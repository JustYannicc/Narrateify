import Foundation

/// One open WebSocket to the service: handshake done and `speech.config` sent,
/// ready for any number of sequential SSML turns.
///
/// Measured 2026-10-11 (api.msedgeservices.com from Zurich): the upgrade costs
/// ~120 ms (server-side; TCP+TLS ~15 ms), one socket serves repeated turns
/// without re-sending `speech.config`, and the server closes an idle socket
/// after 300 s ("Exceeded maximum websocket connection idle duration").
final class EdgeConnection: @unchecked Sendable {
    let endpointIndex: Int
    let endpointName: String
    /// Handshake + speech.config, seconds.
    let connectDuration: TimeInterval

    private let session: URLSession
    private let ws: URLSessionWebSocketTask
    private let lock = NSLock()
    private var sink: ((Event) -> Void)?
    private var failure: Error?
    private var _lastUsed = Date()
    private var _turns = 0

    private enum Event {
        case message(URLSessionWebSocketTask.Message)
        case failed(Error)
    }

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

    enum TurnFailure: Error {
        /// Nothing came back: the socket was dead or unresponsive. Safe to
        /// retry on a fresh connection; the error is what to report otherwise.
        case stale(SpeechEngineError)
        case failed(SpeechEngineError)
    }

    /// Pieces of a turn as they arrive, for streaming playback.
    enum Chunk {
        case audio(Data)
        case boundaries([EdgeProtocol.Boundary])
    }

    struct TurnResult {
        var audio = Data()
        var boundaries: [EdgeProtocol.Boundary] = []
        var firstFrame: TimeInterval?
        var firstAudio: TimeInterval?
        var total: TimeInterval = 0
    }

    private init(endpointIndex: Int, endpointName: String, connectDuration: TimeInterval,
                 session: URLSession, ws: URLSessionWebSocketTask) {
        self.endpointIndex = endpointIndex
        self.endpointName = endpointName
        self.connectDuration = connectDuration
        self.session = session
        self.ws = ws
    }

    deinit { close() }

    var lastUsed: Date { lock.withLock { _lastUsed } }
    var turns: Int { lock.withLock { _turns } }

    /// Cheap local check; a half-open socket still passes (the first-frame
    /// deadline in `speak` catches that).
    var isAlive: Bool {
        lock.withLock { failure == nil } && ws.state == .running && ws.closeCode == .invalid
    }

    func close() {
        ws.cancel(with: .normalClosure, reason: nil)
        session.invalidateAndCancel()
    }

    // MARK: Open

    static func open(endpoint: EdgeEndpoint, index: Int, timeout: TimeInterval) async throws -> EdgeConnection {
        let start = Date()
        let request = endpoint.synthesisRequest(connectionID: EdgeProtocol.newID(), now: EdgeClock.shared.now())
        // Fresh session per connection: a pooled keep-alive connection after a
        // 403 would pin retries to the same rejecting front-door node.
        let session = EdgeHTTP.makeSocketSession()
        let ws = session.webSocketTask(with: request)
        ws.maximumMessageSize = 4 << 20
        ws.resume()

        let timedOut = EdgeLatch()
        let watchdog = Task {
            try await Task.sleep(nanoseconds: UInt64(timeout * 1e9))
            timedOut.set()
            ws.cancel(with: .goingAway, reason: nil)
        }
        defer { watchdog.cancel() }
        do {
            // send() completes only once the handshake succeeded.
            try await withTaskCancellationHandler {
                try await ws.send(.string(EdgeProtocol.speechConfigMessage(timestamp: EdgeProtocol.timestamp())))
            } onCancel: {
                ws.cancel(with: .goingAway, reason: nil)
            }
        } catch {
            session.invalidateAndCancel()
            if Task.isCancelled { throw CancellationError() }
            if timedOut.isSet {
                throw SpeechEngineError.serviceUnavailable("Edge TTS connect timed out after \(Int(timeout)) s")
            }
            if let http = ws.response as? HTTPURLResponse, http.statusCode != 101 {
                throw HandshakeRejected(status: http.statusCode, serverDate: http.value(forHTTPHeaderField: "Date"))
            }
            throw Unreachable(message: error.localizedDescription)
        }
        let connection = EdgeConnection(endpointIndex: index, endpointName: endpoint.name,
                                        connectDuration: Date().timeIntervalSince(start),
                                        session: session, ws: ws)
        connection.startReading()
        return connection
    }

    /// One reader for the socket's whole life. Between turns nothing should
    /// arrive; an error there marks the connection dead so it isn't reused.
    private func startReading() {
        Task { [weak self, ws] in
            while true {
                do {
                    let message = try await ws.receive()
                    self?.deliver(.message(message))
                } catch {
                    self?.deliver(.failed(error))
                    return
                }
            }
        }
    }

    private func deliver(_ event: Event) {
        let sink: ((Event) -> Void)? = lock.withLock {
            if case .failed(let e) = event, failure == nil { failure = e }
            return self.sink
        }
        sink?(event)
    }

    // MARK: Turn

