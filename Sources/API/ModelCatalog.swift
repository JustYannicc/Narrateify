import Foundation

/// The local models a caller can pick with `model` (API, CLI, MCP), and
/// install or remove. Each maps to one engine; a new model slots in with an
/// entry here plus its engine. Cloud and system voices aren't models you
/// install, so they're only reachable through `engine`.
struct ModelInfo: Encodable {
    let id: String
    let engine: String
    let name: String
    let languages: [String]
    let downloadBytes: Int64
    let memory: String
    /// 0–10 judgment for EN/DE voiceover quality (same scale as Engines cards).
    let quality: Int
    let speed: String
    let license: String
    /// Only used when asked for, never in a reading chain; unloads when idle.
    let onDemand: Bool
    let installed: Bool
    let loaded: Bool
    /// Why it can't run on this Mac at all (nil = it can).
    let unsupported: String?
    /// 0–1 while downloading.
    let installing: Double?

    enum CodingKeys: String, CodingKey {
        case id, engine, name, languages, downloadBytes = "download_bytes", memory, quality, speed, license
        case onDemand = "on_demand", installed, loaded, unsupported, installing
    }
}

@MainActor
extension AppState {
    var models: [ModelInfo] {
        func progress(_ store: OnDemandModelStore) -> Double? {
            if case .downloading(let p, _) = store.state { return p } else { return nil }
        }
        let supertonicProgress: Double? = {
            if case .downloading(let p) = supertonic.state { return p } else { return nil }
        }()
        return [
            ModelInfo(id: "supertonic-3", engine: SpeechEngineKind.supertonic.rawValue, name: "Supertonic 3",
                      languages: ["31 incl. en, de"], downloadBytes: SupertonicModelStore.downloadSize,
                      memory: "~120 MB while loaded", quality: 7, speed: "~100–150 ms per sentence",
                      license: "OpenRAIL-M", onDemand: false, installed: supertonic.isInstalled,
                      loaded: supertonicEngine.isLoaded, unsupported: nil, installing: supertonicProgress),
            ModelInfo(id: KokoroEngine.modelName, engine: SpeechEngineKind.kokoro.rawValue,
                      name: "Kokoro v1.0 (82M, ONNX), voice af_heart and 53 more",
                      languages: Array(KokoroEngine.languages).sorted(), downloadBytes: kokoro.downloadSize,
                      memory: "~0.5 GB while loaded (own process, freed when idle)", quality: 9,
                      speed: "~8× faster than real time, ~1 s to load",
                      license: "Apache-2.0", onDemand: true, installed: kokoro.isInstalled,
                      loaded: kokoroEngine.isLoaded, unsupported: ModelHelper.unsupportedReason,
                      installing: progress(kokoro)),
            ModelInfo(id: Qwen3Engine.modelName, engine: SpeechEngineKind.qwen3.rawValue,
                      name: "Qwen3-TTS 1.7B (8-bit, MLX), voices cloned from a clip",
                      languages: Array(Qwen3Engine.languages).sorted(), downloadBytes: qwen3.downloadSize,
                      memory: "~3 GB while loaded (own process, freed when idle)", quality: 7,
                      speed: "about 2× faster than real time, plus a few seconds to load",
                      license: "Apache-2.0", onDemand: true, installed: qwen3.isInstalled,
                      loaded: qwen3Engine.isLoaded, unsupported: ModelHelper.unsupportedReason,
                      installing: progress(qwen3)),
        ]
    }

    /// `model` → its engine: a catalog id ("kokoro", "qwen3-tts-1.7b"), an
    /// alias, or a local engine's name.
    func modelEngine(_ id: String) -> SpeechEngineKind? {
        let key = id.lowercased()
        if KokoroEngine.aliases.contains(key) { return .kokoro }
        if let model = models.first(where: { $0.id == key }) { return SpeechEngineKind(rawValue: model.engine) }
        return SpeechEngineKind.allCases.first { $0.isLocal && $0.rawValue.lowercased() == key }
    }

    /// The download behind an on-demand engine.
    func modelStore(for engine: SpeechEngineKind) -> OnDemandModelStore? {
        switch engine {
        case .qwen3: return qwen3
        case .kokoro: return kokoro
        default: return nil
        }
    }

    func isInstalled(_ engine: SpeechEngineKind) -> Bool {
        if engine == .supertonic { return supertonic.isInstalled }
        return modelStore(for: engine)?.isInstalled ?? true
    }

    func installModel(for engine: SpeechEngineKind) async throws {
        if engine == .supertonic { return try await supertonic.installAndWait() }
        try await modelStore(for: engine)?.install()
    }

    func uninstallModel(for engine: SpeechEngineKind) async throws {
        switch engine {
        case .supertonic:
            await supertonicEngine.unloadAndWait()
            try supertonic.uninstall()
        case .qwen3:
            qwen3Engine.unload()
            try await qwen3.uninstall()
        case .kokoro:
            kokoroEngine.unload()
            try await kokoro.uninstall()
        default: break
        }
    }
}
