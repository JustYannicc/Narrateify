import Foundation

/// VoiceInk-style model cards: what each engine costs you in time, memory and
/// privacy, and roughly how good it sounds. Speed/quality are 0–10 judgments
/// for EN/DE reading; RAM and disk are measured on Apple silicon (see
/// `measuredNote`). "Measured" time-to-audio comes from the in-app benchmark.
struct EngineCard: Identifiable {
    let kind: SpeechEngineKind
    let speed: Int
    let quality: Int
    let ram: String
    let disk: String
    let languages: String
    let privacy: String
    let blurb: String

    var id: SpeechEngineKind { kind }
}

enum EngineCatalog {
    static let cards: [EngineCard] = [
        EngineCard(kind: .edge, speed: 8, quality: 9, ram: "~0", disk: "0",
                   languages: "100+ (incl. multilingual voices)",
                   privacy: "Text sent to Microsoft",
                   blurb: "Microsoft's neural Read Aloud voices — the same ones SuperCmd and the Read Aloud extension use. Free, unofficial endpoint: it can break without notice (it started failing in parts of Europe on 2026-10-10)."),
        EngineCard(kind: .supertonic, speed: 9, quality: 7, ram: "~120 MB while loaded (Core ML), ~0 unloaded",
                   disk: "~220 MB (macOS 15+), ~400 MB on 14",
                   languages: "31 (incl. EN, DE)",
                   privacy: "Fully on-device",
                   blurb: "Supertone's on-device model (the one in Read Aloud). Core ML + ONNX Runtime on the CPU — no Python, no GPU; ~100–150 ms per sentence on Apple silicon. The best local fallback for Edge."),
        EngineCard(kind: .apple, speed: 10, quality: 5, ram: "~0 (system)", disk: "0–500 MB per voice",
                   languages: "Depends on installed voices",
                   privacy: "Fully on-device",
                   blurb: "macOS's built-in voices. Always available, so it's the last resort in every chain. Download Premium voices in System Settings → Accessibility → Spoken Content for much better quality."),
        EngineCard(kind: .elevenLabs, speed: 6, quality: 10, ram: "~0", disk: "0",
                   languages: "29+ (multilingual models)",
                   privacy: "Text sent to ElevenLabs",
                   blurb: "Best-sounding cloud voices. Paid per character; needs an API key."),
        EngineCard(kind: .openAI, speed: 6, quality: 8, ram: "~0", disk: "0",
                   languages: "50+",
                   privacy: "Text sent to OpenAI",
                   blurb: "Natural multilingual cloud voices. Paid; needs an API key."),
        EngineCard(kind: .kokoro, speed: 8, quality: 9, ram: "~0.5 GB while loaded (own process, freed when idle)",
                   disk: "~345 MB", languages: "8 (EN US/UK, ES, FR, IT, PT, HI, JA, ZH — no German)",
                   privacy: "Fully on-device",
                   blurb: "Kokoro v1.0 (82M), the af_heart voice from the Athena explainer: the same kokoro-v1.0.onnx kokoro-onnx uses, run natively on ONNX Runtime with a misaki-style phonemizer (no Python, no espeak). For voiceovers: never in a reading chain, only used when a CLI/API/MCP call asks for it (model kokoro). ~8× faster than real time. Fix a name's pronunciation in ~/Library/Application Support/Narrateify/kokoro-lexicon.json. Apache-2.0. Apple silicon + macOS 15."),
        EngineCard(kind: .qwen3, speed: 3, quality: 9, ram: "~3 GB while loaded (own process, freed when idle)",
                   disk: "~2.9 GB", languages: "10 (incl. EN, DE)",
                   privacy: "Fully on-device",
                   blurb: "Alibaba's Qwen3-TTS 1.7B on MLX: the big model for voiceovers, not everyday reading. Never in a reading chain; only used when a CLI/API/MCP call asks for it (model qwen3-tts-1.7b). Loads on demand (a few seconds), about real time on Apple silicon, and quits after the idle timeout. Voices are cloned from the Supertonic voices or from your own clip. Apache-2.0. Apple silicon + macOS 15."),
    ]
}
