import Foundation
import Combine
import OSLog

private let log = Logger(subsystem: "com.narrateify.Narrateify", category: "narration")

/// Plays a narration section by section: synthesizes on demand (see
/// `SectionPipeline` for the latency rules), highlights the spoken word, and
/// navigates by section instead of scrubbing a timeline.
@MainActor
final class ReadingSession: ObservableObject {
    typealias Synthesize = SectionPipeline.Synthesize

    static let prefetchDepth = 2
    /// previous() restarts the current section once this many (wall) seconds in.
    static let restartThreshold: TimeInterval = 1.5
    static let rateRange: ClosedRange<Float> = 0.5...3.0
    static let ratePresets: [Float] = [1, 1.25, 1.5, 1.75, 2, 2.5, 3]
    static let rateDefaultsKey = "readerRate"

    @Published private(set) var sections: [ReadingSection]
    @Published private(set) var currentIndex = 0
    /// UTF-16 range of the spoken word in `sections[currentIndex].text`.
    @Published private(set) var currentWordRange: NSRange?
    /// Play intent: true while playing *or* buffering towards playing. Drives
    /// the play/pause button.
    @Published private(set) var isPlaying = false
    /// The section we're on isn't synthesized yet.
    @Published private(set) var isBuffering = false
    @Published var rate: Float {
        didSet {
            let clamped = min(max(rate, Self.rateRange.lowerBound), Self.rateRange.upperBound)
            if clamped != rate { rate = clamped }   // no re-entry: didSet doesn't recurse
            defaults.set(rate, forKey: Self.rateDefaultsKey)
            player.rate = rate
        }
    }
    /// Last synthesis/playback problem, human-readable. Cleared on explicit navigation.
    @Published private(set) var error: String?
    @Published private(set) var finished = false
    /// Caller-supplied note for the current section (e.g. "Supertonic · Edge
    /// unavailable"), shown subtly in the overlay. See `setNote(_:for:)`.
    @Published private(set) var currentSectionNote: String?

    /// Natural end of the last section (not called for stop()).
    var onFinished: (() -> Void)?

    private let pipeline: SectionPipeline
    private let player: SectionPlayback
    private let defaults: UserDefaults
    private var notes: [Int: String] = [:]          // by section ID
    private var active = false
    /// Index currently loaded into the player (nil = nothing loaded).
    private var loadedIndex: Int?
    /// The loaded section is a stream still arriving (not yet decoded).
    private var loadedLive: LiveSection?
    private var ticker: Timer?

    convenience init(sections: [ReadingSection], synthesize: @escaping Synthesize) {
        self.init(sections: sections, synthesize: synthesize,
                  player: EngineSectionPlayer(), defaults: .standard)
    }

    init(sections: [ReadingSection], synthesize: @escaping Synthesize,
         player: SectionPlayback, defaults: UserDefaults) {
        self.sections = sections
        self.pipeline = SectionPipeline(sections: sections, depth: Self.prefetchDepth,
                                        synthesize: synthesize)
        self.player = player
        self.defaults = defaults
        let saved = defaults.object(forKey: Self.rateDefaultsKey) as? Float ?? 1
        self.rate = min(max(saved, Self.rateRange.lowerBound), Self.rateRange.upperBound)
        player.rate = rate
        player.onSectionEnd = { [weak self] in self?.sectionDidEnd() }
        pipeline.onReady = { [weak self] i in self?.sectionReady(i) }
        pipeline.onFailed = { [weak self] i, err in self?.sectionFailed(i, err) }
        pipeline.onLiveAudio = { [weak self] i in self?.sectionReady(i) }
    }

    var currentSection: ReadingSection? {
        sections.indices.contains(currentIndex) ? sections[currentIndex] : nil
    }

    // MARK: Transport

