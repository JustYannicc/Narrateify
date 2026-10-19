import Foundation

/// Installs / removes the Supertonic 3 weights under
/// `~/Library/Application Support/Narrateify/Models/supertonic-3/`
/// (~220 MB with the Core ML decoder on macOS 15+, ~401 MB ONNX-only on 14).
///
/// Files land in a sibling staging folder first; each is size/hash-checked
/// before it counts, and the folder is renamed into place only when complete,
/// so the engine never sees a half-installed model. An interrupted install
/// resumes by skipping files already verified in staging, and files from an
/// older install (e.g. the ONNX-only layout) are reused instead of re-fetched.
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

    /// Total download size for this Mac's backend, for "Download (220 MB)" labels.
    nonisolated static var downloadSize: Int64 { SupertonicManifest.totalBytes(for: .current) }

    @Published private(set) var state: InstallState = .notInstalled
    @Published private(set) var diskUsage: Int64 = 0
    /// Which complete install is on disk (nil = none). Stays set during an
    /// upgrade download, so synthesis keeps working on the old backend.
    @Published private(set) var installedBackend: SupertonicBackend?
    /// Why the last upgrade failed (the old install still works).
    @Published private(set) var upgradeError: String?

    let directory: URL
    /// The backend `install()` / `upgrade()` download for (best for this Mac).
    let backend: SupertonicBackend
    private var files: [SupertonicManifest.File] { SupertonicManifest.files(for: backend) }
    private var stagingDirectory: URL {
        directory.deletingLastPathComponent().appendingPathComponent(".\(directory.lastPathComponent).partial")
    }
    private var installTask: Task<Void, Error>?

    init(directory: URL = SupertonicModelStore.defaultDirectory, backend: SupertonicBackend = .current) {
        self.directory = directory
        self.backend = backend
        refresh()
    }

    /// A usable model is on disk (either backend), even mid-upgrade.
    var isInstalled: Bool { installedBackend != nil }

    /// An older ONNX-only install works, but this Mac can run the much faster
    /// Core ML decoder whose files aren't downloaded yet. Call `upgrade()`.
    var upgradeAvailable: Bool { installedBackend != nil && installedBackend != backend }

    /// Re-derive state from disk (cheap: stats ~24 files).
    func refresh() {
        readDisk()
        if case .downloading = state { return }
        state = isInstalled ? .installed : .notInstalled
    }

    private func readDisk() {
        installedBackend = SupertonicBackend.installed(at: directory, preferred: backend)
        diskUsage = Self.allocatedSize(of: [directory, stagingDirectory])
    }

    /// Start (or resume) the download in the background. No-op if the best
    /// backend is already installed or a download is running. Observe `state`
    /// for progress (it reads `.downloading` during an upgrade too).
    func install() {
        guard installTask == nil, installedBackend != backend else { return }
        upgradeError = nil
        installTask = Task { try await self.runInstall() }
    }

    /// Fetch the Core ML files for an existing ONNX install (~178 MB; shared
    /// files are reused). The old install keeps working until the new one is
    /// swapped in; call `SupertonicEngine.unload()` afterwards to switch.
    func upgrade() {
        guard upgradeAvailable else { return }
        install()
    }

    /// Like `install()` but awaits completion and rethrows failures.
    func installAndWait() async throws {
        if installedBackend == backend { return }
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
        installedBackend = nil
        diskUsage = 0
    }

    // MARK: Install

    private func runInstall() async throws {
        defer { installTask = nil }
        let staging = stagingDirectory
        let finalDir = directory
        let files = self.files
        let total = Double(SupertonicManifest.totalBytes(for: backend))
        var doneBytes: Int64 = 0
        Self.reuseInstalledFiles(files, from: finalDir, into: staging)
        let alreadyStaged = files
            .filter { SupertonicManifest.fileSize(staging.appendingPathComponent($0.path)) == $0.size }
            .reduce(Int64(0)) { $0 + $1.size }
        state = .downloading(progress: Double(alreadyStaged) / total)
        do {
            for file in files {
                let target = staging.appendingPathComponent(file.path)
                // Present in staging ⇒ already verified on a previous run.
                if SupertonicManifest.fileSize(target) != file.size {
                    let partial = target.appendingPathExtension("download")
                    let base = doneBytes
                    try await SupertonicDownloader.fetch(file.url, to: partial) { got in
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
            if fm.fileExists(atPath: finalDir.path) {
                // Atomic directory swap (rename-swap on APFS): a concurrent
                // engine load sees either the old or the new install, never neither.
                _ = try fm.replaceItemAt(finalDir, withItemAt: staging)
            } else {
                try fm.moveItem(at: staging, to: finalDir)
            }
            try? fm.removeItem(at: staging)
            readDisk()
            state = installedBackend == backend ? .installed : .failed("Installed files failed verification")
        } catch {
            let cancelled = error is CancellationError || (error as? URLError)?.code == .cancelled
            if !cancelled, isInstalled { upgradeError = error.localizedDescription }
            state = isInstalled ? .installed : (cancelled ? .notInstalled : .failed(error.localizedDescription))
            diskUsage = Self.allocatedSize(of: [finalDir, staging])
            throw cancelled ? CancellationError() : error
        }
    }

    /// Publishes progress in ≥0.5% steps so SwiftUI isn't hammered per packet.
    private func report(_ progress: Double) {
        guard case .downloading(let old) = state else { return }
        let p = min(max(progress, 0), 1)
        if p - old >= 0.005 || p == 1 { state = .downloading(progress: p) }
    }

    /// Clones (APFS copy-on-write, so ~free) still-valid files from the current
    /// install into staging, so an upgrade only downloads what changed.
    nonisolated private static func reuseInstalledFiles(_ files: [SupertonicManifest.File], from installed: URL,
                                                        into staging: URL) {
        let fm = FileManager.default
        for file in files {
            let src = installed.appendingPathComponent(file.path), dst = staging.appendingPathComponent(file.path)
            guard SupertonicManifest.fileSize(dst) != file.size, SupertonicManifest.fileSize(src) == file.size else {
                continue
            }
            try? fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fm.removeItem(at: dst)
            try? fm.copyItem(at: src, to: dst)
        }
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
