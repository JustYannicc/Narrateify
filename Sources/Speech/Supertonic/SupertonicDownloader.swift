import Foundation

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
