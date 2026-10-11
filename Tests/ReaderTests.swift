import XCTest
import AVFoundation
import SwiftUI
@testable import Narrateify

// MARK: - Fakes

/// Records what the session asks the player to do; tests drive section ends
/// and playback position by hand.
@MainActor
private final class FakePlayer: SectionPlayback {
    var rate: Float = 1
    var position: TimeInterval = 0
    var onSectionEnd: (() -> Void)?
    private(set) var played: [Int] = []       // section IDs, in play order
    private(set) var paused = false
    private(set) var loaded: Int?

    func prepare() {}
    func play(_ section: DecodedSection, from time: TimeInterval) throws {
        played.append(section.sectionID)
        loaded = section.sectionID
        position = time
        paused = false
    }
    func pause() { paused = true }
    func resume() { paused = false }
    func stop() { loaded = nil; position = 0 }
    func shutdown() { stop() }

    func endSection() { loaded = nil; onSectionEnd?() }
}

/// A synthesizer whose calls block until the test completes or fails them.
@MainActor
private final class GatedSynth {
    private(set) var calls: [Int] = []
    private(set) var cancelled: [Int] = []
    private var pending: [Int: CheckedContinuation<SynthesizedSpeech, Error>] = [:]

    func synthesize(_ section: ReadingSection) async throws -> SynthesizedSpeech {
        let id = section.id
        calls.append(id)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { cont in pending[id] = cont }
        } onCancel: {
            Task { @MainActor in
                self.cancelled.append(id)
                self.pending.removeValue(forKey: id)?.resume(throwing: CancellationError())
            }
        }
    }

    var waiting: Set<Int> { Set(pending.keys) }

    func complete(_ id: Int, seconds: Double = 0.2) {
        pending.removeValue(forKey: id)?.resume(returning: SynthesizedSpeech(
            audio: TestAudio.wav(seconds: seconds), fileExtension: "wav", words: []))
    }

    func fail(_ id: Int) {
        pending.removeValue(forKey: id)?.resume(throwing: SpeechEngineError.serviceUnavailable("test"))
    }
}

enum TestAudio {
    /// `ffmpeg -f lavfi -i sine=frequency=440:duration=0.5 -ar 24000 -ac 1 -b:a 32k`
    static let mp3Base64 = "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"

    /// A 16-bit PCM WAV sine tone, built by hand.
    static func wav(seconds: Double, sampleRate: Int = 24_000, channels: Int = 1) -> Data {
        let frames = Int(Double(sampleRate) * seconds)
        var pcm = Data(capacity: frames * channels * 2)
        for i in 0..<frames {
            let v = Int16(sin(Double(i) * 2 * .pi * 440 / Double(sampleRate)) * 8000)
            for _ in 0..<channels { withUnsafeBytes(of: v.littleEndian) { pcm.append(contentsOf: $0) } }
        }
        var d = Data()
        func u32(_ x: Int) { withUnsafeBytes(of: UInt32(x).littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ x: Int) { withUnsafeBytes(of: UInt16(x).littleEndian) { d.append(contentsOf: $0) } }
        d.append(contentsOf: Array("RIFF".utf8)); u32(36 + pcm.count)
        d.append(contentsOf: Array("WAVEfmt ".utf8)); u32(16); u16(1); u16(channels)
        u32(sampleRate); u32(sampleRate * channels * 2); u16(channels * 2); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(pcm.count)
        d.append(pcm)
        return d
    }
}

private func makeSections(_ n: Int) -> [ReadingSection] {
    (0..<n).map { ReadingSection(id: $0, text: "Section number \($0) has a few words.", language: .englishUS) }
}

@MainActor
private func waitUntil(_ what: String, timeout: TimeInterval = 3,
                       _ condition: @MainActor () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        if Date() > deadline { XCTFail("Timed out waiting for: \(what)"); throw CancellationError() }
        try await Task.sleep(nanoseconds: 5_000_000)
    }
}

// MARK: - Session navigation & scheduling

@MainActor
final class ReaderSessionTests: XCTestCase {
    private var defaults: UserDefaults!
    private var player: FakePlayer!
    private var synth: GatedSynth!

    override func setUp() async throws {
        defaults = UserDefaults(suiteName: "ReaderTests")!
        defaults.removePersistentDomain(forName: "ReaderTests")
        player = FakePlayer()
        synth = GatedSynth()
    }

