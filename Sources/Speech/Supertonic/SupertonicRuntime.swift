// ONNX Runtime inference pipeline for Supertonic 3:
// duration predictor → text encoder → N flow-matching denoise steps → vocoder.
//
// Ported and adapted from the official Supertonic Swift example
// (https://github.com/supertone-inc/supertonic, swift/Sources/Helper.swift).
// Original code: MIT License, Copyright (c) 2025 Supertone Inc.
//
// Changes: flat Float buffers instead of nested arrays, typed errors instead of
// fatalError / force-unwraps, one voice per call (no batching).
//
// NOT thread-safe — SupertonicEngine serializes all access on one queue.

import Foundation
import OnnxRuntimeBindings

/// A voice's conditioning tensors (`style_ttl` [1,50,256], `style_dp` [1,8,16]).
struct SupertonicStyle {
    let ttl: ORTValue
    let dp: ORTValue
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
    private let chunkSize: Int      // audio samples per latent frame
    private let latentChannels: Int // latent_dim * chunk_compress_factor
    private let tokenizer: SupertonicTokenizer
    private let env: ORTEnv
    private let durationPredictor: ORTSession
    private let textEncoder: ORTSession
    private let vectorEstimator: ORTSession
    private let vocoder: ORTSession

    init(directory: URL) throws {
        let url = { (rel: String) in directory.appendingPathComponent(rel) }
        for rel in SupertonicFiles.all where !FileManager.default.fileExists(atPath: url(rel).path) {
            throw SpeechEngineError.notInstalled("Supertonic 3 model file missing: \(rel)")
        }
        let cfg = try JSONDecoder().decode(Config.self, from: Data(contentsOf: url(SupertonicFiles.config)))
        sampleRate = cfg.ae.sample_rate
        chunkSize = cfg.ae.base_chunk_size * cfg.ttl.chunk_compress_factor
        latentChannels = cfg.ttl.latent_dim * cfg.ttl.chunk_compress_factor
        tokenizer = try SupertonicTokenizer(indexerURL: url(SupertonicFiles.unicodeIndexer))

        let env = try ORTEnv(loggingLevel: .warning)
        let options = try ORTSessionOptions()
        try options.setGraphOptimizationLevel(.all)
        // Measured on M5 Pro: 2–4 threads are as fast as ORT's all-cores default
        // (more is slightly slower), and burn far less CPU in a background app.
        try options.setIntraOpNumThreads(Int32(min(4, ProcessInfo.processInfo.activeProcessorCount)))
        let session = { (rel: String) in
            try ORTSession(env: env, modelPath: url(rel).path, sessionOptions: options)
        }
        self.env = env
        durationPredictor = try session(SupertonicFiles.durationPredictor)
        textEncoder = try session(SupertonicFiles.textEncoder)
        vectorEstimator = try session(SupertonicFiles.vectorEstimator)
        vocoder = try session(SupertonicFiles.vocoder)
    }

    func loadStyle(_ fileURL: URL) throws -> SupertonicStyle {
        let file = try JSONDecoder().decode(StyleFile.self, from: Data(contentsOf: fileURL))
        func value(_ c: StyleFile.Component) throws -> ORTValue {
            let flat = c.data.flatMap { $0.flatMap { $0 } }
            guard c.dims.count == 3, flat.count == c.dims.reduce(1, *) else {
                throw SpeechEngineError.synthesisFailed("Malformed voice style \(fileURL.lastPathComponent)")
            }
            return try Self.tensor(flat, .float, c.dims)
        }
        return SupertonicStyle(ttl: try value(file.style_ttl), dp: try value(file.style_dp))
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
        let textIDs = try Self.tensor(ids, .int64, [1, ids.count])
        let textMask = try Self.tensor([Float](repeating: 1, count: ids.count), .float, [1, 1, ids.count])

        // 1. Total utterance length in seconds (one scalar — no per-token durations).
        let dp = try run(durationPredictor, ["text_ids": textIDs, "style_dp": style.dp, "text_mask": textMask],
                         output: "duration")
        guard let rawDuration = try Self.floats(dp).first, rawDuration.isFinite, rawDuration > 0 else {
            throw SpeechEngineError.synthesisFailed("Duration predictor returned no duration")
        }
        let duration = rawDuration / max(speed, 0.1)

        // 2. Text embedding.
        let textEmb = try run(textEncoder, ["text_ids": textIDs, "style_ttl": style.ttl, "text_mask": textMask],
                              output: "text_emb")

        // 3. Denoise Gaussian noise into the audio latent.
        let wavLength = Int(duration * Float(sampleRate))
        let frames = max(1, (wavLength + chunkSize - 1) / chunkSize)
        var latent = Self.gaussianNoise(count: latentChannels * frames)
        let latentShape = [1, latentChannels, frames]
        let latentMask = try Self.tensor([Float](repeating: 1, count: frames), .float, [1, 1, frames])
        let totalStep = try Self.tensor([Float(steps)], .float, [1])
        for step in 0..<steps {
            let out = try run(vectorEstimator, [
                "noisy_latent": try Self.tensor(latent, .float, latentShape),
                "text_emb": textEmb,
                "style_ttl": style.ttl,
                "latent_mask": latentMask,
                "text_mask": textMask,
                "current_step": try Self.tensor([Float(step)], .float, [1]),
                "total_step": totalStep,
            ], output: "denoised_latent")
            latent = try Self.floats(out)
            guard latent.count == latentChannels * frames else {
                throw SpeechEngineError.synthesisFailed("Unexpected latent size \(latent.count)")
            }
        }

        // 4. Vocoder → waveform, trimmed to the predicted duration.
        let wav = try Self.floats(run(vocoder, ["latent": try Self.tensor(latent, .float, latentShape)],
                                      output: "wav_tts"))
        return Array(wav.prefix(wavLength))
    }

    private func run(_ session: ORTSession, _ inputs: [String: ORTValue], output: String) throws -> ORTValue {
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

    // MARK: Tensor helpers

    private static func tensor<T>(_ array: [T], _ type: ORTTensorElementDataType, _ shape: [Int]) throws -> ORTValue {
        let data = array.withUnsafeBytes { NSMutableData(bytes: $0.baseAddress, length: $0.count) }
        return try ORTValue(tensorData: data, elementType: type, shape: shape.map { NSNumber(value: $0) })
    }

    private static func floats(_ value: ORTValue) throws -> [Float] {
        let data = try value.tensorData() as Data
        return data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
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
