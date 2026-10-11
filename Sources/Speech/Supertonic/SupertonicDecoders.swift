// The heavy half of Supertonic 3: N flow-matching denoise steps, then the vocoder.
// Two interchangeable implementations — Core ML (default, macOS 15+) and ONNX
// Runtime (fallback). Both take the same inputs and return untrimmed PCM.

import CoreML
import Foundation
import OnnxRuntimeBindings

/// Everything the decoder needs for one utterance.
struct SupertonicDecodeInput {
    let textEmb: ORTValue  // [1, 256, T] from the text encoder
    let textMask: ORTValue // [1, 1, T], all ones
    let tokens: Int        // T
    let frames: Int        // L, latent frames
    let channels: Int      // 144 latent channels
    let steps: Int
    let style: SupertonicStyle
}

protocol SupertonicDecoder: AnyObject {
    /// Denoise `noise` ([channels × frames], channel-major) and vocode it.
    func decode(_ noise: [Float], _ input: SupertonicDecodeInput) throws -> [Float]
}

// MARK: - ONNX Runtime

final class SupertonicONNXDecoder: SupertonicDecoder {
    private let vectorEstimator: ORTSession
    private let vocoder: ORTSession

    init(directory: URL, makeSession: (URL) throws -> ORTSession) throws {
        vectorEstimator = try makeSession(directory.appendingPathComponent(SupertonicFiles.vectorEstimator))
        vocoder = try makeSession(directory.appendingPathComponent(SupertonicFiles.vocoder))
    }

    func decode(_ noise: [Float], _ input: SupertonicDecodeInput) throws -> [Float] {
        let shape = [1, input.channels, input.frames]
        let latentMask = try SupertonicORT.tensor([Float](repeating: 1, count: input.frames), [1, 1, input.frames])
        let totalStep = try SupertonicORT.tensor([Float(input.steps)], [1])
        var latent = noise
        for step in 0..<input.steps {
            latent = try SupertonicORT.floats(SupertonicORT.run(vectorEstimator, [
                "noisy_latent": try SupertonicORT.tensor(latent, shape),
                "text_emb": input.textEmb,
                "style_ttl": input.style.ttl,
                "latent_mask": latentMask,
                "text_mask": input.textMask,
                "current_step": try SupertonicORT.tensor([Float(step)], [1]),
                "total_step": totalStep,
            ], output: "denoised_latent"))
            guard latent.count == noise.count else {
                throw SpeechEngineError.synthesisFailed("Unexpected latent size \(latent.count)")
            }
        }
        return try SupertonicORT.floats(SupertonicORT.run(
            vocoder, ["latent": try SupertonicORT.tensor(latent, shape)], output: "wav_tts"))
    }
}

// MARK: - Core ML

/// Runs FluidInference's fp16 Core ML port on the CPU. Measured on M5 Pro,
/// CPU-only beats GPU/ANE ~3× here (10 ms vs 35 ms per denoise step for a
/// short sentence), and the weights stay memory-mapped instead of resident.
@available(macOS 15, *)
final class SupertonicCoreMLDecoder: SupertonicDecoder {
    /// The port's flexible-shape range for both text tokens and latent frames.
    private static let shapeRange = 17...512

    private let vectorEstimator: MLModel
    private let vocoder: MLModel

    init(directory: URL) throws {
        let config = MLModelConfiguration()
        config.computeUnits = .cpuOnly
        func load(_ rel: String) throws -> MLModel {
            try MLModel(contentsOf: directory.appendingPathComponent(rel, isDirectory: true), configuration: config)
        }
        vectorEstimator = try load(SupertonicFiles.coreMLVectorEstimator)
        vocoder = try load(SupertonicFiles.coreMLVocoder)
    }

    func decode(_ noise: [Float], _ input: SupertonicDecodeInput) throws -> [Float] {
        let c = input.channels, frames = input.frames, tokens = input.tokens
        // Short inputs are right-padded to the model's minimum and masked out;
        // the v2 port fills padding correctly, so padded frames don't leak.
        let t = max(tokens, Self.shapeRange.lowerBound), l = max(frames, Self.shapeRange.lowerBound)
        guard t <= Self.shapeRange.upperBound, l <= Self.shapeRange.upperBound else {
            throw SpeechEngineError.synthesisFailed("Chunk too long for Supertonic Core ML (\(tokens) tokens)")
        }
        let emb = try Self.array(Self.pad(SupertonicORT.floats(input.textEmb), rows: 256, from: tokens, to: t),
                                 [1, 256, t])
        let style = try Self.array(input.style.ttlValues, [1, 50, 256])
        let textMask = try Self.array((0..<t).map { $0 < tokens ? 1 : 0 }, [1, 1, t])
        let latentMask = try Self.array((0..<l).map { $0 < frames ? 1 : 0 }, [1, 1, l])
        let totalStep = try Self.array([Float(input.steps)], [1])

        var latent = try Self.array(Self.pad(noise, rows: c, from: frames, to: l), [1, c, l])
        for step in 0..<input.steps {
            let out = try vectorEstimator.prediction(from: MLDictionaryFeatureProvider(dictionary: [
                "noisy_latent": latent, "text_emb": emb, "style_ttl": style,
                "latent_mask": latentMask, "text_mask": textMask,
                "current_step": try Self.array([Float(step)], [1]), "total_step": totalStep,
            ]))
            latent = try Self.output(out, "denoised_latent")
        }
        // Padded frames only add audio past the predicted duration, which the
        // runtime trims (the vocoder pads on the left only).
        let wav = try vocoder.prediction(from: MLDictionaryFeatureProvider(dictionary: ["latent": latent]))
        return try Self.contiguousFloats(Self.output(wav, "wav"))
    }

    // MARK: Helpers

    /// Row-major [rows × from] → [rows × to], zero-filled.
    private static func pad(_ x: [Float], rows: Int, from: Int, to: Int) -> [Float] {
        guard to != from else { return x }
        var out = [Float](repeating: 0, count: rows * to)
        for r in 0..<rows {
            for j in 0..<from { out[r * to + j] = x[r * from + j] }
        }
        return out
    }

    private static func array(_ values: [Float], _ shape: [Int]) throws -> MLMultiArray {
        let a = try MLMultiArray(shape: shape.map { NSNumber(value: $0) }, dataType: .float32)
        values.withUnsafeBufferPointer { src in
            a.dataPointer.bindMemory(to: Float.self, capacity: values.count)
                .update(from: src.baseAddress!, count: min(values.count, a.count))
        }
        return a
    }

    private static func output(_ provider: MLFeatureProvider, _ name: String) throws -> MLMultiArray {
        guard let value = provider.featureValue(for: name)?.multiArrayValue else {
            throw SpeechEngineError.synthesisFailed("Core ML produced no '\(name)'")
        }
        return value
    }

    /// Copies a [1, N] (possibly strided) fp32/fp16 array into a flat buffer.
    private static func contiguousFloats(_ a: MLMultiArray) throws -> [Float] {
        let n = a.shape.last!.intValue, stride = a.strides.last!.intValue
        switch a.dataType {
        case .float32:
            let p = a.dataPointer.bindMemory(to: Float.self, capacity: n * stride)
            return (0..<n).map { p[$0 * stride] }
        case .float16:
            let p = a.dataPointer.bindMemory(to: Float16.self, capacity: n * stride)
            return (0..<n).map { Float(p[$0 * stride]) }
        default:
            throw SpeechEngineError.synthesisFailed("Unexpected Core ML output type")
        }
    }
}
