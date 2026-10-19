import Foundation
import OSLog

private let log = Logger(category: "models")

/// The bundled `narrateify-models` helper that runs on-demand models
/// (Qwen3-TTS on MLX, Kokoro on ONNX Runtime), one process per model.
enum ModelHelper {
    nonisolated static var executable: URL? {
        Bundle.main.sharedSupportURL?.appendingPathComponent("narrateify-models")
    }

    /// The helper is built for Apple silicon and macOS 15 (MLX's floor).
    nonisolated static var unsupportedReason: String? {
        #if !arch(arm64)
        return "Needs Apple silicon"
        #else
        if !ProcessInfo.processInfo.isOperatingSystemAtLeast(OperatingSystemVersion(majorVersion: 15, minorVersion: 0, patchVersion: 0)) {
            return "Needs macOS 15 or later"
        }
        guard let executable, FileManager.default.isExecutableFile(atPath: executable.path) else {
            return "Not included in this build"
        }
        return nil
        #endif
    }
}

/// Owns the helper process: starts it on demand, sends one request at a
/// time, notices when it has exited (idle timeout, crash) and restarts it.
/// Every wait has a deadline, so a hung GPU can't wedge later calls.
final class HelperWorker: @unchecked Sendable {
    /// One live helper. Only the request holding `gate` reads its stdout.
    private final class Helper: @unchecked Sendable {
        let process: Process
        let input: FileHandle
        private var lines: AsyncLineSequence<FileHandle.AsyncBytes>.AsyncIterator

        init(process: Process, input: FileHandle, output: FileHandle) {
            self.process = process
            self.input = input
            lines = output.bytes.lines.makeAsyncIterator()
            // A write to a helper that just died must fail, not SIGPIPE the app.
            _ = fcntl(input.fileDescriptor, F_SETNOSIGPIPE, 1)
        }

        /// Next JSON line, or nil at EOF (the helper exited).
        func next() async throws -> [String: Any]? {
            while let line = try await lines.next() {
                if let object = line.data(using: .utf8).flatMap({ try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }) {
                    return object
                }
            }
            return nil
        }
    }

    /// The helper went away under us (idle exit racing a request, crash, kill).
    private struct HelperGone: Error {}

    private let lock = NSLock()
    private var helper: Helper?
    private var nextID = 1
    private let gate = AsyncGate()
    /// `narrateify-models` arguments that serve this model, given the idle timeout.
    private let serveArguments: @Sendable (_ idleSeconds: Int) -> [String]
    /// Expected render speed: requests time out at several times this.
    private let secondsPerCharacter: Double

    init(secondsPerCharacter: Double, serveArguments: @escaping @Sendable (_ idleSeconds: Int) -> [String]) {
        self.secondsPerCharacter = secondsPerCharacter
        self.serveArguments = serveArguments
    }

    var isRunning: Bool { lock.withLock { helper?.process.isRunning ?? false } }

    func stop() {
        lock.withLock {
            helper?.process.terminate()
            helper = nil
        }
    }

    /// One section → WAV bytes. `voice` is model-specific (a preset name, or
    /// the path of a clip to clone).
    func synthesize(_ text: String, language: String, voice: String, idleSeconds: TimeInterval) async throws -> Data {
        await gate.enter()
        defer { gate.leave() }
        try Task.checkCancellation()

        // Several times the expected render time, so only a real hang trips it.
        let deadline = 60 + Double(text.count) * secondsPerCharacter * 5
        for attempt in 1...2 {
            let helper = try await start(idleSeconds: idleSeconds)
            do {
                return try await request(text, language: language, voice: voice, on: helper, deadline: deadline)
            } catch is HelperGone where attempt == 1 {
                discard(helper)   // requests are idempotent: start a fresh helper and resend once
            } catch is HelperGone {
                discard(helper)
                throw SpeechEngineError.synthesisFailed("The model helper exited mid-request")
            }
        }
        throw SpeechEngineError.synthesisFailed("unreachable")
    }

    private func request(_ text: String, language: String, voice: String, on helper: Helper,
                         deadline: TimeInterval) async throws -> Data {
        let id = lock.withLock { defer { nextID += 1 }; return nextID }
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("narrateify-model-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: out) }
        let request: [String: Any] = ["id": id, "text": text, "language": language,
                                      "voice": voice, "out": out.path]
        do {
            try helper.input.write(contentsOf: try JSONSerialization.data(withJSONObject: request) + Data("\n".utf8))
        } catch {
            throw HelperGone()
        }
        let reply = try await withDeadline(deadline, helper) {
            while let reply = try await helper.next() {
                if reply["id"] as? Int == id { return reply }
            }
            throw HelperGone()
        }
        if let error = reply["error"] as? String { throw SpeechEngineError.synthesisFailed(error) }
        return try Data(contentsOf: out)
    }

    /// The live helper, or a fresh one once it has loaded the model.
    private func start(idleSeconds: TimeInterval) async throws -> Helper {
        if let current = lock.withLock({ helper }), current.process.isRunning { return current }
        guard let executable = ModelHelper.executable else { throw SpeechEngineError.notInstalled("Helper missing") }

        let process = Process()
        process.executableURL = executable
        process.arguments = serveArguments(Int(idleSeconds))
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let started = Date()
        try process.run()
        let fresh = Helper(process: process, input: input.fileHandleForWriting, output: output.fileHandleForReading)

        // A cold disk can take ~45 s to page 2.9 GB in; anything past this is stuck.
        let ready = try await withTaskCancellationHandler {
            try await withDeadline(300, fresh) {
                while let event = try await fresh.next() {
                    if let error = event["error"] as? String { throw SpeechEngineError.notInstalled(error) }
                    if event["ready"] as? Bool == true { return true }
                }
                return false
            }
        } onCancel: {
            process.terminate()   // don't leave a 3 GB helper loading for nobody
        }
        guard ready else { throw SpeechEngineError.synthesisFailed("The model helper quit while loading") }
        log.notice("helper ready in \(Int(Date().timeIntervalSince(started) * 1000)) ms")
        lock.withLock { helper = fresh }
        return fresh
    }

    private func discard(_ dead: Helper) {
        dead.process.terminate()
        lock.withLock { if helper === dead { helper = nil } }
    }

    /// `body`, or kill the helper and throw once `seconds` pass (killing it
    /// ends the pending read with EOF, so the race always settles).
    private func withDeadline<T: Sendable>(_ seconds: TimeInterval, _ helper: Helper,
                                           _ body: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T?.self) { group in
            group.addTask { try await body() }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                return nil
            }
            defer { group.cancelAll() }
            if let value = try await group.next() ?? nil { return value }
            log.error("helper timed out after \(Int(seconds)) s; killing it")
            discard(helper)
            throw SpeechEngineError.synthesisFailed("The model timed out after \(Int(seconds)) s")
        }
    }
}

/// FIFO async mutex: one helper request at a time, in arrival order.
final class AsyncGate: @unchecked Sendable {
    private let lock = NSLock()
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func enter() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let proceed: Bool = lock.withLock {
                if busy { waiters.append(continuation); return false }
                busy = true
                return true
            }
            if proceed { continuation.resume() }
        }
    }

    func leave() {
        let next: CheckedContinuation<Void, Never>? = lock.withLock {
            if waiters.isEmpty { busy = false; return nil }
            return waiters.removeFirst()
        }
        next?.resume()
    }
}
