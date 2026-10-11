// Supertonic 3 inference pipeline:
// duration predictor → text encoder (ONNX Runtime) → N flow-matching denoise
// steps → vocoder (SupertonicDecoder: Core ML or ONNX Runtime).
//
// Ported and adapted from the official Supertonic Swift example
// (https://github.com/supertone-inc/supertonic, swift/Sources/Helper.swift).
// Original code: MIT License, Copyright (c) 2025 Supertone Inc.
//
// Changes: flat Float buffers instead of nested arrays, typed errors instead of
// fatalError / force-unwraps, one voice per call (no batching), pluggable decoder.
//
// NOT thread-safe — SupertonicEngine serializes all access on one queue.

import Foundation
import OnnxRuntimeBindings

/// A voice's conditioning tensors (`style_ttl` [1,50,256], `style_dp` [1,8,16]).
struct SupertonicStyle {
    let ttl: ORTValue
    let dp: ORTValue
    /// `style_ttl` as plain floats, for the Core ML decoder.
    let ttlValues: [Float]
}

final class SupertonicRuntime {
    private struct Config: Decodable {
        struct AE: Decodable { let sample_rate: Int; let base_chunk_size: Int }
        struct TTL: Decodable { let chunk_compress_factor: Int; let latent_dim: Int }
        let ae: AE
        let ttl: TTL
    }

    private struct StyleFile: Decodable {
        struct Component: Decodable { let data: [[[Float]]]; let dims: [Int] }
        let style_ttl: Component
        let style_dp: Component
    }

    let sampleRate: Int
    let backend: SupertonicBackend
    private let chunkSize: Int      // audio samples per latent frame
    private let latentChannels: Int // latent_dim * chunk_compress_factor
    private let tokenizer: SupertonicTokenizer
    private let env: ORTEnv
    private let durationPredictor: ORTSession
    private let textEncoder: ORTSession
    private let decoder: SupertonicDecoder

