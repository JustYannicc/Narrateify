import Foundation
import os

private let log = Logger(subsystem: "com.narrateify.Narrateify", category: "edge")

/// Microsoft Edge "Read Aloud" voices over the browser's WebSocket API.
/// MP3 out; real word timings from WordBoundary metadata. Every failure to
/// reach or be accepted by the service maps to `.serviceUnavailable` quickly
/// (4 s connect deadline) so the router can fall back and bench the engine.
///
/// Latency: a handshake costs ~120 ms, so connections are reused. `prewarm()`
/// opens one ahead of time, and after each section the socket goes back into a
/// one-slot idle pool for `idleLifetime`, so the sections of a narration share
/// one socket. A reused socket that doesn't answer within `staleAfter` is
/// replaced by a fresh one transparently.
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
    /// How long an unused socket is kept (the server allows 300 s).
    var idleLifetime: TimeInterval = 60
    /// A reused socket must send its first frame (normally ~50 ms) within this.
    var staleAfter: TimeInterval = 1.5

    private let lock = NSLock()
    private var preferred = 0
    private var idle: EdgeConnection?
    private var warming: Warmup?
    private var _lastTiming: Timing?

    private final class Warmup {
        let task: Task<Result<EdgeConnection, Error>, Never>
        init(_ task: Task<Result<EdgeConnection, Error>, Never>) { self.task = task }
    }

    /// Where the time of the last `synthesize` went (also logged, category "edge").
    struct Timing: CustomStringConvertible {
        enum Source: String { case fresh, warming, idle, staleRetry }
        var source: Source
        /// Waiting for a socket: full connect when fresh, the tail of a
        /// prewarm in flight, ~0 when idle.
        var connect: TimeInterval
        var firstFrame: TimeInterval?
        var firstAudio: TimeInterval?
        var turn: TimeInterval
        var total: TimeInterval
        var endpoint: String

        var description: String {
            func ms(_ t: TimeInterval?) -> String { t.map { "\(Int(($0 * 1000).rounded())) ms" } ?? "-" }
            return "\(source.rawValue) via \(endpoint): socket \(ms(connect)), first frame \(ms(firstFrame)), "
                + "first audio \(ms(firstAudio)), turn \(ms(turn)), total \(ms(total))"
        }
    }

    var lastTiming: Timing? { lock.withLock { _lastTiming } }

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

    deinit { idle?.close() }

    /// Budget for one turn once connected: generation is much faster than
    /// real time, so this only trips when the service stalls.
    static func turnTimeout(forTextLength n: Int) -> TimeInterval {
        6 + Double(n) * 0.04
    }

    func supports(_ language: ReadingLanguage) -> Bool {
        let code = language.code.lowercased()
        return catalog.knownLocales().contains { $0 == code || $0.hasPrefix(language.base + "-") }
    }

    func voices(for language: ReadingLanguage) async -> [VoiceOption] {
        await catalog.voices(for: language).map(\.option)
    }

    // MARK: Warm-up

    /// Open a socket now so the next `synthesize` skips the handshake. Cheap to
    /// call repeatedly; does nothing if a usable socket is idle or one is
    /// already being opened. Never throws — a failed warm-up is reported by
    /// the `synthesize` that picks it up.
    func prewarm() {
        let warmup: Warmup? = lock.withLock {
            if let c = idle {
                if isUsable(c) { return nil }
                idle = nil
                c.close()
            }
            if warming != nil { return nil }
            let w = Warmup(Task {
                do { return .success(try await self.connect()) } catch { return .failure(error) }
            })
            warming = w
            return w
        }
        guard let warmup else { return }
        Task {
            let result = await warmup.task.value
            guard case .success(let connection) = result else {
                lock.withLock { if warming === warmup { warming = nil } }
                return
            }
            // Hand-over from `warming` to `idle` in one step, unless a
            // synthesize already adopted the warm-up.
            let outcome: Park = lock.withLock {
                guard warming === warmup else { return .adopted }
                warming = nil
                return park(connection)
            }
            finish(connection, outcome)
        }
    }

    // MARK: Synthesis

    func synthesize(_ text: String, language: ReadingLanguage, voiceID: String) async throws -> SynthesizedSpeech {
        guard text.contains(where: { $0.isLetter || $0.isNumber }) else {
            throw SpeechEngineError.synthesisFailed("Nothing speakable in section")
        }
        let ssml = EdgeProtocol.ssml(text: text, voiceID: voiceID, languageCode: language.code)
        let timeout = Self.turnTimeout(forTextLength: text.utf16.count)
        let start = Date()

        var (connection, source) = try await checkOut()
        let connected = Date()
        var turn: EdgeConnection.TurnResult
        do {
            do {
                turn = try await connection.speak(ssml: ssml, timeout: timeout,
                                                  firstFrameTimeout: source == .fresh ? nil : staleAfter)
            } catch EdgeConnection.TurnFailure.stale(let error) where source != .fresh {
                // The kept socket died quietly (sleep, network change, server
                // close). Nothing was spoken yet, so start over on a fresh one.
                log.notice("reused socket stale (\(error.localizedDescription, privacy: .public)); reconnecting")
                connection.close()
                connection = try await connect()
                source = .staleRetry
                turn = try await connection.speak(ssml: ssml, timeout: timeout, firstFrameTimeout: nil)
            }
        } catch let failure as EdgeConnection.TurnFailure {
            connection.close()
            switch failure {
            case .stale(let e), .failed(let e): throw e
            }
        } catch {
            connection.close()
            throw error
        }
        checkIn(connection)

        let timing = Timing(source: source, connect: connected.timeIntervalSince(start),
                            firstFrame: turn.firstFrame, firstAudio: turn.firstAudio,
                            turn: turn.total, total: Date().timeIntervalSince(start),
                            endpoint: connection.endpointName)
        lock.withLock { _lastTiming = timing }
        log.notice("synthesize \(text.utf16.count) chars [\(voiceID, privacy: .public)]: \(timing.description, privacy: .public)")
        return SynthesizedSpeech(audio: turn.audio, fileExtension: "mp3",
                                 words: EdgeWordAligner.align(turn.boundaries, in: text))
    }

    // MARK: Pool

    private func isUsable(_ c: EdgeConnection) -> Bool {
        c.isAlive && Date().timeIntervalSince(c.lastUsed) < idleLifetime
    }

    /// An idle socket, else the warm-up in flight, else a fresh connection.
    private func checkOut() async throws -> (EdgeConnection, Timing.Source) {
        enum Pick { case idle(EdgeConnection), warming(Warmup), none }
        let pick: Pick = lock.withLock {
            if let c = idle {
                idle = nil
                if isUsable(c) { return .idle(c) }
                c.close()
            }
            if let w = warming {
                warming = nil
                return .warming(w)
            }
            return .none
        }
        switch pick {
        case .idle(let c):
            return (c, .idle)
        case .warming(let w):
            // A warm-up that failed already did the endpoint rotation; retrying
            // would only double the failure latency. We own it now, so a
            // cancelled synthesize cancels it.
            let result = await withTaskCancellationHandler { await w.task.value } onCancel: { w.task.cancel() }
            switch result {
            case .success(let c): return (c, .warming)
            case .failure(let e): throw e
            }
        case .none:
            return (try await connect(), .fresh)
        }
    }

    private enum Park { case parked, rejected, adopted }

    /// Call with `lock` held.
    private func park(_ connection: EdgeConnection) -> Park {
        if let current = idle {
            guard !isUsable(current) else { return .rejected }
            current.close()
        }
        guard connection.isAlive else { return .rejected }
        idle = connection
        return .parked
    }

    private func checkIn(_ connection: EdgeConnection) {
        finish(connection, lock.withLock { park(connection) })
    }

    /// Close a rejected connection, or arm the idle expiry for a parked one.
    private func finish(_ connection: EdgeConnection, _ outcome: Park) {
        switch outcome {
        case .adopted: return
        case .rejected: return connection.close()
        case .parked: break
        }
        let lastUsed = connection.lastUsed
        let lifetime = idleLifetime
        Task { [weak self, weak connection] in
            try? await Task.sleep(nanoseconds: UInt64(lifetime * 1e9))
            guard let self, let connection else { return }
            let expired: Bool = self.lock.withLock {
                guard self.idle === connection, connection.lastUsed == lastUsed else { return false }
                self.idle = nil
                return true
            }
            if expired { connection.close() }
        }
    }

    /// Handshake with endpoint rotation: handshake rejections and fast
    /// failures move on to the next endpoint; never more than one connect
    /// budget in total.
    private func connect() async throws -> EdgeConnection {
        let first = lock.withLock { preferred }
        let start = Date()
        var failures: [String] = []
        for i in 0..<handshakeAttempts {
            let index = (first + i) % endpoints.count
            let name = endpoints[index].name
            do {
                let connection = try await EdgeConnection.open(endpoint: endpoints[index], index: index,
                                                               timeout: connectTimeout)
                lock.withLock { preferred = index }
                return connection
            } catch let rejected as EdgeConnection.HandshakeRejected {
                failures.append("\(name): HTTP \(rejected.status)")
                // A wrong local clock produces a stale token: re-anchor to the
                // server's clock before the next try (no-op if we're in sync).
                if let date = rejected.serverDate { EdgeClock.shared.adjust(toServerDate: date) }
            } catch let unreachable as EdgeConnection.Unreachable {
                failures.append("\(name): \(unreachable.message)")
            }
            try Task.checkCancellation()
            if Date().timeIntervalSince(start) > connectTimeout { break }
        }
        throw SpeechEngineError.serviceUnavailable("Edge TTS unavailable (\(failures.joined(separator: ", ")))")
    }
}
