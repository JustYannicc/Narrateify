import AVFoundation

/// A section whose audio is still arriving: PCM chunks decoded from the
/// engine's stream, plus the word timings known so far. The player schedules
/// chunks as they land; once the stream completes, the same PCM becomes the
/// section's `DecodedSection` (no second decode).
@MainActor
final class LiveSection {
    enum State { case streaming, complete, aborted }

    let section: ReadingSection
    private(set) var buffers: [AVAudioPCMBuffer] = []
    private(set) var words: [WordTiming] = []
    private(set) var state = State.streaming
    private(set) var frames: AVAudioFrameCount = 0

    /// First PCM chunk decoded (pipeline → session: start playing).
    var onFirstAudio: (() -> Void)?
    /// Each new chunk, for the player that's playing this section.
    var onBuffer: ((AVAudioPCMBuffer) -> Void)?
    /// Stream completed or aborted, for the player.
    var onSettled: (() -> Void)?

    /// Hand this to the engine.
    nonisolated let sink: Sink
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(section: ReadingSection) {
        self.section = section
        sink = Sink()
        sink.live = self
    }

    var duration: TimeInterval { Double(frames) / SectionDecoder.playbackFormat.sampleRate }

    /// Waits until the main actor has seen the end of the stream. Only call
    /// once the sink reported an end (`sink.ending != nil`), or it may wait forever.
    func settled() async {
        guard state == .streaming else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    /// The whole streamed section, once it completed.
    func decodedSection() -> DecodedSection? {
        guard state == .complete, frames > 0,
              let buffer = SectionDecoder.concatenate(buffers) else { return nil }
        return DecodedSection(section: section, buffer: buffer, words: words)
    }

    // MARK: From the sink (main queue, in order)

    fileprivate func received(_ buffer: AVAudioPCMBuffer) {
        guard state == .streaming else { return }
        buffers.append(buffer)
        frames += buffer.frameLength
        onBuffer?(buffer)
        if buffers.count == 1 { onFirstAudio?() }
    }

    fileprivate func received(words: [WordTiming]) {
        guard state == .streaming else { return }
        self.words = words
    }

    fileprivate func ended(_ outcome: State) {
        guard state == .streaming else { return }
        state = outcome
        onSettled?()
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }

    /// Engine-facing side: decodes on a private queue and forwards to the main
    /// actor in arrival order.
    final class Sink: LiveSpeechSink, @unchecked Sendable {
        fileprivate weak var live: LiveSection?
        private let queue = DispatchQueue(label: "narrateify.live-decode", qos: .userInitiated)
        private let lock = NSLock()
        private var _ending: State?
        private lazy var decoder = MP3StreamDecoder { [weak self] pcm in self?.deliver { $0.received(pcm) } }

        /// How the engine ended the stream, as soon as it did (any thread).
        var ending: State? { lock.withLock { _ending } }

        func audio(_ mp3: Data) {
            guard ending == nil else { return }
            queue.async { self.decoder.feed(mp3) }
        }

        func words(_ words: [WordTiming]) {
            guard ending == nil else { return }
            queue.async { self.deliver { $0.received(words: words) } }
        }

        func complete() { end(.complete) }
        func abort() { end(.aborted) }

        private func end(_ outcome: State) {
            let first: Bool = lock.withLock {
                guard _ending == nil else { return false }
                _ending = outcome
                return true
            }
            guard first else { return }
            queue.async {
                var outcome = outcome
                if outcome == .complete {
                    self.decoder.finish()
                    if self.decoder.failure != nil { outcome = .aborted }   // fall back to a full decode
                }
                self.deliver { $0.ended(outcome) }
            }
        }

        private func deliver(_ body: @escaping @MainActor (LiveSection) -> Void) {
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let live = self?.live else { return }
                    body(live)
                }
            }
        }
    }
}
