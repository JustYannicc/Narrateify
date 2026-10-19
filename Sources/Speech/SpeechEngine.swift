import Foundation

// Shared contract between the speech engines (Edge, Supertonic, Apple, …), the
// language router, and the section-based reader. Engines synthesize ONE section
// at a time at 1× speed; playback speed is applied by the player so it's
// uniform across engines and can change live.

/// A language the user actually reads, as a BCP-47 tag ("en-US", "de-DE").
/// Only these are ever detected or routed — anything else is ignored.
struct ReadingLanguage: Codable, Hashable, Identifiable {
    let code: String

    var id: String { code }

    /// ISO 639-1 base ("en" for "en-US") — what detectors and most models use.
    var base: String {
        String(code.split(separator: "-").first ?? Substring(code)).lowercased()
    }

    var displayName: String {
        Locale.current.localizedString(forIdentifier: code) ?? code
    }

    static let englishUS = ReadingLanguage(code: "en-US")
    static let germanDE = ReadingLanguage(code: "de-DE")
}

/// When one word is spoken inside a section's audio, at 1× playback speed.
struct WordTiming: Equatable {
    /// UTF-16 range into the section's text (works with NSString/AttributedString).
    let range: NSRange
    let start: TimeInterval
    let duration: TimeInterval
}

/// One synthesized section, ready to play.
struct SynthesizedSpeech {
    let audio: Data
    /// "wav" or "mp3" — playable by AVAudioFile once written to disk.
    let fileExtension: String
    /// Real word timings when the engine provides them; empty means the reader
    /// estimates them from the audio duration (see `WordTiming.estimate`).
    var words: [WordTiming]
}

enum SpeechEngineKind: String, Codable, CaseIterable, Identifiable {
    case edge
    case supertonic
    case apple
    case elevenLabs
    case openAI
    case qwen3

    var id: String { rawValue }

    var label: String {
        switch self {
        case .edge:       return "Edge TTS (Microsoft, online)"
        case .supertonic: return "Supertonic 3 (local)"
        case .apple:      return "Apple (built-in)"
        case .elevenLabs: return "ElevenLabs (cloud)"
        case .openAI:     return "OpenAI (cloud)"
        case .qwen3:      return "Qwen3-TTS 1.7B (local, on demand)"
        }
    }

    var isLocal: Bool { self == .supertonic || self == .apple || self == .qwen3 }
    /// Big models used only when a call asks for them (API/CLI/MCP): never
    /// in a language's chain, loaded per use and unloaded when idle.
    var isOnDemand: Bool { self == .qwen3 }
    /// Engines a language's reading chain can use.
    static var chainable: [SpeechEngineKind] { allCases.filter { !$0.isOnDemand } }
    /// Bills per character and needs an API key.
    var isCloudPaid: Bool { self == .elevenLabs || self == .openAI }
}

struct VoiceOption: Codable, Hashable, Identifiable {
    let id: String
    let name: String
    /// BCP-47 tags or bare base codes this voice speaks. A multilingual voice
    /// lists several; ["*"] means "any language the engine supports".
    let languages: [String]

    func speaks(_ language: ReadingLanguage) -> Bool {
        languages.contains { $0 == "*" || language.matches(localeTag: $0) }
    }
}

/// Why an engine couldn't produce audio. Drives fallback: every case falls
/// through to the next engine in the language's chain, and `.serviceUnavailable`
/// additionally benches the engine for a while so each section doesn't pay the
/// failure latency again.
enum SpeechEngineError: LocalizedError, Equatable {
    /// Network down, server rejected us (e.g. Edge's 403), timeout.
    case serviceUnavailable(String)
    /// Local model not downloaded / not loaded yet.
    case notInstalled(String)
    case unsupportedLanguage(String)
    case synthesisFailed(String)

