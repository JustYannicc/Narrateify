import Foundation

/// Kokoro v1.0 (82M): the voice the Athena explainer used (af_heart), run
/// natively — the same `kokoro-v1.0.onnx` + `voices-v1.0.bin` as
/// kokoro-onnx, on ONNX Runtime in the `narrateify-models` helper, with a
/// misaki-style English phonemizer instead of Python + espeak.
///
/// On demand like Qwen3: never in a reading chain, only used when a call
/// asks for `model: "kokoro"`, and its process quits after the idle timeout.
/// No German (Kokoro has no German voices).
final class KokoroEngine: SpeechEngine, @unchecked Sendable {
    let kind: SpeechEngineKind = .kokoro
    static let modelName = "kokoro"
    static let aliases: Set<String> = ["kokoro", "kokoro-v1.0", "kokoro-82m"]
    static let defaultVoiceID = "af_heart"

    nonisolated static let directory = OnDemandModelStore.modelsDirectory("kokoro-v1.0")
    /// Your own pronunciations for Kokoro: {"Yannic": "jˈænɪk"} in misaki phonemes.
    static var lexiconFile: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Narrateify/kokoro-lexicon.json")
    }

    /// Kokoro's voice prefixes: first letter = language, second = gender.
    static let languagePrefixes: [Character: String] = [
        "a": "en-US", "b": "en-GB", "e": "es", "f": "fr", "h": "hi", "i": "it", "j": "ja", "p": "pt", "z": "zh",
    ]
    static let languages: Set<String> = ["en", "es", "fr", "hi", "it", "ja", "pt", "zh"]

    /// Every voice in voices-v1.0.bin (v1.0's 54).
    static let voiceIDs: [String] = [
        "af_alloy", "af_aoede", "af_bella", "af_heart", "af_jessica", "af_kore", "af_nicole", "af_nova", "af_river",
        "af_sarah", "af_sky", "am_adam", "am_echo", "am_eric", "am_fenrir", "am_liam", "am_michael", "am_onyx",
        "am_puck", "am_santa", "bf_alice", "bf_emma", "bf_isabella", "bf_lily", "bm_daniel", "bm_fable",
        "bm_george", "bm_lewis", "ef_dora", "em_alex", "em_santa", "ff_siwis", "hf_alpha", "hf_beta", "hm_omega",
        "hm_psi", "if_sara", "im_nicola", "jf_alpha", "jf_gongitsune", "jf_nezumi", "jf_tebukuro", "jm_kumo",
        "pf_dora", "pm_alex", "pm_santa", "zf_xiaobei", "zf_xiaoni", "zf_xiaoxiao", "zf_xiaoyi", "zm_yunjian",
        "zm_yunxi", "zm_yunxia", "zm_yunyang",
    ]

    /// The model and voices from kokoro-onnx's release (reused from
    /// ~/.cache/kokoro-models when they're already there), plus the
    /// phonemizer's dictionaries and G2P from Hugging Face. ~345 MB.
    @MainActor static func makeStore() -> OnDemandModelStore {
        let release = "https://github.com/thewh1teagle/kokoro-onnx/releases/download/model-files-v1.0/"
        let g2p = "https://huggingface.co/aufklarer/Kokoro-82M-CoreML/resolve/f8ff771e4cab0bb3368e8af3a090a7e847485401/"
        let cache = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cache/kokoro-models")
        var files: [(url: URL, path: String, size: Int64, localCopy: URL?)] = [
            (URL(string: release + "kokoro-v1.0.onnx")!, "kokoro-v1.0.onnx", 325_532_387, cache.appendingPathComponent("kokoro-v1.0.onnx")),
            (URL(string: release + "voices-v1.0.bin")!, "voices-v1.0.bin", 28_214_398, cache.appendingPathComponent("voices-v1.0.bin")),
        ]
        let g2pFiles: [(String, Int64)] = [
            ("vocab_index.json", 2_034), ("g2p_vocab.json", 1_665), ("us_gold.json", 3_001_196), ("us_silver.json", 3_105_352),
            ("G2PEncoder.mlmodelc/coremldata.bin", 398), ("G2PEncoder.mlmodelc/metadata.json", 2_034),
            ("G2PEncoder.mlmodelc/model.mil", 20_392), ("G2PEncoder.mlmodelc/weights/weight.bin", 694_592),
            ("G2PEncoder.mlmodelc/analytics/coremldata.bin", 243),
            ("G2PDecoder.mlmodelc/coremldata.bin", 545), ("G2PDecoder.mlmodelc/metadata.json", 3_064),
            ("G2PDecoder.mlmodelc/model.mil", 19_737), ("G2PDecoder.mlmodelc/weights/weight.bin", 828_030),
            ("G2PDecoder.mlmodelc/analytics/coremldata.bin", 243),
        ]
        files += g2pFiles.map { (URL(string: g2p + $0.0)!, "g2p/" + $0.0, $0.1, nil) }
        let total = files.reduce(0) { $0 + $1.size }
        return OnDemandModelStore(directory: directory, downloadSize: total) { directory, progress in
            try await OnDemandModelStore.fetchFiles(files, into: directory, progress: progress)
        }
    }

    private let worker = HelperWorker(secondsPerCharacter: 0.01) { idle in
        ["kokoro", "serve", "--model-dir", KokoroEngine.directory.path,
         "--lexicon", KokoroEngine.lexiconFile.path, "--idle", String(idle)]
    }
    private let lock = NSLock()
    private var _idleUnloadAfter: TimeInterval = 600

    /// The helper quits after this long without a request (applies from its next start).
    var idleUnloadAfter: TimeInterval {
        get { lock.withLock { _idleUnloadAfter } }
        set { lock.withLock { _idleUnloadAfter = newValue } }
    }

    var isLoaded: Bool { worker.isRunning }
    func unload() { worker.stop() }

    static let notInstalledMessage =
        "Kokoro isn't installed (about 345 MB). Run `narrateify install kokoro`, or retry with --install (API/MCP: install: true)."

    // MARK: SpeechEngine

    func supports(_ language: ReadingLanguage) -> Bool { Self.languages.contains(language.base) }

    var unavailableReason: String? {
        if let reason = ModelHelper.unsupportedReason { return reason }
        return OnDemandModelStore.isInstalled(at: Self.directory) ? nil : Self.notInstalledMessage
    }

    /// Voices for the language; English lists American then British.
    func voices(for language: ReadingLanguage) async -> [VoiceOption] {
        guard supports(language) else { return [] }
        return Self.voiceIDs.compactMap { id in
            guard let tag = id.first.flatMap({ Self.languagePrefixes[$0] }), language.matches(localeTag: tag) else { return nil }
            let gender = id.dropFirst().first == "f" ? "Female" : "Male"
            let name = id.split(separator: "_").last.map { $0.prefix(1).uppercased() + $0.dropFirst() } ?? id
            return VoiceOption(id: id, name: "\(name) · \(gender) (\(tag))", languages: [tag])
        }
    }

    func synthesize(_ text: String, language: ReadingLanguage, voiceID: String) async throws -> SynthesizedSpeech {
        if let reason = unavailableReason { throw SpeechEngineError.notInstalled(reason) }
        guard supports(language) else {
            throw SpeechEngineError.unsupportedLanguage("Kokoro doesn't speak \(language.displayName)")
        }
        let voice = voiceID.isEmpty ? Self.defaultVoice(for: language) : voiceID
        guard Self.voiceIDs.contains(voice) else { throw SpeechEngineError.synthesisFailed("Unknown Kokoro voice \(voice)") }
        let audio = try await worker.synthesize(text, language: language.base, voice: voice, idleSeconds: idleUnloadAfter)
        return SynthesizedSpeech(audio: audio, fileExtension: "wav", words: [])
    }

    static func defaultVoice(for language: ReadingLanguage) -> String {
        if language.base == "en" { return language.code == "en-GB" ? "bf_emma" : defaultVoiceID }
        return voiceIDs.first { $0.first.flatMap { languagePrefixes[$0] }.map(language.matches(localeTag:)) ?? false } ?? defaultVoiceID
    }
}
