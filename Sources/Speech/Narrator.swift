import AVFoundation
import OSLog

private let log = Logger(category: "narration")

/// What one finished narration produced, for History.
struct NarrationSummary {
    let text: String
    let audio: Data
    /// The engine/voice behind each saved section and its character count.
    let parts: [(route: VoiceRoute, characters: Int)]
}

/// How an engine looks from a language's point of view, for Settings.
enum EngineHealth: Equatable {
    case ok
    case needsSetup(String)
    case unsupported(String)
    case unreachable
}

/// Runs a narration end to end: plan sections in the user's languages, route
/// each section to the first working engine, play it in the reader overlay,
/// and save what was read to History.
@MainActor
final class Narrator: ObservableObject {
    let settings = ReadingSettings()
    @Published private(set) var session: ReadingSession?
    /// Bumped when an engine is benched/recovers, so health labels refresh.
    @Published private(set) var healthRevision = 0

    var saveToHistory: ((NarrationSummary) -> Void)?
    /// Reading finished naturally (not stopped) — drives the queue.
    var onFinished: (() -> Void)?
    /// An engine got benched or recovered (lets the app warm up fallbacks).
    var onEngineHealthChange: (() -> Void)?
    var onStatus: ((String) -> Void)?

    private let router: SpeechRouter
    private var previewPlayer: AVAudioPlayer?
    /// One audio engine for every narration: building and starting a fresh
    /// AVAudioEngine per keypress cost ~50 ms before the first word.
    private lazy var sectionPlayer = EngineSectionPlayer()

    /// Which route produced each section of one narration.
    private final class RouteLog { var routes: [Int: VoiceRoute] = [:] }

    init(engines: [SpeechEngine]) {
        router = SpeechRouter(engines: engines)
        router.onHealthChange = { [weak self] _, _ in
            self?.healthRevision += 1
            self?.onEngineHealthChange?()
        }
    }

    var isActive: Bool { session != nil }

    /// Launch-time warm-up of the reader UI and audio graph.
    func prewarm() {
        ReaderOverlayController.shared.prewarm()
        _ = sectionPlayer   // build the graph; starting it waits for a narration
        DispatchQueue.global(qos: .utility).async { MP3StreamDecoder.prewarm() }
    }

    // MARK: Reading

    /// Read `text`. Pass `language` when it's already known (translation
    /// output) to skip detection; `choice` pins an engine/voice (local API).
    func read(_ text: String, language: ReadingLanguage? = nil, choice: VoiceChoice? = nil,
              showOverlay: Bool = true) {
        let started = Date()
        stop()
        let language = language ?? choice?.language
        let sections = ReadingPlanner.plan(text, languages: language.map { [$0] } ?? settings.languages)
        guard !sections.isEmpty else { return }
        let planned = Date()
        let routeLog = RouteLog()
        log.notice("read: \(sections.count) sections, languages \(sections.map(\.language.code).joined(separator: ","), privacy: .public)")

        weak var sessionRef: ReadingSession?   // weak: the session owns this closure
        let session = ReadingSession(sections: sections, synthesize: { [weak self] section, live in
            guard let self else { throw CancellationError() }
            let t0 = Date()
            let result = try await self.router.synthesize(section, profile: await self.profile(for: section.language, choice: choice),
                                                          live: live)
            log.notice("section \(section.id) [\(section.language.code, privacy: .public)] → \(result.route.engine.rawValue, privacy: .public)/\(result.route.voiceID, privacy: .public) in \(Int(Date().timeIntervalSince(t0) * 1000)) ms (t+\(Int(Date().timeIntervalSince(started) * 1000)) ms), skipped \(result.failures.map { "\($0.0.engine.rawValue): \($0.1.localizedDescription)" }.joined(separator: "; "), privacy: .public)")
            routeLog.routes[section.id] = result.route
            sessionRef?.setNote(self.note(for: result), for: section.id)
            return result.speech
        }, player: sectionPlayer, defaults: .standard)
        sessionRef = session
        session.onFinished = { [weak self, weak session] in
            guard let self, let session else { return }
            self.finish(session, log: routeLog)
        }
        self.session = session
        // Kick off synthesis first; the overlay is built on the next main-queue
        // turn, after section 0's job has already hopped to its engine.
        session.start()
        if showOverlay {
            DispatchQueue.main.async { [weak self, weak session] in
                guard let self, let session, self.session === session else { return }
                ReaderOverlayController.shared.show(session)
            }
        }
        log.notice("timing: plan \(Int(planned.timeIntervalSince(started) * 1000)) ms")
        onStatus?("Reading…")
    }

