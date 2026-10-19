import Foundation
import OSLog

private let log = Logger(category: "qwen3")

/// Qwen3-TTS 1.7B (Base): the big local model, for voiceovers rather than
/// everyday reading. Never in a language's default chain; only used when a
/// caller asks for it (`engine: "qwen3"` / `model: "qwen3-tts-1.7b"`).
///
/// It runs in the `narrateify-qwen3` helper process, started on the first
/// call and exiting by itself after the idle timeout, so its ~3 GB is gone
/// when nobody's using it.
///
/// The Base model has no preset speakers, so every voice is cloned from a
/// reference clip: the built-in F1–M5 from the matching Supertonic voice
/// (rendered once, on first use), plus any clip you drop into
/// ~/Library/Application Support/Narrateify/Voices (or pass by path).
final class Qwen3Engine: SpeechEngine, @unchecked Sendable {
    let kind: SpeechEngineKind = .qwen3
    static let modelName = "qwen3-tts-1.7b"
    static let defaultVoiceID = "F1"

    /// Languages the model was trained on.
    static let languages: Set<String> = ["en", "de", "zh", "ja", "ko", "fr", "ru", "pt", "es", "it"]

    static var customVoicesDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Narrateify/Voices", isDirectory: true)
    }
    private static let audioExtensions: Set<String> = ["wav", "m4a", "mp3", "aiff", "aif", "caf", "flac"]

    /// Renders a built-in voice's reference clip (WAV bytes) — Supertonic.
    private let makeReference: @Sendable (String) async throws -> Data
    private let worker = Qwen3Worker()
    private let lock = NSLock()
    private var _idleUnloadAfter: TimeInterval = 600

    init(makeReference: @escaping @Sendable (String) async throws -> Data) {
        self.makeReference = makeReference
    }

    /// The helper quits after this long without a request (applies from its next start).
    var idleUnloadAfter: TimeInterval {
        get { lock.withLock { _idleUnloadAfter } }
        set { lock.withLock { _idleUnloadAfter = newValue } }
    }

    var isLoaded: Bool { worker.isRunning }

    func unload() { worker.stop() }

    // MARK: SpeechEngine

    func supports(_ language: ReadingLanguage) -> Bool { Self.languages.contains(language.base) }

    var unavailableReason: String? {
        if let reason = Qwen3ModelStore.unsupportedReason { return reason }
        return Qwen3ModelStore.isInstalled ? nil : Self.notInstalledMessage
    }

    static let notInstalledMessage =
        "Qwen3-TTS 1.7B isn't installed (about 2.9 GB). Run `narrateify install \(modelName)`, or retry with --install (API/MCP: install: true)."

    func voices(for language: ReadingLanguage) async -> [VoiceOption] {
        guard supports(language) else { return [] }
        let builtIn = SupertonicEngine.voices.map {
            VoiceOption(id: $0.id, name: $0.name.replacingOccurrences(of: "(\($0.id))", with: "(cloned from Supertonic \($0.id))"),
                        languages: ["*"])
        }
        return builtIn + Self.customVoices()
    }

    /// Clips in ~/Library/Application Support/Narrateify/Voices, by file name.
    static func customVoices() -> [VoiceOption] {
        let files = (try? FileManager.default.contentsOfDirectory(at: customVoicesDirectory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { audioExtensions.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map { VoiceOption(id: $0.deletingPathExtension().lastPathComponent,
                               name: "\($0.deletingPathExtension().lastPathComponent) (your clip)", languages: ["*"]) }
    }

    func synthesize(_ text: String, language: ReadingLanguage, voiceID: String) async throws -> SynthesizedSpeech {
        if let reason = unavailableReason { throw SpeechEngineError.notInstalled(reason) }
        guard supports(language) else {
            throw SpeechEngineError.unsupportedLanguage("Qwen3-TTS doesn't speak \(language.code)")
        }
        let reference = try await referenceClip(for: voiceID.isEmpty ? Self.defaultVoiceID : voiceID)
        let audio = try await worker.synthesize(text, language: language.base, reference: reference,
                                                idleSeconds: idleUnloadAfter)
        return SynthesizedSpeech(audio: audio, fileExtension: "wav", words: [])
    }

    /// The clip a voice is cloned from: an absolute path, a clip in the
    /// Voices folder, or a built-in voice (rendered with Supertonic once).
    private func referenceClip(for voiceID: String) async throws -> URL {
        let fm = FileManager.default
        if voiceID.hasPrefix("/") {
            guard fm.fileExists(atPath: voiceID) else { throw SpeechEngineError.synthesisFailed("No reference clip at \(voiceID)") }
            return URL(fileURLWithPath: voiceID)
        }
        let custom = (try? fm.contentsOfDirectory(at: Self.customVoicesDirectory, includingPropertiesForKeys: nil))?
            .first { $0.deletingPathExtension().lastPathComponent == voiceID && Self.audioExtensions.contains($0.pathExtension.lowercased()) }
        if let custom { return custom }

        guard SupertonicEngine.voices.contains(where: { $0.id == voiceID }) else {
            throw SpeechEngineError.synthesisFailed("Unknown Qwen3 voice \(voiceID)")
        }
        let url = Qwen3ModelStore.voicesDirectory.appendingPathComponent("\(voiceID).wav")
        if fm.fileExists(atPath: url.path) { return url }
        log.notice("rendering reference clip for \(voiceID, privacy: .public)")
        let wav = try await makeReference(voiceID)
        try fm.createDirectory(at: Qwen3ModelStore.voicesDirectory, withIntermediateDirectories: true)
        try wav.write(to: url, options: .atomic)
        return url
    }

    /// What the built-in references say: ~10 s of calm, varied speech.
    static let referenceText = "Good morning. This is a reference recording, read calmly and clearly, so the larger model can learn what this voice sounds like."
}

/// Owns the helper process: starts it on demand, sends one request at a
/// time, notices when it has exited (idle timeout, crash) and restarts it.
/// Every wait has a deadline, so a hung GPU can't wedge later calls.
final class Qwen3Worker: @unchecked Sendable {
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

    var isRunning: Bool { lock.withLock { helper?.process.isRunning ?? false } }

    func stop() {
        lock.withLock {
            helper?.process.terminate()
            helper = nil
        }
    }

    func synthesize(_ text: String, language: String, reference: URL, idleSeconds: TimeInterval) async throws -> Data {
        await gate.enter()
        defer { gate.leave() }
        try Task.checkCancellation()

        // ~0.5× real time and ~15 chars/s of speech: this is several times
        // the expected render time, so only a real hang trips it.
        let deadline = 60 + Double(text.count) * 0.5
        for attempt in 1...2 {
            let helper = try await start(idleSeconds: idleSeconds)
            do {
                return try await request(text, language: language, reference: reference, on: helper, deadline: deadline)
            } catch is HelperGone where attempt == 1 {
                discard(helper)   // requests are idempotent: start a fresh helper and resend once
            } catch is HelperGone {
                discard(helper)
                throw SpeechEngineError.synthesisFailed("The Qwen3 helper exited mid-request")
            }
        }
        throw SpeechEngineError.synthesisFailed("unreachable")
    }

    private func request(_ text: String, language: String, reference: URL, on helper: Helper,
                         deadline: TimeInterval) async throws -> Data {
        let id = lock.withLock { defer { nextID += 1 }; return nextID }
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("narrateify-qwen3-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: out) }
        let request: [String: Any] = ["id": id, "text": text, "language": language,
                                      "reference": reference.path, "out": out.path]
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
        guard let executable = Qwen3ModelStore.helper else { throw SpeechEngineError.notInstalled("Helper missing") }

        let process = Process()
        process.executableURL = executable
        process.arguments = ["serve", "--model-id", Qwen3ModelStore.modelID,
                             "--model-dir", Qwen3ModelStore.modelDirectory.path,
                             "--tokenizer-dir", Qwen3ModelStore.tokenizerDirectory.path,
                             "--idle", String(Int(idleSeconds))]
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
        guard ready else { throw SpeechEngineError.synthesisFailed("The Qwen3 helper quit while loading") }
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
            throw SpeechEngineError.synthesisFailed("Qwen3 timed out after \(Int(seconds)) s")
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
