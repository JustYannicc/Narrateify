import Foundation

/// Adapts the existing ElevenLabs/OpenAI clients to `SpeechEngine` so they can
/// sit in a language's fallback chain. Both are multilingual, return MP3 and
/// have no word marks (the reader estimates highlighting). Credentials are read
/// lazily (on the main actor, where AppState owns them) so Settings changes
/// apply without rebuilding the engine.

final class ElevenLabsSpeechEngine: SpeechEngine {
    let kind: SpeechEngineKind = .elevenLabs

    struct Config {
        var apiKey: String
        var modelId: String
        var settings: ElevenLabsClient.VoiceSettings
        var voices: [ElevenLabsClient.Voice]
        /// Used when a route has no voice picked yet.
        var defaultVoice: String
    }
    private let config: @MainActor () -> Config

    init(config: @escaping @MainActor () -> Config) { self.config = config }

    // The multilingual/flash models cover both of our languages and many more.
    func supports(_ language: ReadingLanguage) -> Bool { true }
    // Only read from the main actor (router, settings UI).
    var unavailableReason: String? {
        MainActor.assumeIsolated { config().apiKey.isEmpty } ? "Add an API key in Settings → Cloud" : nil
    }

    func voices(for language: ReadingLanguage) async -> [VoiceOption] {
        await MainActor.run { config() }.voices.map { VoiceOption(id: $0.voiceId, name: $0.name, languages: ["*"]) }
    }

    func synthesize(_ text: String, language: ReadingLanguage, voiceID: String) async throws -> SynthesizedSpeech {
        let c = await MainActor.run { config() }
        guard !c.apiKey.isEmpty else { throw SpeechEngineError.notInstalled("ElevenLabs API key missing") }
        var settings = c.settings
        settings.speed = 1.0   // playback applies speed
        let client = ElevenLabsClient(apiKey: c.apiKey, voiceId: voiceID.isEmpty ? c.defaultVoice : voiceID, modelId: c.modelId, settings: settings)
        return try await cloudCall { SynthesizedSpeech(audio: try await client.synthesize(text: text),
                                                       fileExtension: "mp3", words: []) }
    }
}

final class OpenAISpeechEngine: SpeechEngine {
    let kind: SpeechEngineKind = .openAI

    struct Config {
        var apiKey: String
        var model: String
        var defaultVoice: String
    }
    private let config: @MainActor () -> Config

    init(config: @escaping @MainActor () -> Config) { self.config = config }

    func supports(_ language: ReadingLanguage) -> Bool { true }
    // Only read from the main actor (router, settings UI).
    var unavailableReason: String? {
        MainActor.assumeIsolated { config().apiKey.isEmpty } ? "Add an API key in Settings → Cloud" : nil
    }

    func voices(for language: ReadingLanguage) async -> [VoiceOption] {
        OpenAIClient.voices.map { VoiceOption(id: $0, name: $0.capitalized, languages: ["*"]) }
    }

    func synthesize(_ text: String, language: ReadingLanguage, voiceID: String) async throws -> SynthesizedSpeech {
        let c = await MainActor.run { config() }
        guard !c.apiKey.isEmpty else { throw SpeechEngineError.notInstalled("OpenAI API key missing") }
        let client = OpenAIClient(apiKey: c.apiKey, voice: voiceID.isEmpty ? c.defaultVoice : voiceID, model: c.model, speed: 1.0)
        return try await cloudCall { SynthesizedSpeech(audio: try await client.synthesize(text: text),
                                                       fileExtension: "mp3", words: []) }
    }
}

/// Network failures and 5xx/429 bench the engine; other HTTP errors (bad key,
/// bad voice) are configuration problems that still fall through the chain.
/// A cancelled request is the reader skipping ahead, not an outage.
private func cloudCall(_ body: () async throws -> SynthesizedSpeech) async throws -> SynthesizedSpeech {
    do {
        return try await body()
    } catch is CancellationError {
        throw CancellationError()
    } catch let error as URLError {
        if error.code == .cancelled { throw CancellationError() }
        throw SpeechEngineError.serviceUnavailable(error.localizedDescription)
    } catch {
        if let code = httpStatus(of: error), code == 429 || code >= 500 {
            throw SpeechEngineError.serviceUnavailable(error.localizedDescription)
        }
        throw SpeechEngineError.synthesisFailed(error.localizedDescription)
    }
}

private func httpStatus(of error: Error) -> Int? {
    switch error {
    case ElevenLabsClient.ClientError.http(let code, _): return code
    case OpenAIClient.OpenAIError.http(let code, _): return code
    default: return nil
    }
}