    func stop() {
        previewPlayer?.stop()
        guard let session else { return }
        session.stop()
        self.session = nil
        ReaderOverlayController.shared.hide()
    }

    /// "Supertonic · Edge unavailable" — shown subtly in the overlay header.
    private func note(for result: SpeechRouter.Result) -> String {
        var parts = [result.route.engine.shortName]
        let skipped = Set(result.failures.map(\.0.engine)).subtracting([result.route.engine])
        if !skipped.isEmpty {
            parts.append(skipped.map(\.shortName).sorted().joined(separator: ", ") + " unavailable")
        }
        return parts.joined(separator: " · ")
    }

    private func finish(_ session: ReadingSession, log routeLog: RouteLog) {
        if self.session === session {
            self.session = nil
            ReaderOverlayController.shared.hide()
            sectionPlayer.shutdown()   // release the audio hardware while idle
        }
        onStatus?("Finished")
        onFinished?()

        // Save what was actually synthesized (skipped-over sections may be
        // missing — synthesizing them now would compete with the next read).
        let saved = session.sections.compactMap { section -> (ReadingSection, SynthesizedSpeech, VoiceRoute)? in
            guard let speech = session.speech(for: section.id), let route = routeLog.routes[section.id] else { return nil }
            return (section, speech, route)
        }
        guard !saved.isEmpty, let save = saveToHistory else { return }
        Task.detached(priority: .utility) {
            guard let audio = try? SectionAudioJoiner.joinToM4A(saved.map(\.1)) else { return }
            let summary = NarrationSummary(text: saved.map(\.0.text).joined(separator: " "), audio: audio,
                                           parts: saved.map { ($0.2, $0.0.text.count) })
            await MainActor.run { save(summary) }
        }
    }

    // MARK: Engine status (Settings)

    func voices(_ kind: SpeechEngineKind, language: ReadingLanguage) async -> [VoiceOption] {
        await router.engine(kind)?.voices(for: language) ?? []
    }

    func health(_ kind: SpeechEngineKind, language: ReadingLanguage) -> EngineHealth {
        guard let engine = router.engine(kind) else { return .needsSetup("Not available in this build") }
        if let reason = engine.unavailableReason { return .needsSetup(reason) }
        if !engine.supports(language) { return .unsupported("Doesn't speak \(language.displayName)") }
        return router.isBenched(kind) ? .unreachable : .ok
    }

    func isBenched(_ kind: SpeechEngineKind) -> Bool { router.isBenched(kind) }

    func hasEngine(_ kind: SpeechEngineKind) -> Bool { router.engine(kind) != nil }

    /// One section through the language's chain (render path).
    func synthesize(_ section: ReadingSection, profile: LanguageProfile) async throws -> SpeechRouter.Result {
        try await router.synthesize(section, profile: profile)
    }

    /// A read is about to start: warm the engine each language would use first
    /// (Edge opens its WebSocket — ~200 ms saved off the first section).
    func prewarmEngines() {
        var warmed = Set<SpeechEngineKind>()
        for profile in settings.profiles {
            guard let route = profile.routes.first(where: { router.isUsable($0.engine, for: profile.language) }),
                  warmed.insert(route.engine).inserted else { continue }
            router.engine(route.engine)?.prewarm()
        }
    }

    func retryEngines() { router.resetHealth() }

    /// Would any of the user's languages actually reach this engine right now?
    func isEngineNeeded(_ kind: SpeechEngineKind) -> Bool {
        settings.profiles.contains { router.wouldReach(kind, in: $0) }
    }

    // MARK: Test / preview / benchmark