    private func session(_ n: Int) -> ReadingSession {
        let synth = self.synth!
        return ReadingSession(sections: makeSections(n), synthesize: { try await synth.synthesize($0) },
                              player: player, defaults: defaults)
    }

    /// Start and let the first `ready` sections synthesize.
    private func started(_ n: Int, ready: Int) async throws -> ReadingSession {
        let s = session(n)
        s.start()
        for i in 0..<ready {
            try await waitUntil("synth \(i) requested") { self.synth.waiting.contains(i) }
            synth.complete(i)
            try await waitUntil("section \(i) cached") { !s.inFlightIndices.contains(i) }
        }
        return s
    }

    func testFirstSectionStartsImmediatelyAndPlaysWhenReady() async throws {
        let s = session(5)
        s.start()
        try await waitUntil("section 0 requested") { self.synth.calls == [0] }
        XCTAssertTrue(s.isBuffering)
        XCTAssertTrue(s.isPlaying)
        XCTAssertEqual(player.played, [])

        synth.complete(0)
        try await waitUntil("section 0 plays") { self.player.played == [0] }
        XCTAssertFalse(s.isBuffering)
    }

    func testPrefetchIsSequentialAndBounded() async throws {
        let s = session(6)
        s.start()
        try await waitUntil("0 requested") { self.synth.waiting == [0] }
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(synth.calls, [0], "no prefetch before the current section is ready")

        synth.complete(0)
        try await waitUntil("1 prefetched") { self.synth.waiting == [1] }
        XCTAssertEqual(synth.calls, [0, 1], "one prefetch at a time")
        synth.complete(1)
        try await waitUntil("2 prefetched") { self.synth.waiting == [2] }
        synth.complete(2)
        try await waitUntil("idle") { s.inFlightIndices.isEmpty }
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(synth.calls, [0, 1, 2], "prefetch stops \(ReadingSession.prefetchDepth) ahead")

        player.endSection()                       // 0 done → on 1, window grows to 3
        try await waitUntil("3 prefetched") { self.synth.waiting == [3] }
        XCTAssertEqual(player.played, [0, 1])
    }

    func testJumpNeverWaitsBehindPrefetchAndCancelsStaleWork() async throws {
        let s = try await started(10, ready: 1)
        try await waitUntil("1 prefetching") { self.synth.waiting == [1] }

        s.jump(to: 6)
        try await waitUntil("6 requested") { self.synth.calls.contains(6) }
        try await waitUntil("1 cancelled") { self.synth.cancelled.contains(1) }
        XCTAssertEqual(s.inFlightIndices, [6])
        XCTAssertTrue(s.isBuffering)
        synth.complete(6)
        try await waitUntil("6 plays") { self.player.played.last == 6 }
    }

    func testNextPreviousAndRestartSemantics() async throws {
        let s = try await started(4, ready: 3)
        s.rate = 1
        XCTAssertEqual(player.played, [0])

        s.next()
        XCTAssertEqual(s.currentIndex, 1)
        XCTAssertEqual(player.played, [0, 1], "cached section plays instantly")

        player.position = 3                       // well into section 1 → restart it
        s.previous()
        XCTAssertEqual(s.currentIndex, 1)
        XCTAssertEqual(player.played, [0, 1, 1])

        player.position = 0.4                     // just started → go back
        s.previous()
        XCTAssertEqual(s.currentIndex, 0)
        XCTAssertEqual(player.played.last, 0)

        player.position = 0.1                     // first section → restart, never underflow
        s.previous()
        XCTAssertEqual(s.currentIndex, 0)
        XCTAssertEqual(player.played.count, 5)

        s.rate = 3                                // threshold is wall time: 3 s source @3× = 1 s
        player.position = 3
        s.next()
        player.position = 3
        s.previous()
        XCTAssertEqual(s.currentIndex, 0, "1 s of wall time in → previous section")
    }

    func testPauseResumeKeepsSection() async throws {
        let s = try await started(3, ready: 1)
        s.togglePlayPause()
        XCTAssertFalse(s.isPlaying)
        XCTAssertTrue(player.paused)
        s.togglePlayPause()
        XCTAssertTrue(s.isPlaying)
        XCTAssertFalse(player.paused)
        XCTAssertEqual(player.played, [0], "resume, not replay")
    }

