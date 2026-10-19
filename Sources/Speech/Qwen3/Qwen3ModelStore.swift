import Foundation

/// Qwen3-TTS 1.7B on disk: whether it's there, downloading it (through the
/// bundled `narrateify-qwen3` helper, which owns the MLX/Hugging Face code)
/// and removing it. ~2.9 GB, so it's only ever installed on request.
@MainActor
final class Qwen3ModelStore: ObservableObject {
    enum State: Equatable {
        case notInstalled
        case downloading(progress: Double, message: String)
        case installed
        case failed(String)
    }

    static let modelID = "aufklarer/Qwen3-TTS-12Hz-1.7B-Base-MLX-8bit"
    /// Weights + speech tokenizer, as downloaded (measured: 2.9 GB on disk).
    static let downloadSize: Int64 = 2_900_000_000

    nonisolated static let directory: URL = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Narrateify/Models/qwen3-tts-1.7b", isDirectory: true)
    nonisolated static var modelDirectory: URL { directory.appendingPathComponent("model", isDirectory: true) }
    nonisolated static var tokenizerDirectory: URL { directory.appendingPathComponent("tokenizer", isDirectory: true) }
    /// Reference clips the built-in voices are cloned from.
    nonisolated static var voicesDirectory: URL { directory.appendingPathComponent("voices", isDirectory: true) }
    /// Written last, so a half-finished download never counts as installed.
    nonisolated private static var marker: URL { directory.appendingPathComponent(".installed") }

    /// The helper lives next to the CLI in the app bundle.
    nonisolated static var helper: URL? {
        Bundle.main.sharedSupportURL?.appendingPathComponent("narrateify-qwen3")
    }

    /// MLX needs Apple silicon and macOS 15 (the helper's deployment target).
    nonisolated static var unsupportedReason: String? {
        #if !arch(arm64)
        return "Needs Apple silicon"
        #else
        if !ProcessInfo.processInfo.isOperatingSystemAtLeast(OperatingSystemVersion(majorVersion: 15, minorVersion: 0, patchVersion: 0)) {
            return "Needs macOS 15 or later"
        }
        guard let helper, FileManager.default.isExecutableFile(atPath: helper.path) else {
            return "Not included in this build"
        }
        return nil
        #endif
    }

    nonisolated static var isInstalled: Bool { FileManager.default.fileExists(atPath: marker.path) }

    @Published private(set) var state: State = Qwen3ModelStore.isInstalled ? .installed : .notInstalled
    private var installTask: Task<Void, Error>?

    var isInstalled: Bool { state == .installed }

    var diskUsage: Int64 {
        let files = FileManager.default.enumerator(at: Self.directory, includingPropertiesForKeys: [.totalFileAllocatedSizeKey])
        var total: Int64 = 0
        while let url = files?.nextObject() as? URL {
            total += Int64((try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?.totalFileAllocatedSize ?? 0)
        }
        return total
    }

    /// Downloads (or resumes) and verifies the model. Concurrent callers share
    /// one download.
    func install() async throws {
        if isInstalled { return }
        if let reason = Self.unsupportedReason { throw SpeechEngineError.notInstalled(reason) }
        if let installTask { return try await installTask.value }
        let task = Task { try await runInstall() }
        installTask = task
        defer { installTask = nil }
        do {
            try await task.value
            state = .installed
        } catch {
            state = task.isCancelled ? .notInstalled : .failed(error.localizedDescription)
            throw error
        }
    }

    /// Stops a running download first (and waits for its helper to exit, so
    /// nothing recreates files after the delete). Removing nothing is fine.
    func uninstall() async throws {
        if let installTask {
            installTask.cancel()
            _ = try? await installTask.value
        }
        do {
            try FileManager.default.removeItem(at: Self.directory)
        } catch CocoaError.fileNoSuchFile {
            // already gone
        }
        state = .notInstalled
    }

    private func runInstall() async throws {
        state = .downloading(progress: 0, message: "Starting…")
        let fm = FileManager.default
        for dir in [Self.modelDirectory, Self.tokenizerDirectory] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        let process = Process()
        process.executableURL = Self.helper
        process.arguments = ["install", "--model-id", Self.modelID,
                             "--model-dir", Self.modelDirectory.path, "--tokenizer-dir", Self.tokenizerDirectory.path]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        try process.run()

        var failure: String?
        try await withTaskCancellationHandler {
            for try await line in out.fileHandleForReading.bytes.lines {
                guard let data = line.data(using: .utf8),
                      let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                if let progress = event["progress"] as? Double {
                    state = .downloading(progress: progress, message: event["message"] as? String ?? "")
                }
                if let error = event["error"] as? String { failure = error }
            }
        } onCancel: {
            process.terminate()
        }
        process.waitUntilExit()
        try Task.checkCancellation()
        if let failure { throw SpeechEngineError.notInstalled(failure) }
        guard process.terminationStatus == 0 else {
            throw SpeechEngineError.notInstalled("The download stopped (exit \(process.terminationStatus))")
        }
        fm.createFile(atPath: Self.marker.path, contents: Data())
    }
}
