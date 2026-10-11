import CryptoKit
import Foundation

// Where the Edge "Read Aloud" service lives and how requests get authorized.
// Microsoft is rolling out a v2 scheme (new host + new Sec-MS-GEC format,
// rany2/edge-tts#490) whose token algorithm isn't public yet. Everything that
// changes between schemes sits behind `EdgeEndpoint`, so v2 is a new conformer.

protocol EdgeEndpoint: Sendable {
    /// Short label for logs/errors ("v1").
    var name: String { get }
    /// WebSocket handshake request for one synthesis connection.
    func synthesisRequest(connectionID: String, now: Date) -> URLRequest
    /// Plain HTTPS GET returning the voice list JSON.
    func voiceListRequest(now: Date) -> URLRequest
    /// The Sec-MS-GEC token this endpoint sends at `now` (diagnostics/tests).
    func token(now: Date) -> String
}

/// v1 token scheme (SHA-256 of rounded Windows ticks + client token, version
/// "1-<chromium>"), on either host:
/// - `.bing`: the classic `speech.platform.bing.com` endpoint (edge-tts 7.x).
///   Since 2026-10-10 some European front-door nodes reject it with 403.
/// - `.msEdgeServices`: the host Edge 155 uses (`api.msedgeservices.com`). It
///   still accepts v1 tokens (verified 2026-10-11 from Zurich: 12/12 handshakes
///   101, a garbage token 403) — Edge itself sends a v2 token we can't make yet.
struct EdgeEndpointV1: EdgeEndpoint {
    /// Default order: new host first, classic host as fallback.
    static let all: [EdgeEndpoint] = [EdgeEndpointV1(host: .msEdgeServices), EdgeEndpointV1(host: .bing)]

    enum Host: String, Sendable { case msEdgeServices, bing }

    static let trustedClientToken = "6A5AA1D4EAFF4E9FB37E23D68491D6F4"
    static let chromiumFullVersion = "143.0.3650.75"
    static let origin = "chrome-extension://jdiccldimpdaibmpdkjnbmckianbfold"

    var host: Host = .msEdgeServices

    var name: String { "v1@\(host.rawValue)" }

    private var synthesisBase: String {
        switch host {
        case .bing: return "wss://speech.platform.bing.com/consumer/speech/synthesize/readaloud/edge/v1"
        case .msEdgeServices: return "wss://api.msedgeservices.com/tts/cognitiveservices/websocket/v1"
        }
    }
    private var voiceListBase: String {
        switch host {
        case .bing: return "https://speech.platform.bing.com/consumer/speech/synthesize/readaloud/voices/list"
        case .msEdgeServices: return "https://api.msedgeservices.com/tts/cognitiveservices/voices/list"
        }
    }
    private var keyParam: (synthesis: String, voices: String) {
        switch host {
        case .bing: return ("TrustedClientToken", "trustedclienttoken")
        case .msEdgeServices: return ("Ocp-Apim-Subscription-Key", "Ocp-Apim-Subscription-Key")
        }
    }