    func testSectionEndsAdvanceThenFinish() async throws {
        let s = try await started(2, ready: 2)
        var finishedCalls = 0
        s.onFinished = { finishedCalls += 1 }
        player.endSection()
        XCTAssertEqual(s.currentIndex, 1)
        XCTAssertEqual(player.played, [0, 1])
        player.endSection()
        XCTAssertTrue(s.finished)
        XCTAssertFalse(s.isPlaying)
        XCTAssertEqual(finishedCalls, 1)

        s.togglePlayPause()                       // play after finishing → from the top
        XCTAssertEqual(s.currentIndex, 0)
        XCTAssertEqual(player.played.last, 0)
    }

    func testPrefetchFailureIsSkippedWithError() async throws {
        let s = try await started(4, ready: 1)
        try await waitUntil("1 prefetching") { self.synth.waiting == [1] }
        synth.fail(1)
        try await waitUntil("2 prefetching") { self.synth.waiting == [2] }
        synth.complete(2)
        try await waitUntil("2 cached") { !s.inFlightIndices.contains(2) }

        player.endSection()
        XCTAssertEqual(s.currentIndex, 2, "failed section 1 skipped")
        XCTAssertEqual(player.played, [0, 2])
        XCTAssertNotNil(s.error)
    }

    func testCurrentSectionFailureSkipsAhead() async throws {
        let s = session(3)
        s.start()
        try await waitUntil("0 requested") { self.synth.waiting == [0] }
        synth.fail(0)
        try await waitUntil("moved to 1") { s.currentIndex == 1 }
        XCTAssertNotNil(s.error)
        try await waitUntil("1 requested") { self.synth.waiting.contains(1) }
        synth.complete(1)
        try await waitUntil("1 plays") { self.player.played == [1] }

        s.jump(to: 0)                             // explicit visit retries the failure
        XCTAssertNil(s.error)
        try await waitUntil("0 retried") { self.synth.calls.filter { $0 == 0 }.count == 2 }
    }

    func testGoingBackReusesCache() async throws {
        let s = try await started(3, ready: 2)
        s.next()
        player.position = 0
        s.previous()
        XCTAssertEqual(s.currentIndex, 0)
        XCTAssertEqual(player.played, [0, 1, 0])
        XCTAssertEqual(synth.calls.filter { $0 == 0 }.count, 1)
    }

    func testStopCancelsEverything() async throws {
        let s = try await started(5, ready: 1)
        try await waitUntil("1 prefetching") { self.synth.waiting == [1] }
        s.stop()
        try await waitUntil("1 cancelled") { self.synth.cancelled.contains(1) }
        XCTAssertTrue(s.inFlightIndices.isEmpty)
        XCTAssertFalse(s.isPlaying)
    }

    func testSynthesizeAllFillsGapsInOrderAndExposesCache() async throws {
        let s = try await started(4, ready: 1)
        try await waitUntil("1 prefetching") { self.synth.waiting == [1] }
        s.stop()
        try await waitUntil("1 cancelled") { self.synth.cancelled.contains(1) }
        let before = synth.calls.count
        let task = Task { await s.synthesizeAll() }
        for i in 1..<4 {
            try await waitUntil("\(i) requested") { self.synth.waiting.contains(i) }
            synth.complete(i)
        }
        let all = await task.value
        XCTAssertTrue(all)
        XCTAssertEqual(Array(synth.calls[before...]), [1, 2, 3], "in order, cached section 0 skipped")
        XCTAssertNotNil(s.speech(for: 3))
        XCTAssertNil(s.speech(for: 99))
    }

    func testNotesFollowTheCurrentSection() async throws {
        let s = try await started(3, ready: 2)
        s.setNote("Supertonic · Edge unavailable", for: 1)
        XCTAssertNil(s.currentSectionNote)
        s.next()
        XCTAssertEqual(s.currentSectionNote, "Supertonic · Edge unavailable")
        s.setNote(nil, for: 1)
        XCTAssertNil(s.currentSectionNote)
    }