    static let samples: [String: String] = [
        "en": "Here's a quick test of how this voice sounds.",
        "de": "Das ist ein kurzer Test, wie diese Stimme klingt.",
        "fr": "Voici un petit test pour entendre cette voix.",
        "es": "Esta es una prueba rápida de cómo suena esta voz.",
        "it": "Questa è una breve prova di come suona questa voce.",
    ]

    private func sample(for language: ReadingLanguage) -> String {
        Self.samples[language.base] ?? Self.samples["en"]!
    }

    /// Runs the language's whole chain on a sample sentence and reports which
    /// engine answered and how fast. Plays the result.
    func test(_ language: ReadingLanguage) async -> String {
        router.resetHealth()
        let section = ReadingSection(id: 0, text: sample(for: language), language: language)
        let t0 = Date()
        do {
            let result = try await router.synthesize(section, profile: settings.profile(for: language))
            let ms = Int(Date().timeIntervalSince(t0) * 1000)
            play(result.speech)
            return "\(note(for: result)) · \(ms) ms"
        } catch {
            return "Every engine failed: \(error.localizedDescription)"
        }
    }

    /// Time-to-audio for one engine in each reading language, e.g.
    /// "EN 310 ms · DE 340 ms". Paid cloud engines are skipped, and a local
    /// model loaded only for the benchmark is unloaded again afterwards.
    func benchmark(_ kind: SpeechEngineKind) async -> String {
        guard let engine = router.engine(kind) else { return "Not available" }
        if kind.isCloudPaid { return "Not measured (paid per request)" }
        if let reason = engine.unavailableReason { return reason }
        let supertonic = engine as? SupertonicEngine
        let wasLoaded = supertonic?.isLoaded ?? true
        defer { if !wasLoaded { supertonic?.unload() } }

        var parts: [String] = []
        for language in settings.languages {
            let tag = language.base.uppercased()
            guard engine.supports(language) else { parts.append("\(tag) —"); continue }
            let configured = settings.profile(for: language).routes.first { $0.engine == kind }?.voiceID ?? ""
            let voiceID = configured.isEmpty ? (await engine.voices(for: language).first?.id ?? "") : configured
            let text = sample(for: language)
            do {
                var t0 = Date()
                _ = try await engine.synthesize(text, language: language, voiceID: voiceID)
                let first = Date().timeIntervalSince(t0)
                t0 = Date()
                _ = try await engine.synthesize(text, language: language, voiceID: voiceID)
                let warm = Date().timeIntervalSince(t0)
                var label = "\(tag) \(Int(warm * 1000)) ms"
                if first > warm * 2, first - warm > 0.3 { label += " (first \(Int(first * 1000)) ms)" }
                parts.append(label)
            } catch {
                parts.append("\(tag) failed")
            }
        }
        return parts.joined(separator: " · ")
    }

    /// Plays one specific engine/voice on a sample sentence.
    func preview(_ route: VoiceRoute, language: ReadingLanguage) {
        Task {
            let profile = LanguageProfile(language: language, routes: [route])
            let section = ReadingSection(id: 0, text: sample(for: language), language: language)
            do {
                play(try await router.synthesize(section, profile: profile).speech)
            } catch {
                onStatus?(error.localizedDescription)
            }
        }
    }

    private func play(_ speech: SynthesizedSpeech) {
        previewPlayer?.stop()
        previewPlayer = try? AVAudioPlayer(data: speech.audio)
        previewPlayer?.play()
    }
}

extension SpeechEngineKind {
    var shortName: String {
        switch self {
        case .edge: return "Edge"
        case .supertonic: return "Supertonic"
        case .apple: return "Apple"
        case .elevenLabs: return "ElevenLabs"
        case .openAI: return "OpenAI"
        }
    }

    /// Stored on History records.
    var engineName: String {
        switch self {
        case .edge: return "Edge TTS"
        case .supertonic: return "Supertonic (local)"
        case .apple: return "Apple (built-in)"
        case .elevenLabs: return "ElevenLabs"
        case .openAI: return "OpenAI"
        }
    }
}
