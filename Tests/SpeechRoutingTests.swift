import XCTest
@testable import Narrateify

final class ReadingPlannerTests: XCTestCase {
    private let enDe = [ReadingLanguage.englishUS, .germanDE]

    func testSingleLanguageSkipsDetection() {
        let sections = ReadingPlanner.plan("Die Bundesregierung hat neue Maßnahmen beschlossen.",
                                           languages: [.englishUS])
        XCTAssertEqual(sections.map(\.language), [.englishUS])
    }

    func testDetectsGermanAndEnglishParagraphs() {
        let text = """
        Die Bundesregierung hat am Mittwoch neue Maßnahmen beschlossen. Diese sollen vor allem kleinen Unternehmen helfen.
        The release ships today and fixes the crash on launch. Let me know if anything else breaks after updating.
        """
        let sections = ReadingPlanner.plan(text, languages: enDe)
        XCTAssertEqual(sections.first?.language, .germanDE)
        XCTAssertEqual(sections.last?.language, .englishUS)
    }

    func testUnconfiguredLanguageMapsToAConfiguredOne() {
        let sections = ReadingPlanner.plan("Je ne sais pas ce que tu veux dire par là, mais on peut en parler demain.",
                                           languages: enDe)
        XCTAssertTrue(sections.allSatisfy { enDe.contains($0.language) })
    }

    func testShortSectionInheritsSurroundingLanguage() {
        let text = """
        Die Bundesregierung hat am Mittwoch neue Maßnahmen für kleine Unternehmen beschlossen.
        OK.
        Kritiker bemängeln jedoch, dass die Hilfen viel zu spät kommen und zu kompliziert sind.
        """
        let sections = ReadingPlanner.plan(text, languages: enDe)
        XCTAssertTrue(sections.allSatisfy { $0.language == .germanDE }, "\(sections)")
    }

    func testSectionsRespectLengthLimits() {
        let long = String(repeating: "word, ", count: 200)
        let options = ReadingPlanner.Options()
        let sections = ReadingPlanner.sectionTexts(long, options: options)
        XCTAssertGreaterThan(sections.count, 1)
        XCTAssertLessThanOrEqual(sections[0].count, options.maxFirstSectionLength)
        XCTAssertTrue(sections.allSatisfy { $0.count <= options.maxSectionLength })
        // Nothing lost.
        XCTAssertEqual(sections.joined(separator: " ").filter { !$0.isWhitespace },
                       long.filter { !$0.isWhitespace })
    }

    func testFirstSentenceIsSplitOffForFastStart() {
        let sections = ReadingPlanner.sectionTexts("Here is a quick test of the reader. It reads one section at a time and highlights each word.")
        XCTAssertEqual(sections.first, "Here is a quick test of the reader.")
        XCTAssertEqual(sections.count, 2)
    }

    func testParagraphsNeverMergeAcrossLines() {
        let sections = ReadingPlanner.sectionTexts("Short heading\nAnother short line")
        XCTAssertEqual(sections, ["Short heading", "Another short line"])
    }
}

@MainActor
final class SpeechRouterTests: XCTestCase {
    private final class FakeEngine: SpeechEngine {
        let kind: SpeechEngineKind
        var error: SpeechEngineError?
        var calls = 0
        init(_ kind: SpeechEngineKind, error: SpeechEngineError? = nil) { self.kind = kind; self.error = error }
        func supports(_ language: ReadingLanguage) -> Bool { true }
        func voices(for language: ReadingLanguage) async -> [VoiceOption] { [] }
        func synthesize(_ text: String, language: ReadingLanguage, voiceID: String) async throws -> SynthesizedSpeech {
            calls += 1
            if let error { throw error }
            return SynthesizedSpeech(audio: Data([1]), fileExtension: "wav", words: [])
        }
    }

    private let section = ReadingSection(id: 0, text: "Hallo Welt", language: .germanDE)
    private let profile = LanguageProfile(language: .germanDE, routes: [
        VoiceRoute(engine: .edge, voiceID: "de-DE-SeraphinaMultilingualNeural"),
        VoiceRoute(engine: .supertonic, voiceID: "F1"),
    ])

    func testFallsBackAndBenchesUnavailableEngine() async throws {
        let edge = FakeEngine(.edge, error: .serviceUnavailable("403"))
        let supertonic = FakeEngine(.supertonic)
        let router = SpeechRouter(engines: [edge, supertonic])

        let first = try await router.synthesize(section, profile: profile)
        XCTAssertEqual(first.route.engine, .supertonic)
        XCTAssertEqual(first.failures.count, 1)
        XCTAssertTrue(router.isBenched(.edge))

        // Benched: the next section goes straight to Supertonic.
        _ = try await router.synthesize(section, profile: profile)
        XCTAssertEqual(edge.calls, 1)
        XCTAssertEqual(supertonic.calls, 2)
    }

    func testRecoveredEngineIsUsedAgainAfterReset() async throws {
        let edge = FakeEngine(.edge, error: .serviceUnavailable("403"))
        let router = SpeechRouter(engines: [edge, FakeEngine(.supertonic)])
        _ = try await router.synthesize(section, profile: profile)
        edge.error = nil
        router.resetHealth()
        let result = try await router.synthesize(section, profile: profile)
        XCTAssertEqual(result.route.engine, .edge)
    }

