import CryptoKit
import Foundation

/// Which runtime runs the heavy half of the pipeline (denoiser + vocoder).
/// The duration predictor and text encoder always run on ONNX Runtime.
enum SupertonicBackend: Equatable {
    /// Core ML fp16 ports on the CPU (Accelerate/AMX). ~6× faster than ORT and
    /// the weights are memory-mapped. The models need macOS 15 (mlprogram ios18).
    case coreML
    /// The official ONNX files on ONNX Runtime. Fallback for macOS 14.
    case onnx

    /// The best backend this OS can run.
    static var current: SupertonicBackend {
        if #available(macOS 15, *) { return .coreML }
        return .onnx
    }

    /// The backend a complete install at `directory` supports, preferring
    /// `preferred` (an upgraded install may also still hold ONNX files).
    static func installed(at directory: URL, preferred: SupertonicBackend = .current) -> SupertonicBackend? {
        if preferred == .coreML, SupertonicManifest.isComplete(at: directory, backend: .coreML) { return .coreML }
        if SupertonicManifest.isComplete(at: directory, backend: .onnx) { return .onnx }
        return nil
    }
}

/// Model files, relative to the install directory.
enum SupertonicFiles {
    static let durationPredictor = "onnx/duration_predictor.onnx"
    static let textEncoder = "onnx/text_encoder.onnx"
    static let vectorEstimator = "onnx/vector_estimator.onnx"
    static let vocoder = "onnx/vocoder.onnx"
    static let config = "onnx/tts.json"
    static let unicodeIndexer = "onnx/unicode_indexer.json"
    static let coreMLVectorEstimator = "coreml/VectorEstimator_v2.mlmodelc"
    static let coreMLVocoder = "coreml/Vocoder.mlmodelc"
    static let voiceIDs = ["F1", "F2", "F3", "F4", "F5", "M1", "M2", "M3", "M4", "M5"]
    static func voiceStyle(_ id: String) -> String { "voice_styles/\(id).json" }
}

/// What to download for Supertonic 3. Every source is pinned to one Hugging
/// Face revision so an upstream push can't silently swap the weights under us.
enum SupertonicManifest {
    struct Source {
        let repo: String
        let revision: String
    }

    /// Official weights (OpenRAIL-M).
    static let supertone = Source(repo: "Supertone/supertonic-3",
                                  revision: "3cadd1ee6394adea1bd021217a0e650ede09a323")
    /// FluidInference's Core ML port of the same weights (v2 = padding-leak fix).
    static let fluidCoreML = Source(repo: "FluidInference/supertonic-3-coreml",
                                    revision: "5cd12d1c4cb524e704ce40ba1048e36c2e7ea2fa")

    struct File {
        /// Local path relative to the install directory.
        let path: String
        let source: Source
        /// Path inside the source repo.
        let remotePath: String
        let size: Int64
        /// SHA-256 for the large weights; small files are checked by size.
        let sha256: String?

        var url: URL {
            URL(string: "https://huggingface.co/\(source.repo)/resolve/\(source.revision)/\(remotePath)")!
        }
    }

    private static func official(_ path: String, _ size: Int64, _ sha256: String? = nil) -> File {
        File(path: path, source: supertone, remotePath: path, size: size, sha256: sha256)
    }

    private static func coreML(_ local: String, _ file: String, _ size: Int64, _ sha256: String? = nil) -> File {
        let bundle = (local as NSString).lastPathComponent
        return File(path: "\(local)/\(file)", source: fluidCoreML, remotePath: "\(bundle)/\(file)",
                    size: size, sha256: sha256)
    }

    /// Needed by both backends: tokenizer, config, voices, duration + text encoder.
    static let common: [File] = [
        official(SupertonicFiles.durationPredictor, 3_700_147,
                 "c3eb91414d5ff8a7a239b7fe9e34e7e2bf8a8140d8375ffb14718b1c639325db"),
        official(SupertonicFiles.textEncoder, 36_416_150,
                 "c7befd5ea8c3119769e8a6c1486c4edc6a3bc8365c67621c881bbb774b9902ff"),
        official(SupertonicFiles.config, 8_253),
        official(SupertonicFiles.unicodeIndexer, 277_676),
        official(SupertonicFiles.voiceStyle("F1"), 292_046),
        official(SupertonicFiles.voiceStyle("F2"), 292_423),
        official(SupertonicFiles.voiceStyle("F3"), 290_794),
        official(SupertonicFiles.voiceStyle("F4"), 291_808),
        official(SupertonicFiles.voiceStyle("F5"), 291_479),
        official(SupertonicFiles.voiceStyle("M1"), 291_748),
        official(SupertonicFiles.voiceStyle("M2"), 292_055),
        official(SupertonicFiles.voiceStyle("M3"), 290_198),
        official(SupertonicFiles.voiceStyle("M4"), 291_522),
        official(SupertonicFiles.voiceStyle("M5"), 291_469),
    ]

    static let onnxDecoder: [File] = [
        official(SupertonicFiles.vectorEstimator, 256_534_781,
                 "883ac868ea0275ef0e991524dc64f16b3c0376efd7c320af6b53f5b780d7c61c"),
        official(SupertonicFiles.vocoder, 101_424_195,
                 "085de76dd8e8d5836d6ca66826601f615939218f90e519f70ee8a36ed2a4c4ba"),
    ]

    static let coreMLDecoder: [File] = {
        let ve = SupertonicFiles.coreMLVectorEstimator, voc = SupertonicFiles.coreMLVocoder
        return [
            coreML(ve, "analytics/coremldata.bin", 243),
            coreML(ve, "coremldata.bin", 634),
            coreML(ve, "model.mil", 374_405, "99669125d3f91ee3555fe9f1dbd51affca581d918330b0d89005bc2f21e8095d"),
            coreML(ve, "weights/weight.bin", 127_648_384,
                   "101cebe7759b5f5e8f188ed3c2bf5f624bbf048aa657fe5bed9c3110c5ce0c26"),
            coreML(voc, "analytics/coremldata.bin", 243),
            coreML(voc, "coremldata.bin", 388),
            coreML(voc, "model.mil", 75_626, "5f57d6b16a4ee7237e046a423c265aa2c487857eb0003bba1c89fa66e577353f"),
            coreML(voc, "weights/weight.bin", 50_672_512,
                   "b45e4c17a45cc4de30dcedae9f662548aa35f8f9763632c342b8bbef3089fcee"),
        ]
    }()

    static func files(for backend: SupertonicBackend) -> [File] {
        common + (backend == .coreML ? coreMLDecoder : onnxDecoder)
    }

    static func totalBytes(for backend: SupertonicBackend) -> Int64 {
        files(for: backend).reduce(0) { $0 + $1.size }
    }

    /// True when every file is present at `directory` with the expected size.
    static func isComplete(at directory: URL, backend: SupertonicBackend) -> Bool {
        files(for: backend).allSatisfy { fileSize(directory.appendingPathComponent($0.path)) == $0.size }
    }

    static func fileSize(_ url: URL) -> Int64? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
    }

    /// Checks size (and hash when known). Hashing reads the file in 4 MB chunks.
    static func verify(_ file: File, at url: URL) throws {
        guard fileSize(url) == file.size else {
            throw SpeechEngineError.serviceUnavailable("\(file.path): size mismatch")
        }
        guard let expected = file.sha256 else { return }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        let actual = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard actual == expected else {
            throw SpeechEngineError.serviceUnavailable("\(file.path): checksum mismatch")
        }
    }
}
