import Foundation

/// Talks to the running app's local API, launching the app first if needed.
struct Client {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// `NARRATEIFY_URL`, else the port the app wrote to api.json, else 47801.
    /// Re-read after launching the app (it may have fallen back to another port).
    static var baseURL: URL {
        if let env = ProcessInfo.processInfo.environment["NARRATEIFY_URL"], let url = URL(string: env) { return url }
        if let data = try? Data(contentsOf: APIEndpoint.discoveryFile),
           let info = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let port = info["port"] as? Int {
            return URL(string: "http://127.0.0.1:\(port)")!
        }
        return URL(string: "http://127.0.0.1:\(APIEndpoint.preferredPort)")!
    }

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        // A long render sends nothing until it's done.
        config.timeoutIntervalForRequest = 4 * 3600
        config.timeoutIntervalForResource = 4 * 3600
        config.connectionProxyDictionary = [:]   // never route localhost through a proxy
        return URLSession(configuration: config)
    }()

    /// Checked once per process, not before every call of a big batch.
    nonisolated(unsafe) private static var knownUp = false

    /// Starts Narrateify in the background (no window) if the API isn't up.
    static func ensureRunning() async throws {
        if knownUp { return }
        if await isUp() { knownUp = true; return }
        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        open.arguments = ["-g", "-b", APIEndpoint.appBundleID]
        open.standardOutput = FileHandle.nullDevice   // stdout may be the MCP stream
        open.standardError = FileHandle.nullDevice
        try open.run()
        open.waitUntilExit()
        guard open.terminationStatus == 0 else {
            throw Failure(message: "Narrateify isn't installed (no app with bundle id \(APIEndpoint.appBundleID)).")
        }
        for _ in 0..<60 {
            try await Task.sleep(for: .milliseconds(250))
            if await isUp() { knownUp = true; return }
        }
        throw Failure(message: "Narrateify started but its local API didn't come up. Is it turned off in Settings?")
    }

    private static func isUp() async -> Bool {
        var request = URLRequest(url: baseURL.appendingPathComponent("v1/status"))
        request.timeoutInterval = 1
        return (try? await session.data(for: request)).map { ($0.1 as? HTTPURLResponse)?.statusCode == 200 } ?? false
    }

    /// JSON in, raw reply out. Non-2xx replies throw with the API's message.
    static func call(_ method: String, _ path: String, query: [String: String] = [:],
                     body: [String: Any]? = nil) async throws -> (Data, HTTPURLResponse) {
        try await ensureRunning()
        var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) } }
        var request = URLRequest(url: components.url!)
        request.httpMethod = method
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await session.data(for: request)
        let http = response as! HTTPURLResponse
        guard (200..<300).contains(http.statusCode) else {
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
            throw Failure(message: message ?? "HTTP \(http.statusCode)")
        }
        return (data, http)
    }

    static func json(_ method: String, _ path: String, query: [String: String] = [:],
                     body: [String: Any]? = nil) async throws -> Any {
        try JSONSerialization.jsonObject(with: try await call(method, path, query: query, body: body).0)
    }

    /// Streams the reply body to `handle` as it arrives (for `synth -o -`).
    static func stream(_ path: String, body: [String: Any], to handle: FileHandle) async throws {
        try await ensureRunning()
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (bytes, response) = try await session.bytes(for: request)
        let http = response as! HTTPURLResponse
        guard http.statusCode == 200 else {
            var data = Data()
            for try await byte in bytes { data.append(byte) }
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
            throw Failure(message: message ?? "HTTP \(http.statusCode)")
        }
        var chunk = Data()
        chunk.reserveCapacity(16 << 10)
        for try await byte in bytes {
            chunk.append(byte)
            if chunk.count >= 16 << 10 { handle.write(chunk); chunk.removeAll(keepingCapacity: true) }
        }
        handle.write(chunk)
    }

    /// Blocks until the app stops reading (for `say --wait`).
    static func waitUntilQuiet(timeout: TimeInterval = 3600) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        try await Task.sleep(for: .milliseconds(400))   // let the read start
        while Date() < deadline {
            let status = try await json("GET", "v1/status") as? [String: Any]
            if status?["reading"] as? Bool != true { return }
            try await Task.sleep(for: .milliseconds(250))
        }
    }
}
