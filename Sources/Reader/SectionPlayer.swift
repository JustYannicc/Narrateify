import AVFoundation

/// What `ReadingSession` needs from a player. One section at a time; the
/// session owns ordering. Abstracted so navigation logic is testable without
/// real audio.
@MainActor
protocol SectionPlayback: AnyObject {
    /// 0.5–3.0, pitch preserved, applies live.
    var rate: Float { get set }
    /// Source-time seconds into the loaded section (1× clock, not wall clock).
    var position: TimeInterval { get }
    /// Natural end of the loaded section. Not called for stop()/replacement.
    var onSectionEnd: (() -> Void)? { get set }

    /// Warm up the audio graph so the first section starts without a hitch.
    func prepare()
    func play(_ section: DecodedSection, from time: TimeInterval) throws
    func pause()
    func resume()
    /// Drop the loaded section (keeps the engine warm).
    func stop()
    /// Stop and release the audio hardware.
    func shutdown()
}

enum SectionPlayerError: LocalizedError {
    case outputUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .outputUnavailable(let s): return "Audio output unavailable: \(s)"
        }
    }
}

/// AVAudioEngine → AVAudioPlayerNode → AVAudioUnitTimePitch → mixer. Every
/// section arrives in `SectionDecoder.playbackFormat`, so the graph is wired
/// once. The time-pitch unit gives live 0.5–3× without chipmunking.
@MainActor
final class EngineSectionPlayer: SectionPlayback {
    var rate: Float = 1 {
        didSet { timePitch.rate = rate }
    }
    var onSectionEnd: (() -> Void)?
    /// Output volume (tests mute it so `xcodebuild test` doesn't talk at you).
    var volume: Float {
        get { engine.mainMixerNode.outputVolume }
        set { engine.mainMixerNode.outputVolume = newValue }
    }

    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private let timePitch = AVAudioUnitTimePitch()

    private var loaded: DecodedSection?
    /// Frame the current schedule started at (non-zero after a device-change resume).
    private var startFrame: AVAudioFramePosition = 0
    private var pausedPosition: TimeInterval?
    /// Bumped on every (re)schedule so completion callbacks from replaced or
    /// stopped buffers are ignored — AVAudioPlayerNode fires them on stop too.
    private var generation = 0
    private var configObserver: NSObjectProtocol?

    init() {
        let format = SectionDecoder.playbackFormat
        engine.attach(node)
        engine.attach(timePitch)
        engine.connect(node, to: timePitch, format: format)
        engine.connect(timePitch, to: engine.mainMixerNode, format: format)
        timePitch.rate = rate

        // Output device changed (headphones unplugged, AirPods connected): the
        // engine stops itself. Pick up where we were.
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.recoverFromConfigurationChange() }
        }
    }

    deinit {
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
    }

    func prepare() {
        try? startEngineIfNeeded()
    }

    func play(_ section: DecodedSection, from time: TimeInterval = 0) throws {
        try startEngineIfNeeded()
        generation += 1
        node.stop()
        loaded = section
        pausedPosition = nil

        let sr = section.buffer.format.sampleRate
        startFrame = AVAudioFramePosition(max(0, min(time, section.duration)) * sr)
        guard let buffer = SectionDecoder.tail(of: section.buffer, from: startFrame) else {
            // Asked to start at/after the end: that's just "finished".
            finishSoon(generation)
            return
        }
        let gen = generation
        node.scheduleBuffer(buffer, at: nil, options: [],
                            completionCallbackType: .dataPlayedBack) { [weak self] _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.bufferDidFinish(gen) }
            }
        }
        node.play()
    }

    func pause() {
        guard loaded != nil, pausedPosition == nil else { return }
        pausedPosition = livePosition()
        node.pause()
    }

    func resume() {
        guard loaded != nil, pausedPosition != nil else { return }
        if !engine.isRunning { try? engine.start() }
        pausedPosition = nil
        node.play()
    }

    func stop() {
        generation += 1
        node.stop()
        loaded = nil
        pausedPosition = nil
        startFrame = 0
    }

    func shutdown() {
        stop()
        engine.stop()
    }

    var position: TimeInterval {
        if let pausedPosition { return pausedPosition }
        return livePosition()
    }

    // MARK: Internals

    private func livePosition() -> TimeInterval {
        guard let loaded else { return 0 }
        guard let nodeTime = node.lastRenderTime,
              let playerTime = node.playerTime(forNodeTime: nodeTime) else {
            return Double(startFrame) / loaded.buffer.format.sampleRate
        }
        // playerTime counts frames the player node has produced, i.e. source
        // frames — the time-pitch unit downstream is what speeds it up.
        let frames = startFrame + max(0, playerTime.sampleTime)
        return min(Double(frames) / playerTime.sampleRate, loaded.duration)
    }

    private func startEngineIfNeeded() throws {
        guard !engine.isRunning else { return }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            throw SectionPlayerError.outputUnavailable(error.localizedDescription)
        }
    }

    private func bufferDidFinish(_ gen: Int) {
        guard gen == generation, loaded != nil else { return }
        loaded = nil
        onSectionEnd?()
    }

    private func finishSoon(_ gen: Int) {
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.bufferDidFinish(gen) }
        }
    }

    private func recoverFromConfigurationChange() {
        guard let loaded else { return }
        let wasPaused = pausedPosition != nil
        let at = position
        do {
            try play(loaded, from: at)
            if wasPaused { pause() }
        } catch {
            // Nothing to play to; leave it paused at the same spot.
            pausedPosition = at
        }
    }
}

/// No-op player for building views that never play (overlay prewarm).
@MainActor
final class SilentSectionPlayer: SectionPlayback {
    var rate: Float = 1
    var position: TimeInterval { 0 }
    var onSectionEnd: (() -> Void)?
    func prepare() {}
    func play(_ section: DecodedSection, from time: TimeInterval) throws {}
    func pause() {}
    func resume() {}
    func stop() {}
    func shutdown() {}
}