    func testNonServiceErrorsFallThroughWithoutBenching() async throws {
        let router = SpeechRouter(engines: [FakeEngine(.edge, error: .synthesisFailed("bad voice")),
                                            FakeEngine(.supertonic)])
        let result = try await router.synthesize(section, profile: profile)
        XCTAssertEqual(result.route.engine, .supertonic)
        XCTAssertFalse(router.isBenched(.edge))
    }

    func testThrowsWhenWholeChainFails() async {
        let router = SpeechRouter(engines: [FakeEngine(.edge, error: .serviceUnavailable("x")),
                                            FakeEngine(.supertonic, error: .notInstalled("model"))])
        do {
            _ = try await router.synthesize(section, profile: profile)
            XCTFail("expected failure")
        } catch {
            XCTAssertEqual(error as? SpeechEngineError, .notInstalled("model"))
        }
    }

    func testWordTimingEstimateCoversDuration() {
        let words = WordTiming.estimate(text: "Hallo schöne Welt", duration: 3)
        XCTAssertEqual(words.count, 3)
        XCTAssertEqual(words.last.map { $0.start + $0.duration } ?? 0, 3, accuracy: 0.001)
        XCTAssertEqual(("Hallo schöne Welt" as NSString).substring(with: words[1].range), "schöne")
    }
}

@MainActor
final class NarratorTests: XCTestCase {
    private final class InstantEngine: SpeechEngine {
        let kind: SpeechEngineKind = .apple
        func supports(_ language: ReadingLanguage) -> Bool { true }
        func voices(for language: ReadingLanguage) async -> [VoiceOption] { [] }
        func synthesize(_ text: String, language: ReadingLanguage, voiceID: String) async throws -> SynthesizedSpeech {
            throw SpeechEngineError.synthesisFailed("not needed")
        }
    }

    /// A stopped session (and its cached audio) must be freed — the synthesize
    /// closure once captured the session strongly.
    func testStoppedSessionIsReleased() async throws {
        let narrator = Narrator(engines: [InstantEngine()])
        narrator.read("Hello there, this is a short test of the reader.", showOverlay: false)
        weak var session = narrator.session
        XCTAssertNotNil(session)
        narrator.stop()
        try await Task.sleep(for: .milliseconds(200))   // let cancelled jobs unwind
        XCTAssertNil(session)
    }
}

/// On-demand models (Qwen3) are only ever used when a call asks for them.
final class OnDemandModelTests: XCTestCase {
    @MainActor
    func testOnDemandEnginesStayOutOfReadingChains() {
        XCTAssertFalse(SpeechEngineKind.chainable.contains(.qwen3))
        XCTAssertFalse(SpeechEngineKind.chainable.contains(.kokoro))
        for code in ["en-US", "de-DE", "fr-FR"] {
            let profile = ReadingSettings.defaultProfile(ReadingLanguage(code: code))
            XCTAssertFalse(profile.routes.contains { $0.engine.isOnDemand }, code)
        }
    }

    @MainActor
    func testPinnedOnDemandRouteDoesNotDragInTheChain() async {
        let narrator = Narrator(engines: [])
        let strict = await narrator.profile(for: .germanDE, choice: VoiceChoice(
            language: .germanDE, route: VoiceRoute(engine: .qwen3, voiceID: "M2"), strict: true))
        XCTAssertEqual(strict.routes.map(\.engine), [.qwen3])
        let loose = await narrator.profile(for: .germanDE, choice: VoiceChoice(
            language: .germanDE, route: VoiceRoute(engine: .qwen3, voiceID: "M2"), strict: false))
        XCTAssertEqual(loose.routes.first?.engine, .qwen3)
        XCTAssertEqual(loose.routes.dropFirst().map(\.engine), narrator.settings.profile(for: .germanDE).routes.map(\.engine))
    }
}

final class KokoroEngineTests: XCTestCase {
    func testVoicesFollowTheirLanguagePrefix() async {
        let engine = KokoroEngine()
        let american = await engine.voices(for: .englishUS).map(\.id)
        XCTAssertTrue(american.contains("af_heart"))
        XCTAssertLessThan(american.firstIndex(of: "af_heart")!, american.firstIndex(of: "bf_emma")!)   // US first, then UK
        XCTAssertFalse(american.contains("ff_siwis"))
        let german = await engine.voices(for: .germanDE)
        XCTAssertTrue(german.isEmpty)   // Kokoro has no German
        XCTAssertEqual(KokoroEngine.defaultVoice(for: .englishUS), "af_heart")
        XCTAssertEqual(KokoroEngine.defaultVoice(for: ReadingLanguage(code: "fr-FR")), "ff_siwis")
    }

    func testOnlyKokoroPadsBetweenSections() {
        XCTAssertEqual(SpeechEngineKind.kokoro.sectionGap, 0.28)
        XCTAssertEqual(SpeechEngineKind.edge.sectionGap, 0)
    }
}

