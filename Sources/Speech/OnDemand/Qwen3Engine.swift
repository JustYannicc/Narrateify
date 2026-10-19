import Foundation
import OSLog

private let log = Logger(category: "qwen3")

/// Qwen3-TTS 1.7B (Base): the big local model, for voiceovers rather than
/// everyday reading. Never in a language's default chain; only used when a
/// caller asks for it (`engine: "qwen3"` / `model: "qwen3-tts-1.7b"`).
///
/// It runs in a `narrateify-models` helper process, started on the first
/// call and exiting by itself after the idle timeout, so its ~3 GB is gone
/// when nobody's using it.
///
/// The Base model has no preset speakers, so every voice is cloned from a
/// reference clip: the built-in F1–M5 from the matching Supertonic voice
/// (rendered once, on first use), plus any clip you drop into
/// ~/Library/Application Support/Narrateify/Voices (or pass by path).
final class Qwen3Engine: SpeechEngine, @unchecked Sendable {
    let kind: SpeechEngineKind = .qwen3
    static let modelName = "qwen3-tts-1.7b"
    static let defaultVoiceID = "F1"

    static let modelID = "aufklarer/Qwen3-TTS-12Hz-1.7B-Base-MLX-8bit"
    nonisolated static let directory = OnDemandModelStore.modelsDirectory(modelName)
    nonisolated static var modelDirectory: URL { directory.appendingPathComponent("model", isDirectory: true) }
    nonisolated static var tokenizerDirectory: URL { directory.appendingPathComponent("tokenizer", isDirectory: true) }
    /// Reference clips the built-in voices are cloned from.
    nonisolated static var voicesDirectory: URL { directory.appendingPathComponent("voices", isDirectory: true) }

    /// Weights + speech tokenizer through the helper (Hugging Face, ~2.9 GB on disk).
    @MainActor static func makeStore() -> OnDemandModelStore {
        OnDemandModelStore(directory: directory, downloadSize: 2_900_000_000) { _, progress in
            for dir in [modelDirectory, tokenizerDirectory] {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            }
            try await OnDemandModelStore.runHelper(
                ["qwen3", "install", "--model-id", modelID,
                 "--model-dir", modelDirectory.path, "--tokenizer-dir", tokenizerDirectory.path],
                progress: progress)
        }
    }

    /// Languages the model was trained on.
    static let languages: Set<String> = ["en", "de", "zh", "ja", "ko", "fr", "ru", "pt", "es", "it"]

    static var customVoicesDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Narrateify/Voices", isDirectory: true)
    }
    private static let audioExtensions: Set<String> = ["wav", "m4a", "mp3", "aiff", "aif", "caf", "flac"]

    /// Renders a built-in voice's reference clip (WAV bytes) — Supertonic.
    private let makeReference: @Sendable (String) async throws -> Data
    private let worker = HelperWorker(secondsPerCharacter: 0.1) { idle in
        ["qwen3", "serve", "--model-id", Qwen3Engine.modelID,
         "--model-dir", Qwen3Engine.modelDirectory.path, "--tokenizer-dir", Qwen3Engine.tokenizerDirectory.path,
         "--idle", String(idle)]
    }
    private let lock = NSLock()
    private var _idleUnloadAfter: TimeInterval = 600

    init(makeReference: @escaping @Sendable (String) async throws -> Data) {
        self.makeReference = makeReference
    }

    /// The helper quits after this long without a request (applies from its next start).
    var idleUnloadAfter: TimeInterval {
        get { lock.withLock { _idleUnloadAfter } }
        set { lock.withLock { _idleUnloadAfter = newValue } }
    }

    var isLoaded: Bool { worker.isRunning }

    func unload() { worker.stop() }

    // MARK: SpeechEngine

    func supports(_ language: ReadingLanguage) -> Bool { Self.languages.contains(language.base) }

    var unavailableReason: String? {
        if let reason = ModelHelper.unsupportedReason { return reason }
        return OnDemandModelStore.isInstalled(at: Self.directory) ? nil : Self.notInstalledMessage
    }

    static let notInstalledMessage =
        "Qwen3-TTS 1.7B isn't installed (about 2.9 GB). Run `narrateify install \(modelName)`, or retry with --install (API/MCP: install: true)."

    func voices(for language: ReadingLanguage) async -> [VoiceOption] {
        guard supports(language) else { return [] }
        let builtIn = SupertonicEngine.voices.map {
            VoiceOption(id: $0.id, name: $0.name.replacingOccurrences(of: "(\($0.id))", with: "(cloned from Supertonic \($0.id))"),
                        languages: ["*"])
        }
        return builtIn + Self.customVoices()
    }

    /// Clips in ~/Library/Application Support/Narrateify/Voices, by file name.
    static func customVoices() -> [VoiceOption] {
        let files = (try? FileManager.default.contentsOfDirectory(at: customVoicesDirectory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { audioExtensions.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map { VoiceOption(id: $0.deletingPathExtension().lastPathComponent,
                               name: "\($0.deletingPathExtension().lastPathComponent) (your clip)", languages: ["*"]) }
    }

    func synthesize(_ text: String, language: ReadingLanguage, voiceID: String) async throws -> SynthesizedSpeech {
        if let reason = unavailableReason { throw SpeechEngineError.notInstalled(reason) }
        guard supports(language) else {
            throw SpeechEngineError.unsupportedLanguage("Qwen3-TTS doesn't speak \(language.code)")
        }
        let reference = try await referenceClip(for: voiceID.isEmpty ? Self.defaultVoiceID : voiceID)
        let audio = try await worker.synthesize(text, language: language.base, voice: reference.path,
                                                idleSeconds: idleUnloadAfter)
        return SynthesizedSpeech(audio: audio, fileExtension: "wav", words: [])
    }

    /// The clip a voice is cloned from: an absolute path, a clip in the
    /// Voices folder, or a built-in voice (rendered with Supertonic once).
    private func referenceClip(for voiceID: String) async throws -> URL {
        let fm = FileManager.default
        if voiceID.hasPrefix("/") {
            guard fm.fileExists(atPath: voiceID) else { throw SpeechEngineError.synthesisFailed("No reference clip at \(voiceID)") }
            return URL(fileURLWithPath: voiceID)
        }
        let custom = (try? fm.contentsOfDirectory(at: Self.customVoicesDirectory, includingPropertiesForKeys: nil))?
            .first { $0.deletingPathExtension().lastPathComponent == voiceID && Self.audioExtensions.contains($0.pathExtension.lowercased()) }
        if let custom { return custom }

        guard SupertonicEngine.voices.contains(where: { $0.id == voiceID }) else {
            throw SpeechEngineError.synthesisFailed("Unknown Qwen3 voice \(voiceID)")
        }
        let url = Self.voicesDirectory.appendingPathComponent("\(voiceID).wav")
        if fm.fileExists(atPath: url.path) { return url }
        log.notice("rendering reference clip for \(voiceID, privacy: .public)")
        let wav = try await makeReference(voiceID)
        try fm.createDirectory(at: Self.voicesDirectory, withIntermediateDirectories: true)
        try wav.write(to: url, options: .atomic)
        return url
    }

    /// What the built-in references say: ~10 s of calm, varied speech.
    static let referenceText = "Good morning. This is a reference recording, read calmly and clearly, so the larger model can learn what this voice sounds like."
}

