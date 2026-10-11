import AVFoundation
import OSLog
import SwiftUI

private let log = Logger(subsystem: "com.narrateify.Narrateify", category: "narration")

/// Runs a narration end to end: plan sections in the user's languages, route
/// each section to the first working engine, play it in the reader overlay,
/// and save the whole thing to History when it's done.
@MainActor
final class Narrator: ObservableObject {
    let settings = ReadingSettings()
    let router: SpeechRouter
    @Published private(set) var session: ReadingSession?
    /// Bumped when an engine is benched/recovers, so health labels refresh.
    @Published private(set) var healthRevision = 0

    /// Saves a finished narration (text, joined audio, per-engine summary).
    var saveToHistory: ((_ text: String, _ audio: Data, _ routes: [VoiceRoute], _ characters: [Int]) -> Void)?
    /// Reading finished naturally (not stopped) — drives the queue.
    var onFinished: (() -> Void)?
    /// An engine got benched or recovered (lets the app warm up fallbacks).
    var onEngineHealthChange: ((SpeechEngineKind, Bool) -> Void)?
    /// Status line updates for the menu bar panel.
    var onStatus: ((String) -> Void)?

    private var previewPlayer: AVAudioPlayer?

    /// Which route produced each section of one narration (per session, so a
    /// late history save never mixes narrations).
    private final class RouteLog { var routes: [Int: VoiceRoute] = [:] }

    init(engines: [SpeechEngine]) {
        router = SpeechRouter(engines: engines)
        router.onHealthChange = { [weak self] kind, healthy in
            self?.healthRevision += 1
            self?.onEngineHealthChange?(kind, healthy)
        }
        ReaderOverlayController.shared.onClose = { [weak self] in self?.stop() }
    }

    var isActive: Bool { session != nil }

    // MARK: Reading

    func read(_ text: String, showOverlay: Bool = true) {
        stop()
        let sections = ReadingPlanner.plan(text, languages: settings.languages)
        guard !sections.isEmpty else { return }
        let routeLog = RouteLog()
        let started = Date()
        log.notice("read: \(sections.count) sections, languages \(sections.map(\.language.code).joined(separator: ","), privacy: .public)")

        var sessionRef: ReadingSession?
        let session = ReadingSession(sections: sections) { [weak self] section in
            guard let self else { throw CancellationError() }
            let t0 = Date()
            let result = try await self.router.synthesize(section, profile: self.settings.profile(for: section.language))
            log.notice("section \(section.id) [\(section.language.code, privacy: .public)] → \(result.route.engine.rawValue, privacy: .public)/\(result.route.voiceID, privacy: .public) in \(Int(Date().timeIntervalSince(t0) * 1000)) ms (t+\(Int(Date().timeIntervalSince(started) * 1000)) ms), skipped \(result.failures.map { "\($0.0.engine.rawValue): \($0.1.localizedDescription)" }.joined(separator: "; "), privacy: .public)")
            routeLog.routes[section.id] = result.route
            sessionRef?.setNote(self.note(for: result), for: section.id)
            return result.speech
        }
        sessionRef = session
        session.onFinished = { [weak self, weak session] in
            guard let self, let session else { return }
            self.finish(session, text: text, log: routeLog)
        }
        self.session = session
        if showOverlay { ReaderOverlayController.shared.show(session) }
        session.start()
        onStatus?("Reading…")
    }

    func stop() {
        session?.stop()
        session = nil
        previewPlayer?.stop()
        ReaderOverlayController.shared.hide()
    }

    func togglePlayPause() {
        if let session { session.togglePlayPause() }
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

    private func finish(_ session: ReadingSession, text: String, log: RouteLog) {
        if self.session === session {
            self.session = nil
            ReaderOverlayController.shared.hide()
        }
        onStatus?("Finished")
        onFinished?()
        // Save after the fact so it never competes with playback for synthesis.
        Task {
            guard await session.synthesizeAll() else { return }
            let parts = session.sections.compactMap { session.speech(for: $0.id) }
            guard parts.count == session.sections.count,
                  let audio = try? SectionAudioJoiner.joinToM4A(parts) else { return }
            let routes = session.sections.compactMap { log.routes[$0.id] }
            self.saveToHistory?(text, audio, routes, session.sections.map(\.text.count))
        }
    }

    // MARK: Settings helpers

    func voices(_ kind: SpeechEngineKind, language: ReadingLanguage) async -> [VoiceOption] {
        await router.engine(kind)?.voices(for: language) ?? []
    }

    /// One short status line for an engine in a language's chain.
    func health(_ kind: SpeechEngineKind, language: ReadingLanguage) -> (String, Color) {
        _ = healthRevision
        guard let engine = router.engine(kind) else { return ("Not available in this build", .secondary) }
        if !engine.supports(language) {
            switch kind {
            case .elevenLabs, .openAI: return ("Add an API key in Settings → Cloud", .orange)
            case .supertonic: return ("Model not downloaded — see Engines", .orange)
            default: return ("Doesn't speak \(language.displayName)", .orange)
            }
        }
        if router.isBenched(kind) { return ("Unreachable — skipped for now", .red) }
        return ("", .secondary)
    }

    static let samples: [String: String] = [
        "en": "Here's a quick test of how this voice sounds.",
        "de": "Das ist ein kurzer Test, wie diese Stimme klingt.",
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
    /// "EN 310 ms · DE 340 ms". Uses the voice from that language's chain when
    /// the engine is in it. A cold local model reports its load time separately.
    func benchmark(_ kind: SpeechEngineKind) async -> String {
        guard let engine = router.engine(kind) else { return "Not available" }
        var parts: [String] = []
        for language in settings.languages {
            guard engine.supports(language) else { parts.append("\(language.base.uppercased()) —"); continue }
            let configured = settings.profile(for: language).routes.first { $0.engine == kind }?.voiceID
            let voiceID: String
            if let configured, !configured.isEmpty {
                voiceID = configured
            } else {
                voiceID = await engine.voices(for: language).first?.id ?? ""
            }
            let text = sample(for: language)
            do {
                var t0 = Date()
                _ = try await engine.synthesize(text, language: language, voiceID: voiceID)
                let first = Date().timeIntervalSince(t0)
                t0 = Date()
                _ = try await engine.synthesize(text, language: language, voiceID: voiceID)
                let warm = Date().timeIntervalSince(t0)
                var label = "\(language.base.uppercased()) \(Int(warm * 1000)) ms"
                if first > warm * 2, first - warm > 0.3 { label += " (first \(Int(first * 1000)) ms)" }
                parts.append(label)
            } catch {
                parts.append("\(language.base.uppercased()) failed")
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
