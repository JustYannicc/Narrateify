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
    /// Play a section that's still streaming in, from its start; chunks are
    /// queued as they arrive. Ends once the stream completed and drained (an
    /// aborted stream never ends by itself — the session replaces it).
    func playLive(_ section: LiveSection) throws
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
///
/// Audio is scheduled in chunks: one for a decoded section, one per network
/// chunk for a live one. Position = frames the node has played since the
/// schedule began, minus any time it sat starved waiting for the next chunk.
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

    private enum Source {
        case decoded(DecodedSection)
        case live(LiveSection)
    }

    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private let timePitch = AVAudioUnitTimePitch()

    private var source: Source?
    /// Section frame the current schedule started at (non-zero after a
    /// device-change resume).
    private var startFrame: AVAudioFramePosition = 0
    /// Frames scheduled since `startFrame`.
    private var scheduledFrames: AVAudioFramePosition = 0
    /// Node frames that passed while it had nothing to play (stream starved).
    private var starvedFrames: AVAudioFramePosition = 0
    private var pendingBuffers = 0
    private var pausedPosition: TimeInterval?
    /// Bumped on every (re)schedule so completion callbacks from replaced or
    /// stopped buffers are ignored — AVAudioPlayerNode fires them on stop too.
    private var generation = 0
    private var configObserver: NSObjectProtocol?

    private var sampleRate: Double { SectionDecoder.playbackFormat.sampleRate }

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
        try begin(.decoded(section), from: time)
        if let buffer = SectionDecoder.tail(of: section.buffer, from: startFrame) {
            schedule(buffer)
        }
        node.play()
        endIfDrained()   // asked to start at/after the end: that's just "finished"
    }

    func playLive(_ section: LiveSection) throws {
        try playLive(section, from: 0)
    }

    private func playLive(_ section: LiveSection, from time: TimeInterval) throws {
        try begin(.live(section), from: time)
        if let sofar = SectionDecoder.concatenate(section.buffers),
           let buffer = SectionDecoder.tail(of: sofar, from: startFrame) {
            schedule(buffer)
        }
        let gen = generation
        section.onBuffer = { [weak self] buffer in
            guard let self, self.generation == gen else { return }
            self.schedule(buffer)
        }
        section.onSettled = { [weak self] in
            guard let self, self.generation == gen else { return }
            self.endIfDrained()
        }
        node.play()
        endIfDrained()
    }

    func pause() {
        guard source != nil, pausedPosition == nil else { return }
        accountForStarvation()   // a gap before the pause isn't visible after it
        pausedPosition = livePosition()
        node.pause()
    }

    func resume() {
        guard source != nil, pausedPosition != nil else { return }
        if !engine.isRunning { try? engine.start() }
        pausedPosition = nil
        node.play()
    }

    func stop() {
        generation += 1
        node.stop()
        detachLive()
        source = nil
        pausedPosition = nil
        startFrame = 0
        scheduledFrames = 0
        starvedFrames = 0
        pendingBuffers = 0
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

    private func begin(_ new: Source, from time: TimeInterval) throws {
        try startEngineIfNeeded()
        stop()
        source = new
        let duration: TimeInterval
        switch new {
        case .decoded(let s): duration = s.duration
        case .live(let s): duration = s.duration
        }
        startFrame = AVAudioFramePosition(max(0, min(time, duration)) * sampleRate)
    }

    /// Starved since the last chunk ran out? Don't count that silence as
    /// played audio, or the highlight runs ahead for the rest of the section.
    private func accountForStarvation() {
        if let played = nodeFrames(), played - starvedFrames > scheduledFrames {
            starvedFrames = played - scheduledFrames
        }
    }

    private func schedule(_ buffer: AVAudioPCMBuffer) {
        accountForStarvation()
        scheduledFrames += AVAudioFramePosition(buffer.frameLength)
        pendingBuffers += 1
        let gen = generation
        node.scheduleBuffer(buffer, at: nil, options: [],
                            completionCallbackType: .dataPlayedBack) { [weak self] _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.bufferDidFinish(gen) }
            }
        }
    }

    private func bufferDidFinish(_ gen: Int) {
        guard gen == generation else { return }
        pendingBuffers -= 1
        endIfDrained()
    }

    /// Everything scheduled has played, and nothing more is coming.
    private func endIfDrained() {
        guard let source, pendingBuffers == 0 else { return }
        if case .live(let live) = source, live.state != .complete { return }
        let gen = generation
        // Next main-queue turn, so callers never see onSectionEnd re-entrantly.
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.generation == gen, self.source != nil else { return }
                self.detachLive()
                self.source = nil
                self.onSectionEnd?()
            }
        }
    }

    private func detachLive() {
        if case .live(let live) = source {
            live.onBuffer = nil
            live.onSettled = nil
        }
    }

    private func nodeFrames() -> AVAudioFramePosition? {
        guard let nodeTime = node.lastRenderTime, nodeTime.isSampleTimeValid,
              let playerTime = node.playerTime(forNodeTime: nodeTime) else { return nil }
        return max(0, playerTime.sampleTime)
    }

    private func livePosition() -> TimeInterval {
        guard source != nil else { return 0 }
        // playerTime counts frames the player node has produced, i.e. source
        // frames — the time-pitch unit downstream is what speeds it up.
        let played = nodeFrames().map { min(max(0, $0 - starvedFrames), scheduledFrames) } ?? 0
        return Double(startFrame + played) / sampleRate
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

    private func recoverFromConfigurationChange() {
        guard let source else { return }
        let wasPaused = pausedPosition != nil
        let at = position
        do {
            switch source {
            case .decoded(let s): try play(s, from: at)
            case .live(let s): try playLive(s, from: at)
            }
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
    func playLive(_ section: LiveSection) throws {}
    func pause() {}
    func resume() {}
    func stop() {}
    func shutdown() {}
}
