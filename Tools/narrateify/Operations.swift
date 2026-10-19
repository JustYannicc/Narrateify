import Foundation

/// What both the CLI and the MCP server do, as plain JSON-in/JSON-out calls.
enum Operations {
    /// Voice options shared by every call: text plus engine/voice/language/…
    /// Keys match the API's JSON body (`voice`, `engine`, `language`, `strict`,
    /// `clean`, `speed`, `format`, `words`).
    typealias Options = [String: Any]

    static func speak(_ text: String, _ options: Options, wait: Bool) async throws {
        var body = options
        body["text"] = text
        _ = try await Client.json("POST", "v1/speak", body: body)
        if wait { try await Client.waitUntilQuiet() }
    }

    /// Writes one file and returns the API's description of it (path,
    /// duration, sections, optional words).
    static func synthesize(_ text: String, to path: String, _ options: Options) async throws -> [String: Any] {
        var body = options
        body["text"] = text
        body["out"] = absolute(path)
        return try await Client.json("POST", "v1/synthesize", body: body) as? [String: Any] ?? [:]
    }

    /// Clips → `<dir>/<id>.<format>`, one after another (engines are quickest
    /// that way and the order stays predictable). Per-clip keys override
    /// `defaults`. Returns one entry per clip with its id added.
    static func batch(_ clips: [[String: Any]], outDir: String, _ defaults: Options) async throws -> [[String: Any]] {
        let dir = absolute(outDir)
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let format = (defaults["format"] as? String) ?? "wav"
        var results: [[String: Any]] = []
        for (index, clip) in clips.enumerated() {
            guard let text = clip["text"] as? String else {
                throw Client.Failure(message: "Clip \(index) has no \"text\"")
            }
            let id = (clip["id"] as? String) ?? (clip["id"] as? Int).map(String.init) ?? String(format: "clip-%03d", index + 1)
            var options = defaults
            for (key, value) in clip where key != "id" && key != "text" { options[key] = value }
            let ext = (options["format"] as? String) ?? format
            var result = try await synthesize(text, to: (dir as NSString).appendingPathComponent("\(id).\(ext)"), options)
            result["id"] = id
            results.append(result)
        }
        return results
    }

    static func absolute(_ path: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") { return expanded }
        return (FileManager.default.currentDirectoryPath as NSString).appendingPathComponent(expanded)
    }
}
