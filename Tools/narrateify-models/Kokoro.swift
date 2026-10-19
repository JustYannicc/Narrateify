import Foundation
import KokoroTTS
import OnnxRuntimeBindings

/// Kokoro v1.0 (82M) on ONNX Runtime: the same `kokoro-v1.0.onnx` and
/// `voices-v1.0.bin` kokoro-onnx uses, minus Python. English text goes
/// through `KokoroEnglish` (misaki-style); fr/es/it/pt/hi/ja/zh through
/// speech-swift's phonemizers.
///
/// Model dir layout: kokoro-v1.0.onnx, voices-v1.0.bin, and g2p/ (vocab,
/// misaki dictionaries, CoreML G2P for unknown words).
enum Kokoro {
    static let maxTokens = 510   // the model's context, minus the two pads
    static let styleDim = 256

    static func load() async throws -> ([String: Any]) throws -> [Float] {
        let dir = directory("model-dir")
        let g2p = dir.appendingPathComponent("g2p")
        let phonemizer = try KokoroPhonemizer.loadVocab(from: g2p.appendingPathComponent("vocab_index.json"))
        try phonemizer.loadDictionaries(from: g2p)
        try phonemizer.loadG2PModels(encoderURL: g2p.appendingPathComponent("G2PEncoder.mlmodelc"),
                                     decoderURL: g2p.appendingPathComponent("G2PDecoder.mlmodelc"),
                                     vocabURL: g2p.appendingPathComponent("g2p_vocab.json"))
        let english = try KokoroEnglish(directory: g2p, fallback: phonemizer,
                                        lexicon: option("lexicon").map { URL(fileURLWithPath: $0) })
        let voices = try loadVoices(dir.appendingPathComponent("voices-v1.0.bin"))

        let env = try ORTEnv(loggingLevel: .warning)
        let options = try ORTSessionOptions()
        let session = try ORTSession(env: env, modelPath: dir.appendingPathComponent("kokoro-v1.0.onnx").path,
                                     sessionOptions: options)

        return { request in
            let text = request["text"] as? String ?? ""
            let language = request["language"] as? String ?? "en"
            let voice = request["voice"] as? String ?? "af_heart"
            guard let styles = voices[voice] else {
                throw RequestError(message: "Unknown Kokoro voice \(voice)")
            }
            let ids: [Int]
            if let phonemes = request["phonemes"] as? String {   // exact phonemes (tests, debugging)
                ids = english.tokens(phonemes: phonemes)
            } else if language == "en" {
                ids = english.tokens(text)
            } else {
                ids = Array(phonemizer.tokenize(text, maxLength: 4096, language: language).dropFirst().dropLast())   // its bos/eos
            }
            _ = env   // keep the ORT environment alive with the session
            // Nothing pronounceable (emoji, a lone "$"): a beat of silence, not a
            // failed render.
            guard !ids.isEmpty else { return [Float](repeating: 0, count: 2_400) }
            var audio: [Float] = []
            for chunk in split(ids) {
                audio += trimSilence(try run(session, tokens: chunk, styles: styles))
            }
            return audio
        }
    }

    /// One model call: [0, tokens…, 0] with the voice's style for that
    /// length — row n-1 for n phonemes, as in Kokoro's own pipeline.
    private static func run(_ session: ORTSession, tokens: [Int], styles: [Float]) throws -> [Float] {
        let n = tokens.count
        let row = max(0, min(n, styles.count / styleDim) - 1)
        let style = Array(styles[(row * styleDim)..<(row * styleDim + styleDim)])
        let padded = [Int64(0)] + tokens.map(Int64.init) + [0]
        let outputs = try session.run(withInputs: [
            "tokens": try tensor(padded, .int64, [1, padded.count]),
            "style": try tensor(style, .float, [1, styleDim]),
            "speed": try tensor([Float(1)], .float, [1]),
        ], outputNames: ["audio"], runOptions: nil)
        guard let value = outputs["audio"] else { throw RequestError(message: "Kokoro returned no audio") }
        let data = try value.tensorData() as Data
        return data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }

