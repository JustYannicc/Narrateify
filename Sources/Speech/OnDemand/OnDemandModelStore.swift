import Foundation

/// An on-demand model's files on disk: whether they're there, downloading
/// them and removing them. Each model brings its own `fetch`; this owns the
/// state, the shared download task and the "installed" marker (written
/// last, so a half-finished download never counts).
@MainActor
final class OnDemandModelStore: ObservableObject {
    enum State: Equatable {
        case notInstalled
        case downloading(progress: Double, message: String)
        case installed
        case failed(String)
    }

    /// Downloads into `directory`, reporting 0…1 progress plus a message.
    typealias Fetch = @MainActor (_ directory: URL, _ progress: @escaping @MainActor (Double, String) -> Void) async throws -> Void

    let directory: URL
    let downloadSize: Int64
    private let fetch: Fetch

    @Published private(set) var state: State
    private var installTask: Task<Void, Error>?

    init(directory: URL, downloadSize: Int64, fetch: @escaping Fetch) {
        self.directory = directory
        self.downloadSize = downloadSize
        self.fetch = fetch
        state = Self.isInstalled(at: directory) ? .installed : .notInstalled
    }

    nonisolated static func isInstalled(at directory: URL) -> Bool {
        FileManager.default.fileExists(atPath: directory.appendingPathComponent(".installed").path)
    }

    var isInstalled: Bool { state == .installed }

    var diskUsage: Int64 {
        let files = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.totalFileAllocatedSizeKey])
        var total: Int64 = 0
        while let url = files?.nextObject() as? URL {
            total += Int64((try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?.totalFileAllocatedSize ?? 0)
        }
        return total
    }

    /// Downloads (or resumes) the model. Concurrent callers share one download.
    func install() async throws {
        if isInstalled { return }
        if let reason = ModelHelper.unsupportedReason { throw SpeechEngineError.notInstalled(reason) }
        if let installTask { return try await installTask.value }
        let directory = directory
        let task = Task {
            state = .downloading(progress: 0, message: "Starting…")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try await fetch(directory) { [weak self] progress, message in
                self?.state = .downloading(progress: progress, message: message)
            }
            try Task.checkCancellation()
            FileManager.default.createFile(atPath: directory.appendingPathComponent(".installed").path, contents: Data())
        }
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

    /// Stops a running download first (and waits for it, so nothing recreates
    /// files after the delete). Removing nothing is fine.
    func uninstall() async throws {
        if let installTask {
            installTask.cancel()
            _ = try? await installTask.value
        }
        do {
            try FileManager.default.removeItem(at: directory)
        } catch CocoaError.fileNoSuchFile {
            // already gone
        }
        state = .notInstalled
    }
}

extension OnDemandModelStore {
    nonisolated static func modelsDirectory(_ name: String) -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Narrateify/Models/\(name)", isDirectory: true)
    }

    /// Runs `narrateify-models <arguments>` and forwards its progress lines.
    static func runHelper(_ arguments: [String], progress: @escaping @MainActor (Double, String) -> Void) async throws {
        let process = Process()
        process.executableURL = ModelHelper.executable
        process.arguments = arguments
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        try process.run()

        var failure: String?
        try await withTaskCancellationHandler {
            for try await line in out.fileHandleForReading.bytes.lines {
                guard let data = line.data(using: .utf8),
                      let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                if let p = event["progress"] as? Double { progress(p, event["message"] as? String ?? "") }
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
    }

    /// Plain HTTP files into `directory`, reusing an identical local copy when
    /// there is one (an APFS clone, so it costs no extra disk).
    static func fetchFiles(_ files: [(url: URL, path: String, size: Int64, localCopy: URL?)], into directory: URL,
                           progress: @escaping @MainActor (Double, String) -> Void) async throws {
        let total = Double(files.reduce(0) { $0 + $1.size })
        var done: Int64 = 0
        let fm = FileManager.default
        for file in files {
            let destination = directory.appendingPathComponent(file.path)
            try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            let existing = (try? fm.attributesOfItem(atPath: destination.path))?[.size] as? Int64
            if existing != file.size {
                if let local = file.localCopy, (try? fm.attributesOfItem(atPath: local.path))?[.size] as? Int64 == file.size {
                    try? fm.removeItem(at: destination)
                    try fm.copyItem(at: local, to: destination)
                } else {
                    let base = done
                    try await SupertonicDownloader.fetch(file.url, to: destination) { bytes in
                        Task { @MainActor in progress(Double(base + bytes) / total, "Downloading \(file.url.lastPathComponent)…") }
                    }
                    let got = (try? fm.attributesOfItem(atPath: destination.path))?[.size] as? Int64
                    guard got == file.size else {
                        try? fm.removeItem(at: destination)
                        throw SpeechEngineError.notInstalled("\(file.url.lastPathComponent) came down as \(got ?? 0) bytes, expected \(file.size)")
                    }
                }
            }
            done += file.size
            progress(Double(done) / total, "Downloaded \(destination.lastPathComponent)")
        }
    }
}
