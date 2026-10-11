import CryptoKit
import Foundation

/// Model files, relative to the install directory (mirrors the HF repo layout).
enum SupertonicFiles {
    static let durationPredictor = "onnx/duration_predictor.onnx"
    static let textEncoder = "onnx/text_encoder.onnx"
    static let vectorEstimator = "onnx/vector_estimator.onnx"
    static let vocoder = "onnx/vocoder.onnx"
    static let config = "onnx/tts.json"
    static let unicodeIndexer = "onnx/unicode_indexer.json"
    static let voiceIDs = ["F1", "F2", "F3", "F4", "F5", "M1", "M2", "M3", "M4", "M5"]
    static func voiceStyle(_ id: String) -> String { "voice_styles/\(id).json" }

    static var all: [String] {
        [durationPredictor, textEncoder, vectorEstimator, vocoder, config, unicodeIndexer]
            + voiceIDs.map(voiceStyle)
    }
}

/// What to download for Supertonic 3, pinned to one Hugging Face revision so a
/// later upstream push can't silently swap the weights under us.
enum SupertonicManifest {
    struct File {
        let path: String
        let size: Int64
        /// SHA-256 for the large LFS weights; small JSONs are checked by size.
        let sha256: String?
    }

    static let repo = "Supertone/supertonic-3"
    static let revision = "3cadd1ee6394adea1bd021217a0e650ede09a323"

    static func url(for file: File) -> URL {
        URL(string: "https://huggingface.co/\(repo)/resolve/\(revision)/\(file.path)")!
    }

    static let files: [File] = [
        File(path: SupertonicFiles.durationPredictor, size: 3_700_147,
             sha256: "c3eb91414d5ff8a7a239b7fe9e34e7e2bf8a8140d8375ffb14718b1c639325db"),
        File(path: SupertonicFiles.textEncoder, size: 36_416_150,
             sha256: "c7befd5ea8c3119769e8a6c1486c4edc6a3bc8365c67621c881bbb774b9902ff"),
        File(path: SupertonicFiles.vectorEstimator, size: 256_534_781,
             sha256: "883ac868ea0275ef0e991524dc64f16b3c0376efd7c320af6b53f5b780d7c61c"),
        File(path: SupertonicFiles.vocoder, size: 101_424_195,
             sha256: "085de76dd8e8d5836d6ca66826601f615939218f90e519f70ee8a36ed2a4c4ba"),
        File(path: SupertonicFiles.config, size: 8_253, sha256: nil),
        File(path: SupertonicFiles.unicodeIndexer, size: 277_676, sha256: nil),
        File(path: SupertonicFiles.voiceStyle("F1"), size: 292_046, sha256: nil),
        File(path: SupertonicFiles.voiceStyle("F2"), size: 292_423, sha256: nil),
        File(path: SupertonicFiles.voiceStyle("F3"), size: 290_794, sha256: nil),
        File(path: SupertonicFiles.voiceStyle("F4"), size: 291_808, sha256: nil),
        File(path: SupertonicFiles.voiceStyle("F5"), size: 291_479, sha256: nil),
        File(path: SupertonicFiles.voiceStyle("M1"), size: 291_748, sha256: nil),
        File(path: SupertonicFiles.voiceStyle("M2"), size: 292_055, sha256: nil),
        File(path: SupertonicFiles.voiceStyle("M3"), size: 290_198, sha256: nil),
        File(path: SupertonicFiles.voiceStyle("M4"), size: 291_522, sha256: nil),
        File(path: SupertonicFiles.voiceStyle("M5"), size: 291_469, sha256: nil),
    ]

    static let totalBytes: Int64 = files.reduce(0) { $0 + $1.size }

    /// True when every file is present at `directory` with the expected size.
    static func isComplete(at directory: URL) -> Bool {
        files.allSatisfy { fileSize(directory.appendingPathComponent($0.path)) == $0.size }
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

/// One-file HTTP download with byte progress and Task cancellation.
/// (Delegate-based: a completion-handler task's `progress` only reports 5%/100%.)
enum SupertonicDownloader {
    /// Downloads `url` to `destination` (replacing it). `progress` gets bytes
    /// received so far for this file, from a background thread.
    static func fetch(_ url: URL, to destination: URL,
                      progress: @escaping @Sendable (Int64) -> Void) async throws {
        let delegate = FetchDelegate(destination: destination, progress: progress)
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() } // releases the delegate
        let task = session.downloadTask(with: url)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                delegate.continuation = cont
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    /// Callbacks arrive serially on the session's delegate queue.
    private final class FetchDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
        let destination: URL
        let progress: @Sendable (Int64) -> Void
        var continuation: CheckedContinuation<Void, Error>?
        private var failure: Error?

        init(destination: URL, progress: @escaping @Sendable (Int64) -> Void) {
            self.destination = destination
            self.progress = progress
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData _: Int64,
                        totalBytesWritten: Int64, totalBytesExpectedToWrite _: Int64) {
            progress(totalBytesWritten)
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                        didFinishDownloadingTo location: URL) {
            // `location` is deleted when this returns, so move it now.
            let code = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? -1
            guard code == 200 else {
                failure = SpeechEngineError.serviceUnavailable(
                    "HTTP \(code) for \(downloadTask.originalRequest?.url?.lastPathComponent ?? "model file")")
                return
            }
            do {
                let fm = FileManager.default
                try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? fm.removeItem(at: destination)
                try fm.moveItem(at: location, to: destination)
            } catch {
                failure = error
            }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            let cont = continuation
            continuation = nil
            if let error = error ?? failure { cont?.resume(throwing: error) } else { cont?.resume() }
        }
    }
}