    private var chromiumMajor: String {
        String(Self.chromiumFullVersion.split(separator: ".").first ?? "143")
    }
    private var secMSGECVersion: String { "1-\(Self.chromiumFullVersion)" }
    private var userAgent: String {
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) "
            + "Chrome/\(chromiumMajor).0.0.0 Safari/537.36 Edg/\(chromiumMajor).0.0.0"
    }

    func token(now: Date) -> String {
        EdgeToken.secMSGEC(unixTime: now.timeIntervalSince1970, clientToken: Self.trustedClientToken)
    }

    func synthesisRequest(connectionID: String, now: Date) -> URLRequest {
        var c = URLComponents(string: synthesisBase)!
        c.queryItems = [
            URLQueryItem(name: keyParam.synthesis, value: Self.trustedClientToken),
            URLQueryItem(name: "Sec-MS-GEC", value: token(now: now)),
            URLQueryItem(name: "Sec-MS-GEC-Version", value: secMSGECVersion),
            URLQueryItem(name: "ConnectionId", value: connectionID),
        ]
        var r = URLRequest(url: c.url!)
        r.setValue("no-cache", forHTTPHeaderField: "Pragma")
        r.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        r.setValue(Self.origin, forHTTPHeaderField: "Origin")
        r.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        r.setValue("gzip, deflate, br, zstd", forHTTPHeaderField: "Accept-Encoding")
        r.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        r.setValue("muid=\(EdgeToken.muid());", forHTTPHeaderField: "Cookie")
        return r
    }

    func voiceListRequest(now: Date) -> URLRequest {
        var c = URLComponents(string: voiceListBase)!
        c.queryItems = [
            URLQueryItem(name: keyParam.voices, value: Self.trustedClientToken),
            URLQueryItem(name: "Sec-MS-GEC", value: token(now: now)),
            URLQueryItem(name: "Sec-MS-GEC-Version", value: secMSGECVersion),
        ]
        var r = URLRequest(url: c.url!)
        r.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        r.setValue("*/*", forHTTPHeaderField: "Accept")
        r.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        r.setValue("?0", forHTTPHeaderField: "Sec-CH-UA-Mobile")
        r.setValue("none", forHTTPHeaderField: "Sec-Fetch-Site")
        r.setValue("cors", forHTTPHeaderField: "Sec-Fetch-Mode")
        r.setValue("empty", forHTTPHeaderField: "Sec-Fetch-Dest")
        r.setValue("muid=\(EdgeToken.muid());", forHTTPHeaderField: "Cookie")
        return r
    }
}

enum EdgeToken {
    /// Seconds between 1601-01-01 (Windows file time epoch) and 1970-01-01.
    static let windowsEpochOffset: Int64 = 11_644_473_600

    /// v1 Sec-MS-GEC: Windows file time rounded down to 5 minutes, in 100-ns
    /// ticks, concatenated with the client token, SHA-256, uppercase hex.
    static func secMSGEC(unixTime: TimeInterval, clientToken: String) -> String {
        var seconds = Int64(unixTime.rounded(.down)) + windowsEpochOffset
        seconds -= seconds % 300
        let ticks = seconds * 10_000_000
        let digest = SHA256.hash(data: Data("\(ticks)\(clientToken)".utf8))
        return digest.map { String(format: "%02X", $0) }.joined()
    }

    /// Random 32-hex-char MUID cookie value, like the browser sends.
    static func muid() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "")
    }
}

/// Process-wide correction for a wrong local clock, learned from the server's
/// `Date` header when a handshake is rejected.
final class EdgeClock: @unchecked Sendable {
    static let shared = EdgeClock()

    private let lock = NSLock()
    private var skew: TimeInterval = 0

    func now() -> Date {
        lock.lock(); defer { lock.unlock() }
        return Date().addingTimeInterval(skew)
    }

    /// Re-anchor to the server's clock. Returns the corrected "now".
    @discardableResult
    func adjust(toServerDate header: String) -> Date? {
        guard let server = Self.parseHTTPDate(header) else { return nil }
        lock.lock(); defer { lock.unlock() }
        skew = server.timeIntervalSince(Date())
        return server
    }

    private static let httpDate: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "GMT")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return f
    }()

    static func parseHTTPDate(_ s: String) -> Date? { httpDate.date(from: s) }
}

enum EdgeHTTP {
    /// No cookies, no cache, fail instead of waiting for connectivity.
    static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 60
        config.httpCookieStorage = nil
        config.urlCache = nil
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }

    /// For pooled WebSockets: URLSession's own timeouts must not cut a socket
    /// that sits idle between sections (server keeps it 300 s); the engine's
    /// watchdogs own connect/turn deadlines instead.
    static func makeSocketSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 330
        config.timeoutIntervalForResource = 24 * 3600
        config.httpCookieStorage = nil
        config.urlCache = nil
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }
}
