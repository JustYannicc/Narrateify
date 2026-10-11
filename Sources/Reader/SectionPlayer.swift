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

/// AVAudioEngine → AVAudioPlayerNode → mixer. Every section arrives in
/// `SectionDecoder.playbackFormat`, so the graph is wired once. Speed is
/// applied before scheduling by `SpeechStretcher` (Sonic), which sounds far
/// more natural on speech than AVAudioUnitTimePitch; changing the rate
/// re-schedules from the current spot.
///
/// Stretching runs on a serial background queue in ~0.5 s slices, so a rate
/// change or a long section never stalls the main thread and the first slice
/// plays almost at once. Position = section frames before the schedule began
/// + played output frames × speed, minus any time the node sat starved
/// waiting for the next chunk.
@MainActor
final class EngineSectionPlayer: SectionPlayback {
    var rate: Float = 1 {
        didSet { if rate != oldValue { restart() } }
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
    private var stretcher = SpeechStretcher(speed: 1)

    private var source: Source?
    /// Section frame the current schedule started at (non-zero after a
    /// device-change resume).
    private var startFrame: AVAudioFramePosition = 0
    /// Output (stretched) frames scheduled since `startFrame`.
    private var scheduledFrames: AVAudioFramePosition = 0
    /// Section frames handed to the stretcher since `startFrame`.
    private var fedFrames: AVAudioFramePosition = 0
    /// Node frames that passed while it had nothing to play (stream starved).
    private var starvedFrames: AVAudioFramePosition = 0
    private var pendingBuffers = 0
    /// Stretch jobs submitted but not yet enqueued (this generation).
    private var stretchJobs = 0
    private let stretchQueue = DispatchQueue(label: "narrateify.stretch", qos: .userInitiated)
    private var pausedPosition: TimeInterval?
    /// Bumped on every (re)schedule so completion callbacks from replaced or
    /// stopped buffers are ignored — AVAudioPlayerNode fires them on stop too.
    private var generation = 0
    private var configObserver: NSObjectProtocol?

    private var sampleRate: Double { SectionDecoder.playbackFormat.sampleRate }

    init() {
        let format = SectionDecoder.playbackFormat
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)

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
        try start(.decoded(section), from: time, paused: false)
    }

    func playLive(_ section: LiveSection) throws {
        try start(.live(section), from: 0, paused: false)
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
        fedFrames = 0
        starvedFrames = 0
        pendingBuffers = 0
        stretchJobs = 0
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

    /// Schedule `new` from `time`. Paused starts don't touch the node, so a
    /// rate change while paused can't leak a blip of audio.
    private func start(_ new: Source, from time: TimeInterval, paused: Bool) throws {
        try startEngineIfNeeded()
        stop()
        source = new
        let duration: TimeInterval
        switch new {
        case .decoded(let s): duration = s.duration
        case .live(let s): duration = s.duration
        }
        startFrame = AVAudioFramePosition(max(0, min(time, duration)) * sampleRate)
        stretcher = SpeechStretcher(speed: rate)

        switch new {
        case .decoded(let section):
            if let buffer = SectionDecoder.tail(of: section.buffer, from: startFrame) { schedule(buffer) }
            scheduleFlush()
        case .live(let section):
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
                if section.state == .complete { self.scheduleFlush() }
                self.endIfDrained()
            }
            if section.state == .complete { scheduleFlush() }
        }
        if paused {
            pausedPosition = Double(startFrame) / sampleRate
        } else {
            node.play()
        }
        endIfDrained()   // asked to start at/after the end: that's just "finished"
    }

    /// Starved since the last chunk ran out? Don't count that silence as
    /// played audio, or the highlight runs ahead for the rest of the section.
    private func accountForStarvation() {
        if let played = nodeFrames(), played - starvedFrames > scheduledFrames {
            starvedFrames = played - scheduledFrames
        }
    }

    /// Stretch a chunk of section audio and queue the result. At 1× it's
    /// queued as is; otherwise in slices, so playback starts on the first.
    private func schedule(_ buffer: AVAudioPCMBuffer) {
        fedFrames += AVAudioFramePosition(buffer.frameLength)
        guard stretcher.speed != 1 else { return enqueue(buffer) }
        let slice = AVAudioFrameCount(sampleRate / 2)
        var offset: AVAudioFrameCount = 0
        while offset < buffer.frameLength {
            guard let part = SectionDecoder.slice(of: buffer, from: offset,
                                                  count: min(slice, buffer.frameLength - offset)) else { return }
            submit { $0.process(part) }
            offset += slice
        }
    }

    /// End of the section's audio: queue what the stretcher held back.
    private func scheduleFlush() {
        guard stretcher.speed != 1 else { return }
        submit { $0.flush() }
    }

    /// Run stretch work in order off the main thread; enqueue the result
    /// unless the schedule was replaced meanwhile.
    private func submit(_ work: @escaping @Sendable (SpeechStretcher) -> AVAudioPCMBuffer?) {
        let stretcher = self.stretcher
        let gen = generation
        stretchJobs += 1
        stretchQueue.async {
            let out = work(stretcher)
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.generation == gen else { return }
                    self.stretchJobs -= 1
                    if let out { self.enqueue(out) }
                    self.endIfDrained()
                }
            }
        }
    }

    private func enqueue(_ buffer: AVAudioPCMBuffer) {
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
        guard let source, pendingBuffers == 0, stretchJobs == 0 else { return }
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
        // The node counts stretched output frames; each stands for `speed`
        // section frames (Sonic holds the ratio to within ~0.3%).
        let output = nodeFrames().map { min(max(0, $0 - starvedFrames), scheduledFrames) } ?? 0
        let played = min(AVAudioFramePosition(Double(output) * Double(stretcher.speed)), fedFrames)
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

    private func recoverFromConfigurationChange() { restart() }

    /// Re-schedule the loaded section from where it is now (output device
    /// changed, or a new rate), keeping it paused if it was.
    private func restart() {
        guard let source else { return }
        let wasPaused = pausedPosition != nil
        let at = position
        do {
            try start(source, from: at, paused: wasPaused)
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
