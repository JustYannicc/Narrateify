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
        let qwen3Progress: Double? = { if case .downloading(let p, _) = qwen3.state { return p } else { return nil } }()
        let supertonicProgress: Double? = {
            if case .downloading(let p) = supertonic.state { return p } else { return nil }
        }()
        return [
            ModelInfo(id: "supertonic-3", engine: SpeechEngineKind.supertonic.rawValue, name: "Supertonic 3",
                      languages: ["31 incl. en, de"], downloadBytes: SupertonicModelStore.downloadSize,
                      memory: "~120 MB while loaded", quality: 7, speed: "~100–150 ms per sentence",
                      license: "OpenRAIL-M", onDemand: false, installed: supertonic.isInstalled,
                      loaded: supertonicEngine.isLoaded, unsupported: nil, installing: supertonicProgress),
            ModelInfo(id: Qwen3Engine.modelName, engine: SpeechEngineKind.qwen3.rawValue,
                      name: "Qwen3-TTS 1.7B (8-bit, MLX)",
                      languages: Array(Qwen3Engine.languages).sorted(), downloadBytes: Qwen3ModelStore.downloadSize,
                      memory: "~3 GB while loaded (own process, freed when idle)", quality: 9,
                      speed: "about real time on Apple silicon, plus a few seconds to load",
                      license: "Apache-2.0", onDemand: true, installed: qwen3.isInstalled,
                      loaded: qwen3Engine.isLoaded, unsupported: Qwen3ModelStore.unsupportedReason,
                      installing: qwen3Progress),
        ]
    }

    /// `model` → its engine: a catalog id ("qwen3-tts-1.7b") or an engine name.
    func modelEngine(_ id: String) -> SpeechEngineKind? {
        let key = id.lowercased()
        if let model = models.first(where: { $0.id == key }) { return SpeechEngineKind(rawValue: model.engine) }
        return SpeechEngineKind.allCases.first { $0.isLocal && $0.rawValue.lowercased() == key }
    }

    func isInstalled(_ engine: SpeechEngineKind) -> Bool {
        switch engine {
        case .supertonic: return supertonic.isInstalled
        case .qwen3: return qwen3.isInstalled
        default: return true
        }
    }

    func installModel(for engine: SpeechEngineKind) async throws {
        switch engine {
        case .supertonic: try await supertonic.installAndWait()
        case .qwen3: try await qwen3.install()
        default: break
        }
    }

    func uninstallModel(for engine: SpeechEngineKind) async throws {
        switch engine {
        case .supertonic:
            await supertonicEngine.unloadAndWait()
            try supertonic.uninstall()
        case .qwen3:
            qwen3Engine.unload()
            try await qwen3.uninstall()
        default: break
        }
    }
}
