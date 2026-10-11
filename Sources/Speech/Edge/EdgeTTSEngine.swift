import Foundation

/// Microsoft Edge "Read Aloud" voices over the browser's WebSocket API.
/// One connection per section; MP3 out; real word timings from WordBoundary
/// metadata. Every failure to reach or be accepted by the service maps to
/// `.serviceUnavailable` quickly (4 s connect deadline) so the router can fall
/// back and bench the engine.
///
/// Sections are sent as one SSML request; keep them well under ~4 KB of text
/// (edge-tts splits at 4096 bytes of escaped text — the service drops more).
final class EdgeTTSEngine: SpeechEngine {
    let kind: SpeechEngineKind = .edge

    /// Tried in rotation, starting from the last one that worked.
    let endpoints: [EdgeEndpoint]
    let catalog: EdgeVoiceCatalog
    let connectTimeout: TimeInterval
    /// Handshake rejections (e.g. HTTP 403) are retried on a fresh connection,
    /// rotating endpoints, up to this many attempts in total. During the v2
    /// rollout (rany2/edge-tts#490) the classic host is rejected by *some*
    /// front-door nodes only (~50% from Zurich, 2026-10-11) and a rejection
    /// takes ~0.1 s, so retrying is cheap.
    let handshakeAttempts: Int

    private let preferredLock = NSLock()
    private var preferred = 0

    init(endpoints: [EdgeEndpoint] = EdgeEndpointV1.all,
         catalog: EdgeVoiceCatalog = .shared,
         connectTimeout: TimeInterval = 4,
         handshakeAttempts: Int = 4) {
        precondition(!endpoints.isEmpty)
        self.endpoints = endpoints
        self.catalog = catalog
        self.connectTimeout = connectTimeout
        self.handshakeAttempts = max(1, handshakeAttempts)
    }

    /// Single endpoint with its own uncached catalog (tests, diagnostics).
    convenience init(endpoint: EdgeEndpoint, connectTimeout: TimeInterval = 4, handshakeAttempts: Int = 4) {
        self.init(endpoints: [endpoint],
                  catalog: EdgeVoiceCatalog(endpoints: [endpoint], cacheURL: nil),
                  connectTimeout: connectTimeout, handshakeAttempts: handshakeAttempts)
    }

    /// Overall budget for one section: generation is much faster than real
    /// time, so this only trips when the service stalls.
    static func overallTimeout(forTextLength n: Int, connect: TimeInterval) -> TimeInterval {
        connect + 6 + Double(n) * 0.04
    }

    func supports(_ language: ReadingLanguage) -> Bool {
        let code = language.code.lowercased()
        return catalog.knownLocales().contains { $0 == code || $0.hasPrefix(language.base + "-") }
    }

    func voices(for language: ReadingLanguage) async -> [VoiceOption] {
        await catalog.voices(for: language).map(\.option)
    }

    func synthesize(_ text: String, language: ReadingLanguage, voiceID: String) async throws -> SynthesizedSpeech {
        guard text.contains(where: { $0.isLetter || $0.isNumber }) else {
            throw SpeechEngineError.synthesisFailed("Nothing speakable in section")
        }
        let first = preferredLock.withLock { preferred }
        let start = Date()
        var failures: [String] = []
        for i in 0..<handshakeAttempts {
            let index = (first + i) % endpoints.count
            let name = endpoints[index].name
            do {
                let speech = try await attempt(text, language: language, voiceID: voiceID, endpoint: endpoints[index])
                preferredLock.withLock { preferred = index }
                return speech
            } catch let rejected as HandshakeRejected {
                failures.append("\(name): HTTP \(rejected.status)")
                // A wrong local clock produces a stale token: re-anchor to the
                // server's clock before the next try (no-op if we're in sync).
                if let date = rejected.serverDate { EdgeClock.shared.adjust(toServerDate: date) }
            } catch let unreachable as Unreachable {
                failures.append("\(name): \(unreachable.message)")
            }
            // Only fast failures rotate; never spend more than one connect budget.
            try Task.checkCancellation()
            if Date().timeIntervalSince(start) > connectTimeout { break }
        }
        throw SpeechEngineError.serviceUnavailable("Edge TTS unavailable (\(failures.joined(separator: ", ")))")
    }

    // MARK: - One connection

    /// The server answered the upgrade with an HTTP error (403 = token/node rejected).
    struct HandshakeRejected: Error {
        let status: Int
        let serverDate: String?
    }

    /// Failed fast before connecting (DNS, refused, offline). Connect timeouts
    /// are not this — they already used the whole budget.
    struct Unreachable: Error {
        let message: String
    }

