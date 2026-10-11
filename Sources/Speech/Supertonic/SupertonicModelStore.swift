import Foundation

/// Installs / removes the Supertonic 3 weights (~401 MB) under
/// `~/Library/Application Support/Narrateify/Models/supertonic-3/`.
///
/// Files land in a sibling staging folder first; each is size/hash-checked
/// before it counts, and the folder is renamed into place only when complete,
/// so the engine never sees a half-installed model. An interrupted install
/// resumes by skipping files already verified in staging.
@MainActor
final class SupertonicModelStore: ObservableObject {
    enum InstallState: Equatable {
        case notInstalled
        /// 0…1 over all bytes.
        case downloading(progress: Double)
        case installed
        case failed(String)
    }

    nonisolated static let defaultDirectory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Narrateify/Models/supertonic-3", isDirectory: true)
    }()

    /// Total download size, for "Download (401 MB)" labels.
    nonisolated static let downloadSize: Int64 = SupertonicManifest.totalBytes

    @Published private(set) var state: InstallState = .notInstalled
    @Published private(set) var diskUsage: Int64 = 0

    let directory: URL
    private var stagingDirectory: URL {
        directory.deletingLastPathComponent().appendingPathComponent(".\(directory.lastPathComponent).partial")
    }
    private var installTask: Task<Void, Error>?

    init(directory: URL = SupertonicModelStore.defaultDirectory) {
        self.directory = directory
        refresh()
    }

    var isInstalled: Bool { state == .installed }

    /// Re-derive state from disk (cheap: stats 16 files).
    func refresh() {
        if case .downloading = state { return }
        state = SupertonicManifest.isComplete(at: directory) ? .installed : .notInstalled
        diskUsage = Self.allocatedSize(of: [directory, stagingDirectory])
    }

    /// Start (or resume) the download in the background. No-op if already
    /// installed or downloading. Observe `state` for progress.
    func install() {
        guard installTask == nil, state != .installed else { return }
        installTask = Task { try await self.runInstall() }
    }

    /// Like `install()` but awaits completion and rethrows failures.
    func installAndWait() async throws {
        if state == .installed { return }
        if installTask == nil { install() }
        try await installTask?.value
    }

    /// Stop an in-flight download. Verified files are kept for resume.
    func cancel() {
        installTask?.cancel()
    }

    /// Delete the model (and any partial download). Unload the engine first.
    func uninstall() throws {
        installTask?.cancel()
        installTask = nil
        let fm = FileManager.default
        for url in [directory, stagingDirectory] where fm.fileExists(atPath: url.path) {
            try fm.removeItem(at: url)
        }
        state = .notInstalled
        diskUsage = 0
    }

    // MARK: Install

    private func runInstall() async throws {
        defer { installTask = nil }
        let staging = stagingDirectory
        let finalDir = directory
        let total = Double(SupertonicManifest.totalBytes)
        var doneBytes: Int64 = 0
        let alreadyStaged = SupertonicManifest.files
            .filter { SupertonicManifest.fileSize(staging.appendingPathComponent($0.path)) == $0.size }
            .reduce(Int64(0)) { $0 + $1.size }
        state = .downloading(progress: Double(alreadyStaged) / total)
        do {
            for file in SupertonicManifest.files {
                let target = staging.appendingPathComponent(file.path)
                // Present in staging ⇒ already verified on a previous run.
                if SupertonicManifest.fileSize(target) != file.size {
                    let partial = target.appendingPathExtension("download")
                    let base = doneBytes
                    try await SupertonicDownloader.fetch(SupertonicManifest.url(for: file), to: partial) { got in
                        Task { @MainActor [weak self] in self?.report(Double(base + got) / total) }
                    }
                    try Task.checkCancellation()
                    try await Task.detached(priority: .utility) {
                        try SupertonicManifest.verify(file, at: partial)
                        try? FileManager.default.removeItem(at: target)
                        try FileManager.default.moveItem(at: partial, to: target)
                    }.value
                }
                doneBytes += file.size
                report(Double(doneBytes) / total)
            }
            try Task.checkCancellation()
            let fm = FileManager.default
            if fm.fileExists(atPath: finalDir.path) { try fm.removeItem(at: finalDir) }
            try fm.moveItem(at: staging, to: finalDir)
            state = .installed
            diskUsage = Self.allocatedSize(of: [finalDir])
        } catch {
            if error is CancellationError || (error as? URLError)?.code == .cancelled {
                state = .notInstalled
                diskUsage = Self.allocatedSize(of: [finalDir, staging])
                throw CancellationError()
            }
            state = .failed(error.localizedDescription)
            throw error
        }
    }

    /// Publishes progress in ≥0.5% steps so SwiftUI isn't hammered per packet.
    private func report(_ progress: Double) {
        guard case .downloading(let old) = state else { return }
        let p = min(max(progress, 0), 1)
        if p - old >= 0.005 || p == 1 { state = .downloading(progress: p) }
    }

    nonisolated private static func allocatedSize(of dirs: [URL]) -> Int64 {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
        var total: Int64 = 0
        for dir in dirs {
            guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: keys) else { continue }
            for case let url as URL in e {
                let v = try? url.resourceValues(forKeys: Set(keys))
                total += Int64(v?.totalFileAllocatedSize ?? v?.fileAllocatedSize ?? 0)
            }
        }
        return total
    }
}