    var errorDescription: String? {
        switch self {
        case .serviceUnavailable(let s): return "Service unavailable: \(s)"
        case .notInstalled(let s):       return "Not installed: \(s)"
        case .unsupportedLanguage(let s): return "Unsupported language: \(s)"
        case .synthesisFailed(let s):    return "Synthesis failed: \(s)"
        }
    }
}

protocol SpeechEngine: AnyObject {
    var kind: SpeechEngineKind { get }

    /// Cheap, synchronous check: can this engine speak `language` at all?
    func supports(_ language: ReadingLanguage) -> Bool

    /// Get ready for an imminent synthesize (open a connection, load a model).
    /// Called the moment a read hotkey fires, overlapping text capture.
    func prewarm()

    /// Why the engine can't run right now regardless of language (missing API
    /// key, model not downloaded), or nil when it's ready. Routing skips it.
    var unavailableReason: String? { get }

    /// Voices usable for `language` (may hit the network or disk).
    func voices(for language: ReadingLanguage) async -> [VoiceOption]

    /// Synthesize one section at 1× speed. Throw `SpeechEngineError` so the
    /// router can fall back.
    func synthesize(_ text: String, language: ReadingLanguage, voiceID: String) async throws -> SynthesizedSpeech

    /// Same, but an engine that can stream also feeds `live` as audio arrives
    /// so playback starts before synthesis ends. Engines that can't ignore it
    /// (the default).
    func synthesize(_ text: String, language: ReadingLanguage, voiceID: String,
                    live: LiveSpeechSink?) async throws -> SynthesizedSpeech
}

extension SpeechEngine {
    var unavailableReason: String? { nil }
    func prewarm() {}

    func synthesize(_ text: String, language: ReadingLanguage, voiceID: String,
                    live: LiveSpeechSink?) async throws -> SynthesizedSpeech {
        try await synthesize(text, language: language, voiceID: voiceID)
    }
}

/// Receives a section's audio while it's still being synthesized. Called from
/// any thread, in order. A streaming engine must end with exactly one of
/// `complete()` (right before returning) or `abort()` (before throwing, if it
/// sent anything) — the reader then either keeps the streamed audio or
/// restarts the section from whatever engine answered instead.
protocol LiveSpeechSink: AnyObject, Sendable {
    /// Next bytes of an MP3 stream (frames may be split across calls).
    func audio(_ mp3: Data)
    /// Every word timing known so far (replaces the previous list).
    func words(_ words: [WordTiming])
    func complete()
    func abort()
}

extension ReadingLanguage {
    /// Whether a voice/locale tag ("de-DE", "de", "DE-ch") belongs to this
    /// language: exact match, bare base code, or same base with any region.
    func matches(localeTag tag: String) -> Bool {
        let t = tag.lowercased()
        return t == code.lowercased() || t == base || t.hasPrefix(base + "-")
    }
}

extension WordTiming {
    /// Approximate word timings for engines without word marks: spread
    /// `duration` over the words proportionally to their length (plus a small
    /// fixed cost per word, so short words aren't instant).
    static func estimate(text: String, duration: TimeInterval) -> [WordTiming] {
        let ns = text as NSString
        var ranges: [NSRange] = []
        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length),
                               options: [.byWords, .substringNotRequired]) { _, range, _, _ in
            ranges.append(range)
        }
        guard !ranges.isEmpty, duration > 0 else { return [] }
        let perWordOverhead = 2.0
        let weights = ranges.map { Double($0.length) + perWordOverhead }
        let total = weights.reduce(0, +)
        var t: TimeInterval = 0
        return zip(ranges, weights).map { range, w in
            let d = duration * w / total
            defer { t += d }
            return WordTiming(range: range, start: t, duration: d)
        }
    }
}

/// One navigable chunk of a narration (roughly a sentence or two). The reader
/// synthesizes, plays, highlights, and skips by section.
struct ReadingSection: Identifiable, Equatable {
    let id: Int
    let text: String
    /// Always one of the user's reading languages.
    let language: ReadingLanguage
}
