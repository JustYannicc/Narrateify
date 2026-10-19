import AVFoundation
import Foundation

// narrateify-models: runs Narrateify's on-demand local models (Qwen3-TTS on
// MLX, Kokoro on ONNX Runtime) in their own process, so a model's memory is
// fully freed when it exits (idle timeout, or the app closing stdin) and a
// GPU/runtime crash can't take the app down. One process per model.
//
//   narrateify-models qwen3 install --model-id ID --model-dir D --tokenizer-dir T
//       downloads + verifies; prints {"progress":0.4,"message":"…"} lines, then {"done":true}
//   narrateify-models qwen3 serve --model-dir D --tokenizer-dir T [--idle SECONDS]
//   narrateify-models kokoro serve --model-dir D [--lexicon FILE] [--idle SECONDS]
//       print {"ready":true,"load_seconds":…}, then answer one JSON line per request:
//       {"id":1,"text":"…","language":"en","voice":"af_heart"|"/ref.wav","out":"/tmp/x.wav"}
//       → {"id":1,"samples":N,"sample_rate":24000} or {"id":1,"error":"…"}

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

struct RequestError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

func writeAudio(_ samples: [Float], to path: String) throws {
    let format = AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1)!
    guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(max(samples.count, 1))) else { return }
    buffer.frameLength = AVAudioFrameCount(samples.count)
    samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
    let file = try AVAudioFile(forWriting: URL(fileURLWithPath: path), settings: format.settings)
    try file.write(from: buffer)
}

/// The request loop shared by every model: announce readiness, answer one
/// JSON line at a time, quit after `--idle` seconds without a request.
func serve(load: () async throws -> (_ request: [String: Any]) throws -> [Float], afterEach: () -> Void = {}) async {
    let idle = TimeInterval(option("idle").flatMap(Double.init) ?? 600)
    let started = Date()
    let handle: ([String: Any]) throws -> [Float]
    do {
        handle = try await load()
    } catch {
        fail("load failed: \(error.localizedDescription)")
    }
    emit(["ready": true, "load_seconds": Date().timeIntervalSince(started)])

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
        guard request["text"] is String, let out = request["out"] as? String else {
            emit(["id": id, "error": "text and out are required"]); continue
        }
        do {
            let samples = try handle(request)
            guard !samples.isEmpty else { emit(["id": id, "error": "the model produced no audio"]); continue }
            try writeAudio(samples, to: out)
            afterEach()
            emit(["id": id, "samples": samples.count, "sample_rate": 24_000])
        } catch {
            emit(["id": id, "error": error.localizedDescription])
        }
    }
}

let args = CommandLine.arguments.dropFirst()
switch (args.first, args.dropFirst().first) {
case ("qwen3", "install"): await Qwen3.install()
case ("qwen3", "serve"): await Qwen3.serve()
case ("kokoro", "serve"): await serve(load: Kokoro.load)
default: fail("usage: narrateify-models qwen3 install|serve … | kokoro serve …")
}