    private func attempt(_ text: String, language: ReadingLanguage, voiceID: String,
                         endpoint: EdgeEndpoint) async throws -> SynthesizedSpeech {
        let now = EdgeClock.shared.now()
        let request = endpoint.synthesisRequest(connectionID: EdgeProtocol.newID(), now: now)
        // Fresh session per attempt: a pooled keep-alive connection after a
        // 403 would pin retries to the same rejecting front-door node.
        let session = EdgeHTTP.makeSession()
        let ws = session.webSocketTask(with: request)
        ws.maximumMessageSize = 4 << 20
        let deadline = Deadline(socket: ws)
        ws.resume()
        defer {
            ws.cancel(with: .normalClosure, reason: nil)
            session.invalidateAndCancel()
        }

        let overall = Self.overallTimeout(forTextLength: text.utf16.count, connect: connectTimeout)
        return try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(of: SynthesizedSpeech?.self) { group in
                group.addTask {
                    try await self.run(ws, deadline: deadline, text: text,
                                       language: language, voiceID: voiceID)
                }
                group.addTask {
                    // Watchdog: first the handshake, then the whole section. It
                    // only cancels the socket; the receiving task reports why.
                    try await Task.sleep(nanoseconds: UInt64(self.connectTimeout * 1e9))
                    guard deadline.isConnected else {
                        deadline.fire(.timedOut("Edge TTS connect timed out after \(Int(self.connectTimeout)) s"))
                        return nil
                    }
                    try await Task.sleep(nanoseconds: UInt64((overall - self.connectTimeout) * 1e9))
                    deadline.fire(.timedOut("Edge TTS timed out after \(Int(overall)) s"))
                    return nil
                }
                defer { group.cancelAll() }
                while let result = try await group.next() {
                    if let speech = result { return speech }
                }
                throw SpeechEngineError.serviceUnavailable("Edge TTS produced no result")
            }
        } onCancel: {
            deadline.fire(.cancelled)
        }
    }

    private func run(_ ws: URLSessionWebSocketTask, deadline: Deadline,
                     text: String, language: ReadingLanguage, voiceID: String) async throws -> SynthesizedSpeech {
        do {
            // send() completes only once the handshake succeeded.
            try await ws.send(.string(EdgeProtocol.speechConfigMessage(timestamp: EdgeProtocol.timestamp())))
            deadline.markConnected()
            let ssml = EdgeProtocol.ssml(text: text, voiceID: voiceID, languageCode: language.code)
            try await ws.send(.string(EdgeProtocol.ssmlMessage(requestID: EdgeProtocol.newID(),
                                                               timestamp: EdgeProtocol.timestamp(),
                                                               ssml: ssml)))
            var audio = Data()
            var boundaries: [EdgeProtocol.Boundary] = []
            receiving: while true {
                switch try await ws.receive() {
                case .string(let s):
                    let frame = try EdgeProtocol.parseTextFrame(s)
                    switch frame.path {
                    // A bad metadata frame costs highlights, not the audio.
                    case "audio.metadata": boundaries += (try? EdgeProtocol.parseMetadata(frame.body)) ?? []
                    case "turn.end": break receiving
                    default: continue
                    }
                case .data(let d):
                    let frame = try EdgeProtocol.parseBinaryFrame(d)
                    if frame.path == "audio", frame.headers["Content-Type"] == "audio/mpeg" {
                        audio.append(frame.body)
                    }
                @unknown default:
                    continue
                }
            }
            guard !audio.isEmpty else {
                throw SpeechEngineError.synthesisFailed("Edge TTS returned no audio (voice \(voiceID))")
            }
            return SynthesizedSpeech(audio: audio, fileExtension: "mp3",
                                     words: EdgeWordAligner.align(boundaries, in: text))
        } catch {
            throw classify(error, ws: ws, deadline: deadline)
        }
    }

    private func classify(_ error: Error, ws: URLSessionWebSocketTask, deadline: Deadline) -> Error {
        switch deadline.reason {
        case .timedOut(let msg): return SpeechEngineError.serviceUnavailable(msg)
        case .cancelled: return CancellationError()
        case nil: break
        }
        if let e = error as? SpeechEngineError { return e }
        if let http = ws.response as? HTTPURLResponse, http.statusCode != 101 {
            return HandshakeRejected(status: http.statusCode,
                                     serverDate: http.value(forHTTPHeaderField: "Date"))
        }
        if error is EdgeProtocol.ParseError {
            return SpeechEngineError.synthesisFailed("Edge TTS sent an unexpected frame: \(error)")
        }
        if !deadline.isConnected {
            return Unreachable(message: error.localizedDescription)
        }
        // Connected, then the socket died mid-stream (bad voice name, server drop).
        if let close = closeReason(ws) {
            return SpeechEngineError.synthesisFailed("Edge TTS closed the connection: \(close)")
        }
        return SpeechEngineError.serviceUnavailable("Edge TTS connection lost: \(error.localizedDescription)")
    }

    private func closeReason(_ ws: URLSessionWebSocketTask) -> String? {
        guard ws.closeCode != .invalid else { return nil }
        let reason = ws.closeReason.map { String(decoding: $0, as: UTF8.self) } ?? ""
        return "code \(ws.closeCode.rawValue) \(reason)".trimmingCharacters(in: .whitespaces)
    }
}

/// Shared between the receiving task and the watchdog: records whether the
/// handshake finished and, if the watchdog fired, why. Firing cancels the
/// socket, which unblocks any pending send/receive immediately.
private final class Deadline: @unchecked Sendable {
    enum Reason { case timedOut(String), cancelled }

    private let lock = NSLock()
    private let socket: URLSessionWebSocketTask
    private var connected = false
    private var _reason: Reason?

    init(socket: URLSessionWebSocketTask) { self.socket = socket }

    var isConnected: Bool { lock.withLock { connected } }
    var reason: Reason? { lock.withLock { _reason } }

    func markConnected() { lock.withLock { connected = true } }

    func fire(_ reason: Reason) {
        lock.withLock { if _reason == nil { _reason = reason } }
        socket.cancel(with: .goingAway, reason: nil)
    }
}
