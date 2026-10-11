import Foundation

/// Adapts the existing ElevenLabs/OpenAI clients to `SpeechEngine` so they can
/// sit in a language's fallback chain. Both are multilingual, return MP3 and
/// have no word marks (the reader estimates highlighting). Credentials are read
/// lazily so Settings changes apply without rebuilding the engine.

final class ElevenLabsSpeechEngine: SpeechEngine {
    let kind: SpeechEngineKind = .elevenLabs

    struct Config {
        var apiKey: String
        var modelId: String
        var settings: ElevenLabsClient.VoiceSettings
        var voices: [ElevenLabsClient.Voice]
    }
    private let config: () -> Config

    init(config: @escaping () -> Config) { self.config = config }

    // The multilingual/flash models cover both of our languages and many more.
    func supports(_ language: ReadingLanguage) -> Bool { !config().apiKey.isEmpty }

    func voices(for language: ReadingLanguage) async -> [VoiceOption] {
        config().voices.map { VoiceOption(id: $0.voiceId, name: $0.name, languages: ["*"]) }
    }

    func synthesize(_ text: String, language: ReadingLanguage, voiceID: String) async throws -> SynthesizedSpeech {
        let c = config()
        guard !c.apiKey.isEmpty else { throw SpeechEngineError.notInstalled("ElevenLabs API key missing") }
        var settings = c.settings
        settings.speed = 1.0   // playback applies speed
        let client = ElevenLabsClient(apiKey: c.apiKey, voiceId: voiceID, modelId: c.modelId, settings: settings)
        return try await cloudCall { SynthesizedSpeech(audio: try await client.synthesize(text: text),
                                                       fileExtension: "mp3", words: []) }
    }
}

final class OpenAISpeechEngine: SpeechEngine {
    let kind: SpeechEngineKind = .openAI

    struct Config {
        var apiKey: String
        var model: String
    }
    private let config: () -> Config

    init(config: @escaping () -> Config) { self.config = config }

    func supports(_ language: ReadingLanguage) -> Bool { !config().apiKey.isEmpty }

    func voices(for language: ReadingLanguage) async -> [VoiceOption] {
        OpenAIClient.voices.map { VoiceOption(id: $0, name: $0.capitalized, languages: ["*"]) }
    }

    func synthesize(_ text: String, language: ReadingLanguage, voiceID: String) async throws -> SynthesizedSpeech {
        let c = config()
        guard !c.apiKey.isEmpty else { throw SpeechEngineError.notInstalled("OpenAI API key missing") }
        let client = OpenAIClient(apiKey: c.apiKey, voice: voiceID, model: c.model, speed: 1.0)
        return try await cloudCall { SynthesizedSpeech(audio: try await client.synthesize(text: text),
                                                       fileExtension: "mp3", words: []) }
    }
}

/// Network failures and 5xx/429 bench the engine; other HTTP errors (bad key,
/// bad voice) are configuration problems that still fall through the chain.
private func cloudCall(_ body: () async throws -> SynthesizedSpeech) async throws -> SynthesizedSpeech {
    do {
        return try await body()
    } catch is CancellationError {
        throw CancellationError()
    } catch let error as URLError {
        throw SpeechEngineError.serviceUnavailable(error.localizedDescription)
    } catch let error as ElevenLabsClient.ClientError {
        if case .http(let code, _) = error, code == 429 || code >= 500 {
            throw SpeechEngineError.serviceUnavailable(error.localizedDescription)
        }
        throw SpeechEngineError.synthesisFailed(error.localizedDescription)
    } catch let error as OpenAIClient.OpenAIError {
        if case .http(let code, _) = error, code == 429 || code >= 500 {
            throw SpeechEngineError.serviceUnavailable(error.localizedDescription)
        }
        throw SpeechEngineError.synthesisFailed(error.localizedDescription)
    } catch {
        throw SpeechEngineError.synthesisFailed(error.localizedDescription)
    }
}