    func testRateClampsPersistsAndSteps() {
        let s = session(1)
        s.rate = 9
        XCTAssertEqual(s.rate, 3)
        XCTAssertEqual(player.rate, 3)
        XCTAssertEqual(defaults.float(forKey: ReadingSession.rateDefaultsKey), 3)
        s.rate = 1.5
        s.faster()
        XCTAssertEqual(s.rate, 1.75)
        s.slower(); s.slower()
        XCTAssertEqual(s.rate, 1.25)
        XCTAssertEqual(session(1).rate, 1.25, "new sessions read the saved rate")
        XCTAssertEqual(ReaderOverlayView.rateLabel(1.25), "1.25×")
        XCTAssertEqual(ReaderOverlayView.rateLabel(2), "2×")
        XCTAssertEqual(ReaderOverlayView.rateLabel(1.5), "1.5×")
    }

    func testHighlightFollowsPlayerPosition() async throws {
        let s = try await started(1, ready: 1)
        let text = s.sections[0].text as NSString
        try await waitUntil("first word") { s.currentWordRange?.location == 0 }
        player.position = 0.19                    // near the end of the 0.2 s section
        try await waitUntil("last word") { s.currentWordRange.map { NSMaxRange($0) } == text.length - 1 }
    }
}

// MARK: - Decoding & timeline

final class ReaderAudioTests: XCTestCase {
    private let section = ReadingSection(id: 0, text: "one two three", language: .englishUS)

    func testDecodesDifferentFormatsToOnePlaybackFormat() throws {
        for (rate, ch) in [(24_000, 1), (44_100, 2), (48_000, 1)] {
            let speech = SynthesizedSpeech(audio: TestAudio.wav(seconds: 0.5, sampleRate: rate, channels: ch),
                                           fileExtension: "wav", words: [])
            let d = try SectionDecoder.decode(speech, section: section)
            XCTAssertEqual(d.buffer.format, SectionDecoder.playbackFormat)
            XCTAssertEqual(d.duration, 0.5, accuracy: 0.02, "\(rate) Hz × \(ch)")
            XCTAssertEqual(d.words.count, 3, "estimated when the engine gave none")
        }
    }

    func testDecodesMP3() throws {
        // 0.5 s, 440 Hz, 24 kHz mono, 32 kbps — the shape Edge TTS returns.
        let mp3 = try XCTUnwrap(Data(base64Encoded: TestAudio.mp3Base64))
        let d = try SectionDecoder.decode(SynthesizedSpeech(audio: mp3, fileExtension: "mp3", words: []),
                                          section: section)
        XCTAssertEqual(d.buffer.format, SectionDecoder.playbackFormat)
        XCTAssertEqual(d.duration, 0.5, accuracy: 0.08)   // MP3 encoder padding
    }

    func testGarbageAudioThrows() {
        let speech = SynthesizedSpeech(audio: Data("nope".utf8), fileExtension: "mp3", words: [])
        XCTAssertThrowsError(try SectionDecoder.decode(speech, section: section))
    }

    func testWordTimelineLookup() {
        let words = WordTiming.estimate(text: "one two three", duration: 3)
        XCTAssertNil(WordTimeline.index(at: 1, in: []))
        XCTAssertEqual(WordTimeline.index(at: -1, in: words), 0)
        XCTAssertEqual(WordTimeline.index(at: 0, in: words), 0)
        XCTAssertEqual(WordTimeline.index(at: words[1].start + 0.01, in: words), 1)
        XCTAssertEqual(WordTimeline.index(at: 99, in: words), 2)
    }
}

// MARK: - Real audio