    /// Begin reading from the current section (0 for a fresh session).
    func start() {
        guard !sections.isEmpty else { finish(); return }
        active = true
        isPlaying = true
        finished = false
        go(to: currentIndex, explicit: true)
        // Start the audio engine on the next main-queue turn: section 0's
        // synthesis job is queued first, so engine start-up (~50–70 ms)
        // overlaps synthesis instead of delaying it. play() starts it anyway
        // if this hasn't run yet.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.active else { return }
            self.player.prepare()
        }
    }

    func togglePlayPause() {
        if finished { currentIndex = 0 }
        if finished || !active { start(); return }
        if isPlaying {
            isPlaying = false
            player.pause()
            stopTicker()
        } else {
            isPlaying = true
            if loadedIndex == currentIndex {
                player.resume()
                startTicker()
            } else {
                playCurrentIfReady()
            }
        }
    }

    func next() {
        guard active, currentIndex + 1 < sections.count else { return }
        go(to: currentIndex + 1, explicit: true)
    }

    /// Music-player semantics: restart the section if we're a little way into
    /// it (or on the first one), otherwise go to the previous section.
    func previous() {
        if finished { reactivate(); go(to: sections.count - 1, explicit: true); return }
        guard active else { return }
        let elapsed = loadedIndex == currentIndex ? player.position / Double(rate) : 0
        if elapsed > Self.restartThreshold || currentIndex == 0 {
            go(to: currentIndex, explicit: true)
        } else {
            go(to: currentIndex - 1, explicit: true)
        }
    }

    func jump(to index: Int) {
        guard sections.indices.contains(index) else { return }
        if finished || !active { reactivate() }
        go(to: index, explicit: true)
    }

    /// Step to the next faster/slower preset.
    func faster() { rate = Self.ratePresets.first { $0 > rate + 0.001 } ?? Self.rateRange.upperBound }
    func slower() { rate = Self.ratePresets.last { $0 < rate - 0.001 } ?? Self.rateRange.lowerBound }

    /// Cancel everything and release audio. Does not call `onFinished`.
    func stop() {
        active = false
        pipeline.cancelAll()
        stopTicker()
        player.shutdown()
        loadedIndex = nil
        loadedLive = nil
        isPlaying = false
        isBuffering = false
    }

    // MARK: Cache access & notes

    /// Synthesized audio for a section, if we have it (by `ReadingSection.id`).
    func speech(for sectionID: Int) -> SynthesizedSpeech? {
        sections.firstIndex { $0.id == sectionID }.flatMap(pipeline.speech(at:))
    }

    /// Fill in every section that hasn't been synthesized yet, in order, one
    /// request at a time, without disturbing playback. True if all have audio.
    @discardableResult
    func synthesizeAll() async -> Bool { await pipeline.synthesizeAll() }

    func setNote(_ note: String?, for sectionID: Int) {
        notes[sectionID] = note
        if currentSection?.id == sectionID { currentSectionNote = note }
    }

    // MARK: Navigation core

    private func reactivate() {
        active = true
        finished = false
        isPlaying = true
        player.prepare()
    }

    private func go(to index: Int, explicit: Bool) {
        guard active, sections.indices.contains(index) else { return }
        if explicit {
            pipeline.clearFailure(index)     // an explicit visit retries a failed section
            error = nil
        }
        player.stop()
        stopTicker()
        loadedIndex = nil
        loadedLive = nil
        currentIndex = index
        currentWordRange = nil
        currentSectionNote = notes[sections[index].id]
        playCurrentIfReady()
        pipeline.schedule(playhead: index)
    }

    /// Play the current section: decoded if we have it, else its stream if
    /// audio is already arriving, else wait (buffering).
    private func playCurrentIfReady() {
        let decoded = pipeline.decodedSection(at: currentIndex)
        let live = decoded == nil ? pipeline.liveSection(at: currentIndex) : nil
        guard decoded != nil || live != nil else {
            isBuffering = true
            return
        }
        isBuffering = false
        guard isPlaying else { return }
        do {
            if let decoded {
                try player.play(decoded, from: 0)
            } else if let live {
                try player.playLive(live)
            }
            loadedIndex = currentIndex
            loadedLive = live
            log.notice("playing section \(self.currentIndex) (\(live != nil ? "streaming" : "decoded", privacy: .public))")
            updateHighlight()
            startTicker()
        } catch {
            self.error = error.localizedDescription
            isPlaying = false
        }
    }

    /// The current section got audio (streamed or decoded).
    private func sectionReady(_ i: Int) {
        guard active, i == currentIndex else { return }
        if loadedIndex == i {
            // Streamed audio that broke off mid-way (the engine failed and a
            // fallback answered): restart the section with the full result.
            guard let live = loadedLive, live.state == .aborted else { return }
            player.stop()
            stopTicker()
            loadedIndex = nil
            loadedLive = nil
        } else if loadedIndex != nil {
            return
        }
        playCurrentIfReady()
    }

    private func sectionFailed(_ i: Int, _ err: Error) {
        guard active, i == currentIndex else { return }   // prefetch failures surface on arrival
        error = "Couldn't read section \(i + 1): \(err.localizedDescription) — skipped."
        advance()
    }

    private func sectionDidEnd() {
        stopTicker()
        loadedIndex = nil
        loadedLive = nil
        advance()
    }

    /// Move to the next playable section, skipping known failures.
    private func advance() {
        var j = currentIndex + 1
        while j < sections.count, pipeline.hasFailed(j) {
            error = "Couldn't read section \(j + 1) — skipped."
            j += 1
        }
        if j < sections.count { go(to: j, explicit: false) } else { finish() }
    }

    private func finish() {
        stopTicker()
        player.stop()
        pipeline.cancelAll()
        loadedIndex = nil
        loadedLive = nil
        currentWordRange = nil
        isPlaying = false
        isBuffering = false
        finished = true
        active = false
        onFinished?()
    }

    // MARK: Word highlight

    private func startTicker() {
        stopTicker()
        let t = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            // Hop to a clean main-queue turn: in .common mode the timer can fire
            // inside a SwiftUI update, where publishing would warn.
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.updateHighlight() }
            }
        }
        RunLoop.main.add(t, forMode: .common)
        ticker = t
    }

    private func stopTicker() {
        ticker?.invalidate()
        ticker = nil
    }

    private func updateHighlight() {
        guard let loadedIndex,
              let words = pipeline.decodedSection(at: loadedIndex)?.words ?? loadedLive?.words else { return }
        let range = WordTimeline.index(at: player.position, in: words).map { words[$0].range }
        if range != currentWordRange { currentWordRange = range }
    }

    // MARK: Test / preview hooks

    var cachedAudioIndices: Set<Int> { pipeline.cachedAudioIndices }
    var inFlightIndices: Set<Int> { pipeline.inFlightIndices }

    /// Pose the session for previews and snapshots without synthesizing anything.
    func applyPreviewState(index: Int, wordRange: NSRange?, playing: Bool,
                           buffering: Bool = false, error: String? = nil) {
        currentIndex = index
        currentWordRange = wordRange
        currentSectionNote = sections.indices.contains(index) ? notes[sections[index].id] : nil
        isPlaying = playing
        isBuffering = buffering
        self.error = error
    }
}
