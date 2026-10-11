import Foundation

// Wire format of the Edge Read Aloud WebSocket. Pure functions, no I/O, so
// everything here is unit-testable with fixtures.
//
// Client → server: two text frames, `speech.config` then `ssml`.
// Server → client: text frames `turn.start`, `response`, `audio.metadata`
// (word boundaries), `turn.end`; binary frames carrying MP3 bytes, prefixed by
// a 2-byte big-endian header length and that many bytes of `Key:Value\r\n`
// headers.

enum EdgeProtocol {
    static let outputFormat = "audio-24khz-48kbitrate-mono-mp3"
    static let ticksPerSecond = 10_000_000.0

    // MARK: Outgoing

    static func speechConfigMessage(timestamp: String) -> String {
        "X-Timestamp:\(timestamp)\r\n"
            + "Content-Type:application/json; charset=utf-8\r\n"
            + "Path:speech.config\r\n\r\n"
            + #"{"context":{"synthesis":{"audio":{"metadataoptions":{"#
            + #""sentenceBoundaryEnabled":"false","wordBoundaryEnabled":"true"},"#
            + #""outputFormat":"\#(outputFormat)"}}}}"#
            + "\r\n"
    }

    static func ssmlMessage(requestID: String, timestamp: String, ssml: String) -> String {
        "X-RequestId:\(requestID)\r\n"
            + "Content-Type:application/ssml+xml\r\n"
            // The trailing "Z" after a JS-style date is what Edge itself sends.
            + "X-Timestamp:\(timestamp)Z\r\n"
            + "Path:ssml\r\n\r\n"
            + ssml
    }

    static func ssml(text: String, voiceID: String, languageCode: String) -> String {
        "<speak version='1.0' xmlns='http://www.w3.org/2001/10/synthesis' xml:lang='\(escapeXML(languageCode))'>"
            + "<voice name='\(escapeXML(longVoiceName(voiceID)))'>"
            + "<prosody pitch='+0Hz' rate='+0%' volume='+0%'>"
            + escapeXML(sanitize(text))
            + "</prosody></voice></speak>"
    }

    /// JavaScript `Date.toString()`-style timestamp in UTC.
    static func timestamp(_ date: Date = Date()) -> String { jsDate.string(from: date) }

    private static let jsDate: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "EEE MMM dd yyyy HH:mm:ss 'GMT+0000 (Coordinated Universal Time)'"
        return f
    }()

    static func newID() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }

    /// "en-US-AriaNeural" → "Microsoft Server Speech Text to Speech Voice (en-US, AriaNeural)".
    /// Locales with a third part ("zh-CN-liaoning-XiaobeiNeural") keep it in the
    /// locale. Anything else passes through unchanged.
    static func longVoiceName(_ shortName: String) -> String {
        let parts = shortName.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 3, parts.last!.hasSuffix("Neural"),
              parts[0].count >= 2, parts[0] == parts[0].lowercased(),
              parts[1].count >= 2, parts[1] == parts[1].uppercased()
        else { return shortName }
        let locale = parts.dropLast().joined(separator: "-")
        return "Microsoft Server Speech Text to Speech Voice (\(locale), \(parts.last!))"
    }

    // MARK: Text

    /// Escape for XML text and single-quoted attributes.
    static func escapeXML(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.utf16.count)
        for ch in s {
            switch ch {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "'": out += "&apos;"
            case "\"": out += "&quot;"
            default: out.append(ch)
            }
        }
        return out
    }

    static func unescapeXML(_ s: String) -> String {
        guard s.contains("&") else { return s }
        return s.replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    /// The service rejects some control characters (vertical tab is common in
    /// OCR'd PDFs). Replace them with spaces.
    static func sanitize(_ s: String) -> String {
        String(String.UnicodeScalarView(s.unicodeScalars.map { u in
            let v = u.value
            return (v <= 8 || v == 11 || v == 12 || (14...31).contains(v)) ? " " : u
        }))
    }

    // MARK: Incoming

    struct Frame: Equatable {
        var headers: [String: String]
        var body: Data
        var path: String? { headers["Path"] }
    }

    enum ParseError: Error, Equatable {
        case malformed(String)
    }

    /// Text frame: headers, blank line, body.
    static func parseTextFrame(_ text: String) throws -> Frame {
        let data = Data(text.utf8)
        guard let sep = data.range(of: Data("\r\n\r\n".utf8)) else {
            throw ParseError.malformed("text frame without header terminator")
        }
        let headers = parseHeaders(data[data.startIndex..<sep.lowerBound])
        return Frame(headers: headers, body: Data(data[sep.upperBound...]))
    }

    /// Binary frame: UInt16 BE header length, headers, then payload.
    static func parseBinaryFrame(_ data: Data) throws -> Frame {
        guard data.count >= 2 else { throw ParseError.malformed("binary frame shorter than 2 bytes") }
        let b = [UInt8](data.prefix(2))
        let headerLength = Int(b[0]) << 8 | Int(b[1])
        guard 2 + headerLength <= data.count else {
            throw ParseError.malformed("binary header length \(headerLength) exceeds frame size \(data.count)")
        }
        let start = data.startIndex
        let headers = parseHeaders(data[(start + 2)..<(start + 2 + headerLength)])
        return Frame(headers: headers, body: Data(data[(start + 2 + headerLength)...]))
    }

    private static func parseHeaders(_ bytes: Data) -> [String: String] {
        var out: [String: String] = [:]
        let text = String(decoding: bytes, as: UTF8.self)
        for line in text.components(separatedBy: "\r\n") where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            out[key] = value
        }
        return out
    }

    struct Boundary: Equatable {
        enum Kind: Equatable { case word, punctuation, sentence, other(String) }
        let kind: Kind
        let text: String
        /// 100-ns ticks from the start of the audio.
        let offset: Int64
        let duration: Int64

        var start: TimeInterval { Double(offset) / EdgeProtocol.ticksPerSecond }
        var seconds: TimeInterval { Double(duration) / EdgeProtocol.ticksPerSecond }
    }

    /// Body of an `audio.metadata` frame → its boundaries (other entries, e.g.
    /// `SessionEnd`, are ignored).
    static func parseMetadata(_ body: Data) throws -> [Boundary] {
        guard let root = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let items = root["Metadata"] as? [[String: Any]]
        else { throw ParseError.malformed("audio.metadata body is not {Metadata:[…]}") }
        return items.compactMap { item in
            guard let type = item["Type"] as? String,
                  type.hasSuffix("Boundary"),
                  let d = item["Data"] as? [String: Any],
                  let offset = (d["Offset"] as? NSNumber)?.int64Value,
                  let duration = (d["Duration"] as? NSNumber)?.int64Value,
                  let t = d["text"] as? [String: Any],
                  let raw = t["Text"] as? String
            else { return nil }
            let boundaryType = (t["BoundaryType"] as? String) ?? type
            let kind: Boundary.Kind
            switch boundaryType {
            case "WordBoundary": kind = .word
            case "PunctuationBoundary": kind = .punctuation
            case "SentenceBoundary": kind = .sentence
            default: kind = .other(boundaryType)
            }
            return Boundary(kind: kind, text: unescapeXML(raw), offset: offset, duration: duration)
        }
    }
}