    init(directory: URL, backend: SupertonicBackend = .current) throws {
        for file in SupertonicManifest.files(for: backend)
        where !FileManager.default.fileExists(atPath: directory.appendingPathComponent(file.path).path) {
            throw SpeechEngineError.notInstalled("Supertonic 3 model file missing: \(file.path)")
        }
        let url = { (rel: String) in directory.appendingPathComponent(rel) }
        let cfg = try JSONDecoder().decode(Config.self, from: Data(contentsOf: url(SupertonicFiles.config)))
        sampleRate = cfg.ae.sample_rate
        chunkSize = cfg.ae.base_chunk_size * cfg.ttl.chunk_compress_factor
        latentChannels = cfg.ttl.latent_dim * cfg.ttl.chunk_compress_factor
        tokenizer = try SupertonicTokenizer(indexerURL: url(SupertonicFiles.unicodeIndexer))
        self.backend = backend

        let env = try ORTEnv(loggingLevel: .warning)
        let options = try ORTSessionOptions()
        try options.setGraphOptimizationLevel(.all)
        // Measured on M5 Pro: 2–6 threads are as fast as ORT's all-cores
        // default (all cores is ~10% slower) and burn far less CPU.
        try options.setIntraOpNumThreads(Int32(min(4, ProcessInfo.processInfo.activeProcessorCount)))
        let session = { (file: URL) in try ORTSession(env: env, modelPath: file.path, sessionOptions: options) }
        self.env = env
        durationPredictor = try session(url(SupertonicFiles.durationPredictor))
        textEncoder = try session(url(SupertonicFiles.textEncoder))
        switch backend {
        case .coreML:
            guard #available(macOS 15, *) else {
                throw SpeechEngineError.notInstalled("Supertonic Core ML models need macOS 15")
            }
            decoder = try SupertonicCoreMLDecoder(directory: directory)
        case .onnx:
            decoder = try SupertonicONNXDecoder(directory: directory, makeSession: session)
        }
    }

    func loadStyle(_ fileURL: URL) throws -> SupertonicStyle {
        let file = try JSONDecoder().decode(StyleFile.self, from: Data(contentsOf: fileURL))
        func flat(_ c: StyleFile.Component) throws -> [Float] {
            let flat = c.data.flatMap { $0.flatMap { $0 } }
            guard c.dims.count == 3, flat.count == c.dims.reduce(1, *) else {
                throw SpeechEngineError.synthesisFailed("Malformed voice style \(fileURL.lastPathComponent)")
            }
            return flat
        }
        let ttl = try flat(file.style_ttl), dp = try flat(file.style_dp)
        return SupertonicStyle(ttl: try SupertonicORT.tensor(ttl, file.style_ttl.dims),
                               dp: try SupertonicORT.tensor(dp, file.style_dp.dims),
                               ttlValues: ttl)
    }

    /// Mono Float PCM at `sampleRate`. Long text is chunked and joined with
    /// `pause` seconds of silence. `speed` 1.0 = the model's natural pace.
    func synthesize(_ text: String, lang: String, style: SupertonicStyle, steps: Int,
                    speed: Float = 1.0, pause: Float = 0.3) throws -> [Float] {
        let chunks = SupertonicChunker.chunk(text, maxLength: SupertonicText.maxChunkLength(for: lang))
        guard !chunks.isEmpty else { throw SpeechEngineError.synthesisFailed("Nothing to say") }
        var out: [Float] = []
        for (i, chunk) in chunks.enumerated() {
            if i > 0 { out += [Float](repeating: 0, count: Int(pause * Float(sampleRate))) }
            out += try infer(tokenizer.encode(chunk, lang: lang), style: style, steps: steps, speed: speed)
        }
        return out
    }

    private func infer(_ ids: [Int64], style: SupertonicStyle, steps: Int, speed: Float) throws -> [Float] {
        let textIDs = try SupertonicORT.tensor(ids, [1, ids.count])
        let textMask = try SupertonicORT.tensor([Float](repeating: 1, count: ids.count), [1, 1, ids.count])

        // 1. Total utterance length in seconds (one scalar — no per-token durations).
        let dp = try SupertonicORT.run(durationPredictor, [
            "text_ids": textIDs, "style_dp": style.dp, "text_mask": textMask,
        ], output: "duration")
        guard let rawDuration = try SupertonicORT.floats(dp).first, rawDuration.isFinite, rawDuration > 0 else {
            throw SpeechEngineError.synthesisFailed("Duration predictor returned no duration")
        }
        let wavLength = Int(rawDuration / max(speed, 0.1) * Float(sampleRate))
        let frames = max(1, (wavLength + chunkSize - 1) / chunkSize)

        // 2. Text embedding.
        let textEmb = try SupertonicORT.run(textEncoder, [
            "text_ids": textIDs, "style_ttl": style.ttl, "text_mask": textMask,
        ], output: "text_emb")

        // 3+4. Denoise Gaussian noise into the latent, vocode, trim to duration.
        let input = SupertonicDecodeInput(textEmb: textEmb, textMask: textMask, tokens: ids.count,
                                          frames: frames, channels: latentChannels, steps: steps, style: style)
        let wav = try decoder.decode(Self.gaussianNoise(count: latentChannels * frames), input)
        return Array(wav.prefix(wavLength))
    }

    /// Standard normal samples via Box–Muller.
    private static func gaussianNoise(count: Int) -> [Float] {
        var out = [Float](repeating: 0, count: count)
        var rng = SystemRandomNumberGenerator()
        var i = 0
        while i < count {
            let u1 = Float.random(in: Float.ulpOfOne...1, using: &rng)
            let u2 = Float.random(in: 0..<1, using: &rng)
            let r = (-2 * log(u1)).squareRoot()
            out[i] = r * cos(2 * .pi * u2)
            if i + 1 < count { out[i + 1] = r * sin(2 * .pi * u2) }
            i += 2
        }
        return out
    }
}

/// Thin typed wrappers over the ONNX Runtime Objective-C API.
enum SupertonicORT {
    static func tensor(_ array: [Float], _ shape: [Int]) throws -> ORTValue {
        try make(array, .float, shape)
    }

    static func tensor(_ array: [Int64], _ shape: [Int]) throws -> ORTValue {
        try make(array, .int64, shape)
    }

    private static func make<T>(_ array: [T], _ type: ORTTensorElementDataType, _ shape: [Int]) throws -> ORTValue {
        let data = array.withUnsafeBytes { NSMutableData(bytes: $0.baseAddress, length: $0.count) }
        return try ORTValue(tensorData: data, elementType: type, shape: shape.map { NSNumber(value: $0) })
    }

    static func floats(_ value: ORTValue) throws -> [Float] {
        let data = try value.tensorData() as Data
        return data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }

    static func run(_ session: ORTSession, _ inputs: [String: ORTValue], output: String) throws -> ORTValue {
        do {
            guard let value = try session.run(withInputs: inputs, outputNames: [output], runOptions: nil)[output] else {
                throw SpeechEngineError.synthesisFailed("Model produced no '\(output)'")
            }
            return value
        } catch let error as SpeechEngineError {
            throw error
        } catch {
            throw SpeechEngineError.synthesisFailed("ONNX Runtime: \(error.localizedDescription)")
        }
    }
}