@MainActor
final class ReaderPlaybackIntegrationTests: XCTestCase {
    /// Apple TTS → WAV → real AVAudioEngine at 2×: the highlight must walk the
    /// words in order and the section must finish in about half its length.
    func testRealPlaybackAtDoubleSpeed() async throws {
        let text = "The quick brown fox jumps over the lazy dog, while the reader keeps up with every single word it hears."
        let section = ReadingSection(id: 0, text: text, language: .englishUS)
        // Real Apple voice with its real word marks.
        let speech = try await AppleSpeechEngine().synthesize(
            text, language: .englishUS, voiceID: AppleSpeechEngine.defaultVoice(for: .englishUS) ?? "")
        let duration = try SectionDecoder.decode(speech, section: section).duration
        XCTAssertGreaterThan(duration, 2)

        let defaults = UserDefaults(suiteName: "ReaderPlaybackTests")!
        let player = EngineSectionPlayer()
        player.volume = 0                     // renders for real, just silently
        let session = ReadingSession(sections: [section], synthesize: { _ in speech },
                                     player: player, defaults: defaults)
        session.rate = 2

        var locations: [Int] = []
        let sub = session.$currentWordRange.sink { if let r = $0 { locations.append(r.location) } }
        defer { sub.cancel() }

        // Clock from when audio actually starts, not from synthesis/decoding.
        try await waitUntilPlaying(session)
        let t0 = Date()
        try await waitUntil("finished", timeout: duration) { session.finished }
        let elapsed = Date().timeIntervalSince(t0)

        let wordCount = WordTiming.estimate(text: text, duration: 1).count
        print("[reader] \(duration)s section at 2× played in \(elapsed)s; highlight hit \(Set(locations).count)/\(wordCount) words")
        XCTAssertEqual(elapsed, duration / 2, accuracy: duration * 0.12 + 0.15,
                       "2× of \(duration)s took \(elapsed)s")
        XCTAssertEqual(locations, locations.sorted(), "highlight only moves forward")
        XCTAssertGreaterThan(Set(locations).count, wordCount * 3 / 4,
                             "highlight visited \(Set(locations).count)/\(wordCount) words")
    }

    private func waitUntilPlaying(_ s: ReadingSession) async throws {
        s.start()
        try await waitUntil("playing") { !s.isBuffering && s.currentWordRange != nil }
    }
}

// MARK: - Snapshot

@MainActor
final class ReaderSnapshotTests: XCTestCase {
    /// Renders the overlay with sample state to /tmp/reader-overlay*.png for eyeballing.
    func testRenderOverlaySnapshot() throws {
        let text = "Section-based reading means you skip by sentence, not by timeline. "
            + "The box keeps the spoken word highlighted and glides along as narration moves forward, "
            + "so you always know where you are without hunting through a scrubber."
        let sections = (0..<12).map { ReadingSection(id: $0, text: text, language: .englishUS) }
        let session = ReadingSession(sections: sections, synthesize: { _ in throw CancellationError() },
                                     player: FakePlayer(), defaults: UserDefaults(suiteName: "ReaderSnapshot")!)
        session.rate = 1.5
        session.setNote("Supertonic · Edge unavailable", for: 2)
        let word = (text as NSString).range(of: "highlighted")

        let states: [(String, () -> Void)] = [
            ("", { session.applyPreviewState(index: 2, wordRange: word, playing: true) }),
            ("-buffering", { session.applyPreviewState(index: 3, wordRange: nil, playing: true, buffering: true) }),
            ("-error", { session.applyPreviewState(index: 5, wordRange: NSRange(location: 0, length: 7),
                                                   playing: false, error: "Edge: 403") }),
        ]
        for (suffix, apply) in states {
            apply()
            for (scheme, tag) in [(ColorScheme.dark, ""), (.light, "-light")] {
                let url = URL(fileURLWithPath: "/tmp/reader-overlay\(suffix)\(tag).png")
                try snapshot(ReaderOverlayView(session: session, onClose: {}), scheme: scheme, to: url)
            }
        }
    }

    /// Hosts the view in a real (offscreen-positioned) window over a desktop-ish
    /// backdrop so materials and AppKit-backed controls render like they do live.
    private func snapshot<V: View>(_ view: V, scheme: ColorScheme, to url: URL) throws {
        let backdrop = LinearGradient(colors: scheme == .dark
                                          ? [Color(red: 0.13, green: 0.16, blue: 0.27), Color(red: 0.32, green: 0.18, blue: 0.30)]
                                          : [Color(red: 0.80, green: 0.86, blue: 0.95), Color(red: 0.95, green: 0.85, blue: 0.80)],
                                      startPoint: .topLeading, endPoint: .bottomTrailing)
        let root = view.background(backdrop).environment(\.colorScheme, scheme)
        let hosting = NSHostingView(rootView: root)
        hosting.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        hosting.frame = NSRect(origin: .zero, size: hosting.fittingSize)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = hosting.appearance
        window.contentView = hosting
        window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))   // let layout + preferences settle

        let rep = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        try png.write(to: url)
    }
}
