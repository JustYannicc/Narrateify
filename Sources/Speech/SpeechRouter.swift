import Foundation

/// One step in a language's fallback chain: an engine plus the voice to use.
struct VoiceRoute: Codable, Hashable, Identifiable {
    var engine: SpeechEngineKind
    var voiceID: String

    var id: String { "\(engine.rawValue):\(voiceID)" }
}

/// What the user configured for one of their reading languages: an ordered
/// chain of engine/voice pairs. The first that works wins.
struct LanguageProfile: Codable, Hashable, Identifiable {
    var language: ReadingLanguage
    var routes: [VoiceRoute]

    var id: String { language.code }
}

/// Picks an engine for each section and falls back down the language's chain
/// when one fails. An engine that reports `.serviceUnavailable` (Edge's 403,
/// no network) is benched for a while so later sections don't keep paying the
/// failure latency.
@MainActor
final class SpeechRouter {
    struct Result {
        let speech: SynthesizedSpeech
        let route: VoiceRoute
        /// Routes tried before `route` and why they failed (for status/UI).
        let failures: [(VoiceRoute, Error)]
    }

    private let engines: [SpeechEngineKind: SpeechEngine]
    private var benchedUntil: [SpeechEngineKind: Date] = [:]
    var benchDuration: TimeInterval = 10 * 60

    /// Called whenever an engine gets benched or recovers, for status display.
    var onHealthChange: ((SpeechEngineKind, Bool) -> Void)?

    init(engines: [SpeechEngine]) {
        self.engines = Dictionary(uniqueKeysWithValues: engines.map { ($0.kind, $0) })
    }

    func engine(_ kind: SpeechEngineKind) -> SpeechEngine? { engines[kind] }

    func isBenched(_ kind: SpeechEngineKind, now: Date = Date()) -> Bool {
        guard let until = benchedUntil[kind] else { return false }
        return until > now
    }

    /// Clears the bench, e.g. when the user hits "retry" or the network changes.
    func resetHealth() {
        let kinds = Array(benchedUntil.keys)
        benchedUntil.removeAll()
        kinds.forEach { onHealthChange?($0, true) }
    }

    func synthesize(_ section: ReadingSection, profile: LanguageProfile) async throws -> Result {
        var failures: [(VoiceRoute, Error)] = []
        let candidates = profile.routes.filter { engines[$0.engine] != nil }
        // If everything is benched, still try the chain rather than fail outright.
        let healthy = candidates.filter { !isBenched($0.engine) }
        for route in healthy.isEmpty ? candidates : healthy {
            guard let engine = engines[route.engine] else { continue }
            guard engine.supports(section.language) else {
                failures.append((route, SpeechEngineError.unsupportedLanguage(section.language.code)))
                continue
            }
            do {
                try Task.checkCancellation()
                let speech = try await engine.synthesize(section.text,
                                                         language: section.language,
                                                         voiceID: route.voiceID)
                if benchedUntil.removeValue(forKey: route.engine) != nil {
                    onHealthChange?(route.engine, true)
                }
                return Result(speech: speech, route: route, failures: failures)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                failures.append((route, error))
                if case SpeechEngineError.serviceUnavailable = error {
                    benchedUntil[route.engine] = Date().addingTimeInterval(benchDuration)
                    onHealthChange?(route.engine, false)
                }
            }
        }
        throw failures.last?.1 ?? SpeechEngineError.unsupportedLanguage(section.language.code)
    }
}