    /// Speak one SSML document and collect its audio and word boundaries.
    /// - Parameter firstFrameTimeout: for a reused socket, how long to wait for
    ///   the server's first reply (normally ~50 ms) before calling it stale.
    /// - Parameter onChunk: sees each audio/metadata frame as it arrives.
    func speak(ssml: String, timeout: TimeInterval, firstFrameTimeout: TimeInterval?,
               onChunk: (Chunk) -> Void = { _ in }) async throws -> TurnResult {
        let (events, continuation) = AsyncStream<Event>.makeStream()
        let alreadyDead: Error? = lock.withLock {
            if failure == nil { sink = { continuation.yield($0) } }
            _turns += 1
            return failure
        }
        if let alreadyDead {
            throw TurnFailure.stale(.serviceUnavailable("Edge TTS connection lost: \(alreadyDead.localizedDescription)"))
        }
        defer {
            lock.withLock { sink = nil; _lastUsed = Date() }
            continuation.finish()
        }

        let start = Date()
        let gotFrame = EdgeLatch()
        let reason = EdgeBox<TimeoutReason>()
        let watchdog = Task { [weak self] in
            if let firstFrameTimeout {
                try await Task.sleep(nanoseconds: UInt64(firstFrameTimeout * 1e9))
                if !gotFrame.isSet {
                    reason.set(.noResponse(firstFrameTimeout))
                    self?.ws.cancel(with: .goingAway, reason: nil)
                    return
                }
            }
            let left = timeout - Date().timeIntervalSince(start)
            try await Task.sleep(nanoseconds: UInt64(max(0, left) * 1e9))
            reason.set(.timedOut(timeout))
            self?.ws.cancel(with: .goingAway, reason: nil)
        }
        defer { watchdog.cancel() }

        var result = TurnResult()
        do {
            try await withTaskCancellationHandler {
                try await ws.send(.string(EdgeProtocol.ssmlMessage(requestID: EdgeProtocol.newID(),
                                                                   timestamp: EdgeProtocol.timestamp(),
                                                                   ssml: ssml)))
                for await event in events {
                    switch event {
                    case .failed(let error):
                        throw error
                    case .message(let message):
                        if !gotFrame.isSet {
                            gotFrame.set()
                            result.firstFrame = Date().timeIntervalSince(start)
                        }
                        if try handle(message, into: &result, start: start, onChunk: onChunk) {
                            result.total = Date().timeIntervalSince(start)
                            return
                        }
                    }
                }
                throw CancellationError()
            } onCancel: { [ws] in
                ws.cancel(with: .goingAway, reason: nil)
            }
        } catch {
            throw classify(error, reason: reason.value, gotFrame: gotFrame.isSet)
        }
        guard !result.audio.isEmpty else {
            throw TurnFailure.failed(.synthesisFailed("Edge TTS returned no audio"))
        }
        return result
    }

    /// Returns true on `turn.end`.
    private func handle(_ message: URLSessionWebSocketTask.Message, into r: inout TurnResult, start: Date,
                        onChunk: (Chunk) -> Void) throws -> Bool {
        switch message {
        case .string(let s):
            let frame = try EdgeProtocol.parseTextFrame(s)
            switch frame.path {
            // A bad metadata frame costs highlights, not the audio.
            case "audio.metadata":
                let boundaries = (try? EdgeProtocol.parseMetadata(frame.body)) ?? []
                r.boundaries += boundaries
                if !boundaries.isEmpty { onChunk(.boundaries(boundaries)) }
            case "turn.end": return true
            default: break
            }
        case .data(let d):
            let frame = try EdgeProtocol.parseBinaryFrame(d)
            if frame.path == "audio", frame.headers["Content-Type"] == "audio/mpeg", !frame.body.isEmpty {
                if r.firstAudio == nil { r.firstAudio = Date().timeIntervalSince(start) }
                r.audio.append(frame.body)
                onChunk(.audio(frame.body))
            }
        @unknown default:
            break
        }
        return false
    }

    private enum TimeoutReason {
        case noResponse(TimeInterval)
        case timedOut(TimeInterval)
    }

    private func classify(_ error: Error, reason: TimeoutReason?, gotFrame: Bool) -> Error {
        switch reason {
        case .noResponse(let s):
            return TurnFailure.stale(.serviceUnavailable("Edge TTS didn't respond within \(s) s"))
        case .timedOut(let s):
            return TurnFailure.failed(.serviceUnavailable("Edge TTS timed out after \(Int(s)) s"))
        case nil:
            break
        }
        if error is CancellationError || Task.isCancelled { return CancellationError() }
        if error is EdgeProtocol.ParseError {
            return TurnFailure.failed(.synthesisFailed("Edge TTS sent an unexpected frame: \(error)"))
        }
        if ws.closeCode != .invalid {
            // The server closed on this request (e.g. unknown voice): a fresh
            // socket would fail the same way. (A close *between* turns shows
            // up as `alreadyDead` → stale instead.)
            let why = ws.closeReason.map { String(decoding: $0, as: UTF8.self) } ?? ""
            return TurnFailure.failed(.synthesisFailed("Edge TTS closed the connection: code \(ws.closeCode.rawValue) \(why)"))
        }
        let engineError = SpeechEngineError.serviceUnavailable("Edge TTS connection lost: \(error.localizedDescription)")
        return gotFrame ? TurnFailure.failed(engineError) : TurnFailure.stale(engineError)
    }
}

/// Set-once flag shared with watchdog tasks.
final class EdgeLatch: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    var isSet: Bool { lock.withLock { flag } }
    func set() { lock.withLock { flag = true } }
}

/// First-write-wins value shared with watchdog tasks.
final class EdgeBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T?
    var value: T? { lock.withLock { stored } }
    func set(_ v: T) { lock.withLock { if stored == nil { stored = v } } }
}