    /// librosa's `trim(top_db=60)`, as kokoro-onnx applies it: drop leading and
    /// trailing frames more than 60 dB below the loudest (2048-sample frames,
    /// hop 512, centred). Without it each sentence carries the model's ~0.3 s
    /// tail and the pacing drifts from the Athena voiceover.
    static func trimSilence(_ y: [Float], topDB: Float = 60, frame: Int = 2048, hop: Int = 512) -> [Float] {
        guard y.count > frame else { return y }
        let frames = 1 + y.count / hop
        var power = [Float](repeating: 0, count: frames)
        y.withUnsafeBufferPointer { buf in
            for f in 0..<frames {
                let lo = f * hop - frame / 2, hi = lo + frame
                var sum: Float = 0
                for i in max(lo, 0)..<min(hi, y.count) { sum += buf[i] * buf[i] }
                power[f] = sum / Float(frame)
            }
        }
        guard let peak = power.max(), peak > 0 else { return y }
        let threshold = peak * pow(10, -topDB / 10)
        guard let first = power.firstIndex(where: { $0 > threshold }),
              let last = power.lastIndex(where: { $0 > threshold }) else { return y }
        let start = first * hop, end = min(y.count, (last + 1) * hop)
        return start < end ? Array(y[start..<end]) : y
    }

    /// Over-long sections split at the last word break (token 16 = space)
    /// that fits; sections are sentence-sized, so this is rare.
    private static func split(_ ids: [Int]) -> [[Int]] {
        var rest = ids[...]
        var chunks: [[Int]] = []
        while rest.count > maxTokens {
            let window = rest.prefix(maxTokens)
            let cut = window.lastIndex(of: 16).map { $0 + 1 } ?? window.endIndex
            chunks.append(Array(rest[..<cut]))
            rest = rest[cut...]
        }
        if !rest.isEmpty { chunks.append(Array(rest)) }
        return chunks
    }

    private static func tensor<T>(_ array: [T], _ type: ORTTensorElementDataType, _ shape: [Int]) throws -> ORTValue {
        let data = array.withUnsafeBufferPointer { NSMutableData(bytes: $0.baseAddress, length: $0.count * MemoryLayout<T>.stride) }
        return try ORTValue(tensorData: data, elementType: type, shape: shape.map { NSNumber(value: $0) })
    }

    /// voices-v1.0.bin is numpy's `savez`: an uncompressed (zip64) zip of
    /// `<voice>.npy`, each float32 (510, 1, 256).
    static func loadVoices(_ url: URL) throws -> [String: [Float]] {
        let data = try Data(contentsOf: url)
        func u16(_ o: Int) -> Int { Int(data[o]) | Int(data[o + 1]) << 8 }
        func u32(_ o: Int) -> Int { u16(o) | u16(o + 2) << 16 }
        var voices: [String: [Float]] = [:]
        var offset = 0
        func bad(_ why: String) -> RequestError { RequestError(message: "\(url.lastPathComponent) is damaged: \(why)") }
        while offset + 30 < data.count, u32(offset) == 0x0403_4B50 {
            guard u16(offset + 8) == 0 else { throw RequestError(message: "voices file is compressed; expected numpy savez") }
            let nameLength = u16(offset + 26), extraLength = u16(offset + 28)
            var size = u32(offset + 22)   // uncompressed size
            if size == 0xFFFF_FFFF {      // zip64: real size is the first field of the extra block
                size = u32(offset + 30 + nameLength + 4)
            }
            let start = offset + 30 + nameLength + extraLength
            guard start + size <= data.count, size > 10 else { throw bad("entry runs past the end") }
            let name = String(decoding: data[(offset + 30)..<(offset + 30 + nameLength)], as: UTF8.self)
            let npy = data[start..<(start + size)]
            let headerLength = Int(npy[npy.startIndex + 8]) | Int(npy[npy.startIndex + 9]) << 8
            let body = npy.dropFirst(10 + headerLength)
            guard body.count >= styleDim * MemoryLayout<Float>.size else { throw bad("\(name) is too short") }
            // Copy rather than rebind: the float data isn't 4-byte aligned in the file.
            var floats = [Float](repeating: 0, count: body.count / MemoryLayout<Float>.size)
            _ = floats.withUnsafeMutableBytes { body.copyBytes(to: $0) }
            voices[(name as NSString).deletingPathExtension] = floats
            offset = start + size
        }
        guard !voices.isEmpty else { throw RequestError(message: "no voices in \(url.lastPathComponent)") }
        return voices
    }
}
