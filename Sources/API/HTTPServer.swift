import Foundation
import Network
import OSLog

private let log = Logger(category: "api")

/// A tiny HTTP/1.1 server on 127.0.0.1: one request per connection, then it
/// closes. Enough for curl, the CLI and the MCP bridge; nothing else needed.
///
/// Browsers are shut out: any request carrying an `Origin` header, or a `Host`
/// that isn't localhost (DNS rebinding), gets a 403. Local processes run as
/// the user anyway, so there's no token.
final class HTTPServer: @unchecked Sendable {
    struct Request {
        let method: String
        let path: String
        let query: [String: String]
        let body: Data
    }

    /// Writes the reply. Call `send` once, or `begin` + `write`… + `end` to
    /// stream (`abort` if the stream fails, so the client sees an error
    /// instead of a clean end).
    final class Response: @unchecked Sendable {
        private let connection: NWConnection
        init(_ connection: NWConnection) { self.connection = connection }

        func send(status: Int, contentType: String, body: Data, headers: [String: String] = [:]) {
            var all = headers
            all["Content-Length"] = String(body.count)
            connection.send(content: head(status, contentType, all) + body, completion: .contentProcessed { [connection] _ in
                connection.cancel()
            })
        }

        func json(_ value: some Encodable, status: Int = 200) {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            send(status: status, contentType: "application/json", body: (try? encoder.encode(value)) ?? Data("{}".utf8))
        }

        func error(_ status: Int, _ message: String) {
            json(["error": message], status: status)
        }

        /// No Content-Length: the body ends when the connection closes.
        func begin(contentType: String, headers: [String: String] = [:]) async throws {
            try await write(head(200, contentType, headers))
        }

        /// Returns once the bytes are handed to the socket, so a slow reader
        /// slows the render down instead of piling audio up in memory.
        func write(_ data: Data) async throws {
            try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
                connection.send(content: data, completion: .contentProcessed { error in
                    if let error { done.resume(throwing: error) } else { done.resume() }
                })
            }
        }

        func end() {
            connection.send(content: nil, contentContext: .finalMessage, isComplete: true,
                            completion: .contentProcessed { [connection] _ in connection.cancel() })
        }

        func abort() { connection.forceCancel() }

        private func head(_ status: Int, _ contentType: String, _ headers: [String: String]) -> Data {
            let reason = [200: "OK", 400: "Bad Request", 403: "Forbidden", 404: "Not Found",
                          405: "Method Not Allowed", 409: "Conflict", 411: "Length Required", 413: "Payload Too Large",
                          500: "Internal Server Error",
                          503: "Service Unavailable"][status] ?? "Status"
            var lines = ["HTTP/1.1 \(status) \(reason)", "Content-Type: \(contentType)", "Connection: close"]
            lines += headers.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }
            return Data((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8)
        }
    }

    /// Runs in its own task, cancelled when the client goes away.
    typealias Handler = @Sendable (Request, Response) async -> Void

    private let handler: Handler
    private let queue = DispatchQueue(label: "narrateify.api")
    private var listener: NWListener?
    private static let maxBody = 4 << 20

    private(set) var port: UInt16 = 0

    init(handler: @escaping Handler) {
        self.handler = handler
    }

    /// Binds 127.0.0.1:`preferred`, or any free port if that's taken.
    func start(preferred: UInt16, ready: @escaping @Sendable (UInt16?) -> Void) {
        start(port: NWEndpoint.Port(rawValue: preferred) ?? .any, fallback: true, ready: ready)
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func start(port: NWEndpoint.Port, fallback: Bool, ready: @escaping @Sendable (UInt16?) -> Void) {
        let params = NWParameters.tcp
        // No allowLocalEndpointReuse: with SO_REUSEPORT a second copy of the
        // app would share 47801 and split requests instead of falling back.
        params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: port)
        guard let listener = try? NWListener(using: params) else { return ready(nil) }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.port = listener.port?.rawValue ?? 0
                log.notice("listening on 127.0.0.1:\(self.port)")
                ready(self.port)
            case .failed(let error):
                log.error("listen failed: \(error.localizedDescription, privacy: .public)")
                listener.cancel()
                if fallback { self.start(port: .any, fallback: false, ready: ready) } else { ready(nil) }
            default:
                break
            }
        }
        self.listener = listener
        listener.start(queue: queue)
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(connection, buffer: Data(), sentContinue: false)
    }

    private func receive(_ connection: NWConnection, buffer: Data, sentContinue: Bool) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 << 10) { [weak self] data, _, done, error in
            guard let self else { return connection.cancel() }
            var buffer = buffer
            if let data { buffer.append(data) }
            let response = Response(connection)
            guard buffer.count <= Self.maxBody + (16 << 10) else { return response.error(413, "Request too large") }
            switch Self.parse(buffer) {
            case .incomplete(let expectsContinue) where !done && error == nil:
                // curl sends `Expect: 100-continue` for bigger bodies and waits
                // a second for this before sending them.
                if expectsContinue, !sentContinue {
                    connection.send(content: Data("HTTP/1.1 100 Continue\r\n\r\n".utf8), completion: .idempotent)
                }
                self.receive(connection, buffer: buffer, sentContinue: sentContinue || expectsContinue)
            case .incomplete, .invalid:
                response.error(400, "Malformed request")
            case .rejected(let status, let message):
                response.error(status, message)
            case .complete(let request):
                let task = Task { await self.handler(request, response) }
                connection.stateUpdateHandler = { state in
                    switch state {
                    case .failed, .cancelled: task.cancel()
                    default: break
                    }
                }
            }
        }
    }

    private enum Parsed {
        case incomplete(expectsContinue: Bool)
        case invalid
        case rejected(Int, String)
        case complete(Request)
    }

    private static func parse(_ data: Data) -> Parsed {
        guard let end = data.range(of: Data("\r\n\r\n".utf8)) else { return .incomplete(expectsContinue: false) }
        guard let head = String(data: data[..<end.lowerBound], encoding: .utf8) else { return .invalid }
        var lines = head.components(separatedBy: "\r\n")
        let start = lines.removeFirst().split(separator: " ")
        guard start.count >= 2 else { return .invalid }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let forbidden = Parsed.rejected(403, "Only local, non-browser clients may use this API")
        if headers["origin"] != nil { return forbidden }
        if let host = headers["host"]?.split(separator: ":").first.map(String.init),
           !["127.0.0.1", "localhost"].contains(host.lowercased()) { return forbidden }
        if headers["transfer-encoding"] != nil { return .rejected(411, "Send a Content-Length (chunked bodies aren't supported)") }

        let length = Int(headers["content-length"] ?? "0") ?? 0
        guard length >= 0 else { return .invalid }
        guard length <= maxBody else { return .rejected(413, "Request too large") }
        let bodyStart = end.upperBound
        guard data.count - bodyStart >= length else {
            return .incomplete(expectsContinue: headers["expect"]?.lowercased() == "100-continue")
        }

        let target = String(start[1])
        let components = URLComponents(string: target)
        var query: [String: String] = [:]
        components?.queryItems?.forEach { query[$0.name] = $0.value ?? "" }
        return .complete(Request(method: String(start[0]).uppercased(), path: components?.path ?? target,
                                 query: query, body: data.subdata(in: bodyStart..<(bodyStart + length))))
    }
}
