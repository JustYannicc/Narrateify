import AVFoundation
import Foundation
import MLX
import Qwen3TTS

/// Qwen3-TTS 1.7B Base on MLX. Voices are cloned from a reference clip
/// (`voice` is its path); the app supplies one for every request.
enum Qwen3 {
    static let tokenizerModelID = "Qwen/Qwen3-TTS-Tokenizer-12Hz"

    static func install() async {
        guard let modelID = option("model-id") else { fail("missing --model-id") }
        do {
            let model = try await Qwen3TTSModel.fromPretrained(
                modelId: modelID, tokenizerModelId: tokenizerModelID,
                cacheDir: directory("model-dir"), tokenizerCacheDir: directory("tokenizer-dir"),
                wiredMemoryPolicy: .none,
                progressHandler: { progress, message in emit(["progress": progress, "message": message]) })
            model.unload()
            emit(["done": true])
        } catch {
            fail("install failed: \(error.localizedDescription)")
        }
    }

    static func serve() async {
        await NarrateifyModels.serve(load: {
            // Offline: a missing file is an error here, never a silent multi-GB download.
            let model = try await Qwen3TTSModel.fromPretrained(
                modelId: option("model-id") ?? Qwen3TTSModel.defaultModelId, tokenizerModelId: tokenizerModelID,
                cacheDir: directory("model-dir"), tokenizerCacheDir: directory("tokenizer-dir"),
                offlineMode: true, wiredMemoryPolicy: .none)
            // MLX keeps freed GPU buffers cached for reuse; uncapped that roughly
            // doubled the footprint (6.8 GB for 2.4 GB of weights).
            Memory.cacheLimit = 256 << 20
            Memory.clearCache()
            return { request in
                let text = request["text"] as? String ?? ""
                let language = request["language"] as? String ?? "en"
                guard let reference = request["voice"] as? String else {
                    return model.synthesize(text: text, language: language, languageExplicit: true)
                }
                let (audio, rate) = try readAudio(reference)
                return model.synthesizeWithVoiceClone(text: text, referenceAudio: audio,
                                                      referenceSampleRate: rate, language: language)
            }
        }, afterEach: { Memory.clearCache() })
    }

    private static func readAudio(_ path: String) throws -> ([Float], Int) {
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else {
            throw RequestError(message: "can't read \(path)")
        }
        try file.read(into: buffer)
        return (Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength))),
                Int(file.processingFormat.sampleRate))
    }
}
