import AVFoundation
import Foundation
import MLX
import Qwen3TTS

// narrateify-qwen3: runs Qwen3-TTS (MLX) for the Narrateify app in its own
// process, so the ~3 GB model is fully freed when this exits (idle timeout or
// the app closing stdin), and an MLX/GPU crash can't take the app down.
//
//   narrateify-qwen3 install --model-id ID --model-dir D --tokenizer-dir T
//       downloads + verifies; prints {"progress":0.4,"message":"…"} lines, then {"done":true}
//   narrateify-qwen3 serve --model-dir D --tokenizer-dir T [--idle SECONDS]
//       prints {"ready":true,"load_seconds":…}, then answers one JSON line per request:
//       {"id":1,"text":"…","language":"de","reference":"/voice.wav"?,"out":"/tmp/x.wav"}
//       → {"id":1,"samples":N,"sample_rate":24000} or {"id":1,"error":"…"}

let tokenizerModelID = "Qwen/Qwen3-TTS-Tokenizer-12Hz"
let output = NSLock()

func emit(_ object: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
    output.withLock { FileHandle.standardOutput.write(data + Data("\n".utf8)) }
}

func fail(_ message: String) -> Never {
    emit(["error": message])
    exit(1)
}

func option(_ name: String) -> String? {
    let args = CommandLine.arguments
    guard let i = args.firstIndex(of: "--\(name)"), i + 1 < args.count else { return nil }
    return args[i + 1]
}

func directory(_ name: String) -> URL {
    guard let path = option(name) else { fail("missing --\(name)") }
    return URL(fileURLWithPath: path, isDirectory: true)
}

func readAudio(_ path: String) throws -> ([Float], Int) {
    let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
    guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else {
        throw NSError(domain: "qwen3", code: 1, userInfo: [NSLocalizedDescriptionKey: "can't read \(path)"])
    }
    try file.read(into: buffer)
    let samples = Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
    return (samples, Int(file.processingFormat.sampleRate))
}

func writeAudio(_ samples: [Float], to path: String) throws {
    let format = AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1)!
    guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(max(samples.count, 1))) else { return }
    buffer.frameLength = AVAudioFrameCount(samples.count)
    samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
    let file = try AVAudioFile(forWriting: URL(fileURLWithPath: path), settings: format.settings)
    try file.write(from: buffer)
}

func install() async {
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

func serve() async {
    let idle = TimeInterval(option("idle").flatMap(Double.init) ?? 600)
    let started = Date()
    let model: Qwen3TTSModel
    do {
        // Offline: a missing file is an error here, never a silent multi-GB download.
        model = try await Qwen3TTSModel.fromPretrained(
            modelId: option("model-id") ?? Qwen3TTSModel.defaultModelId, tokenizerModelId: tokenizerModelID,
            cacheDir: directory("model-dir"), tokenizerCacheDir: directory("tokenizer-dir"),
            offlineMode: true, wiredMemoryPolicy: .none)
    } catch {
        fail("load failed: \(error.localizedDescription)")
    }
    // MLX keeps freed GPU buffers cached for reuse; uncapped that roughly
    // doubled the footprint (6.8 GB for 2.4 GB of weights). Keep a small
    // cache and drop it after each request.
    Memory.cacheLimit = 256 << 20
    Memory.clearCache()
    emit(["ready": true, "load_seconds": Date().timeIntervalSince(started)])

    // Quit after `idle` seconds without a request; the app respawns us on demand.
    let lastUse = NSLock()
    nonisolated(unsafe) var last = Date()
    let timer = DispatchSource.makeTimerSource(queue: .global())
    timer.schedule(deadline: .now() + 5, repeating: 5)
    timer.setEventHandler {
        if lastUse.withLock({ Date().timeIntervalSince(last) }) > idle { exit(0) }
    }
    timer.resume()

    while let line = readLine(strippingNewline: true) {
        lastUse.withLock { last = .distantFuture }   // busy: never idle mid-request
        defer { lastUse.withLock { last = Date() } }
        guard let data = line.data(using: .utf8),
              let request = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
        let id = request["id"] ?? NSNull()
        guard let text = request["text"] as? String, let out = request["out"] as? String else {
            emit(["id": id, "error": "text and out are required"]); continue
        }
        let language = request["language"] as? String ?? "en"
        do {
            let samples: [Float]
            if let reference = request["reference"] as? String {
                let (audio, rate) = try readAudio(reference)
                samples = model.synthesizeWithVoiceClone(text: text, referenceAudio: audio,
                                                         referenceSampleRate: rate, language: language)
            } else {
                samples = model.synthesize(text: text, language: language, languageExplicit: true)
            }
            guard !samples.isEmpty else { emit(["id": id, "error": "the model produced no audio"]); continue }
            try writeAudio(samples, to: out)
            Memory.clearCache()
            emit(["id": id, "samples": samples.count, "sample_rate": 24_000])
        } catch {
            emit(["id": id, "error": error.localizedDescription])
        }
    }
}

switch CommandLine.arguments.dropFirst().first {
case "install": await install()
case "serve": await serve()
default: fail("usage: narrateify-qwen3 install|serve …")
}
