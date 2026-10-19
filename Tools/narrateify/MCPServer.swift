import Foundation

/// `narrateify mcp`: a stdio MCP server (newline-delimited JSON-RPC) over the
/// local API. The app is launched lazily, on the first tool call.
enum MCPServer {
    private static let voiceProperties: [String: Any] = [
        "voice": ["type": "string", "description": "Voice id or name from list_voices (e.g. \"de-DE-KatjaNeural\", \"F1\", \"Anna\"). Pins the language to the voice's."],
        "engine": ["type": "string", "description": "edge, supertonic, apple, elevenLabs or openAI. Tried first; the language's fallback chain follows unless strict."],
        "language": ["type": "string", "description": "BCP-47 or base code (\"en\", \"de-DE\"). Skips language detection."],
        "strict": ["type": "boolean", "description": "Only the given engine/voice, no fallback."],
    ]

    private static func schema(_ properties: [String: Any], required: [String] = []) -> [String: Any] {
        ["type": "object", "properties": properties, "required": required]
    }

    private static let tools: [[String: Any]] = [
        ["name": "speak",
         "description": "Read text aloud on this Mac through Narrateify's reader (same engines, voices and fallbacks as its hotkey). Returns once reading starts, or when it ends if wait is true.",
         "inputSchema": schema(voiceProperties.merging([
            "text": ["type": "string"],
            "wait": ["type": "boolean", "description": "Return only after reading finishes."],
         ]) { $1 }, required: ["text"])],
        ["name": "synthesize",
         "description": "Render text to an audio file (wav or m4a, 48 kHz mono) without playing it. Returns the path, the file's exact duration in seconds, which engine/voice read each section, and optionally per-word timings.",
         "inputSchema": schema(voiceProperties.merging([
            "text": ["type": "string"],
            "out": ["type": "string", "description": "Absolute output path ending in .wav or .m4a."],
            "speed": ["type": "number", "description": "0.5–3, pitch preserved. Default 1."],
            "words": ["type": "boolean", "description": "Include per-word start/end times."],
         ]) { $1 }, required: ["text", "out"])],
        ["name": "synthesize_batch",
         "description": "Render many clips (e.g. per-scene voiceover) to <out_dir>/<id>.<format>. Returns, per clip, its path and exact duration.",
         "inputSchema": schema(voiceProperties.merging([
            "clips": ["type": "array", "description": "[{id, text, …per-clip voice/engine/language/speed}]",
                      "items": ["type": "object", "properties": ["id": ["type": "string"], "text": ["type": "string"]],
                                "required": ["text"]]],
            "out_dir": ["type": "string", "description": "Absolute directory."],
            "format": ["type": "string", "enum": ["wav", "m4a"]],
            "speed": ["type": "number"],
            "words": ["type": "boolean"],
         ]) { $1 }, required: ["clips", "out_dir"])],
        ["name": "list_voices",
         "description": "Voices usable right now, per language (only engines that are set up and reachable).",
         "inputSchema": schema(["engine": voiceProperties["engine"]!, "language": voiceProperties["language"]!])],
        ["name": "list_engines",
         "description": "Engines and their health per reading language.",
         "inputSchema": schema([:])],
        ["name": "status",
         "description": "Whether Narrateify is reading, its speed, and each language's engine chain.",
         "inputSchema": schema([:])],
        ["name": "stop",
         "description": "Stop reading aloud.",
         "inputSchema": schema([:])],
    ]

    /// Each tool call runs in its own task, so a long `speak --wait` or batch
    /// doesn't block `ping` or other calls. Replies are written whole, one
    /// line each, under a lock.
    static func run() async {
        await withTaskGroup(of: Void.self) { group in
            while let line = readLine(strippingNewline: true) {
                group.addTask { await handle(line) }
            }
        }
    }

    private static func handle(_ line: String) async {
        do {
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty,
                  let data = line.data(using: .utf8),
                  let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            let id = message["id"]
            guard let method = message["method"] as? String else { return }
            let params = message["params"] as? [String: Any] ?? [:]
            guard id != nil else { return }   // notifications (initialized, cancelled) need no reply

            switch method {
            case "initialize":
                reply(id, result: [
                    "protocolVersion": params["protocolVersion"] as? String ?? "2025-06-18",
                    "capabilities": ["tools": [:]],
                    "serverInfo": ["name": "narrateify", "version": "1.0.0"],
                    "instructions": "Text-to-speech through the Narrateify app on this Mac. synthesize/synthesize_batch write audio files and report exact durations; speak reads aloud. Engines and voices follow the user's per-language settings unless you pass voice/engine.",
                ])
            case "ping":
                reply(id, result: [:])
            case "tools/list":
                reply(id, result: ["tools": tools])
            case "tools/call":
                let name = params["name"] as? String ?? ""
                let args = params["arguments"] as? [String: Any] ?? [:]
                do {
                    let output = try await call(name, args)
                    reply(id, result: ["content": [["type": "text", "text": output]]])
                } catch {
                    reply(id, result: ["content": [["type": "text", "text": error.localizedDescription]], "isError": true])
                }
            default:
                reply(id, error: ["code": -32601, "message": "Method not found: \(method)"])
            }
        }
    }

    private static func call(_ name: String, _ args: [String: Any]) async throws -> String {
        var options = args
        for key in ["text", "out", "wait", "clips", "out_dir"] { options.removeValue(forKey: key) }
        switch name {
        case "speak":
            guard let text = args["text"] as? String else { throw Client.Failure(message: "text is required") }
            try await Operations.speak(text, options, wait: args["wait"] as? Bool ?? false)
            return args["wait"] as? Bool == true ? "Finished reading." : "Reading started."
        case "synthesize":
            guard let text = args["text"] as? String, let out = args["out"] as? String else {
                throw Client.Failure(message: "text and out are required")
            }
            return JSONOutput.pretty(try await Operations.synthesize(text, to: out, options))
        case "synthesize_batch":
            guard let clips = args["clips"] as? [[String: Any]], let dir = args["out_dir"] as? String else {
                throw Client.Failure(message: "clips and out_dir are required")
            }
            return JSONOutput.pretty(try await Operations.batch(clips, outDir: dir, options))
        case "list_voices":
            var query: [String: String] = [:]
            if let engine = args["engine"] as? String { query["engine"] = engine }
            if let language = args["language"] as? String { query["language"] = language }
            return JSONOutput.pretty(try await Client.json("GET", "v1/voices", query: query))
        case "list_engines":
            return JSONOutput.pretty(try await Client.json("GET", "v1/engines"))
        case "status":
            return JSONOutput.pretty(try await Client.json("GET", "v1/status"))
        case "stop":
            _ = try await Client.json("POST", "v1/stop")
            return "Stopped."
        default:
            throw Client.Failure(message: "Unknown tool \(name)")
        }
    }

    private static let output = NSLock()   // calls run concurrently; lines must not interleave

    private static func reply(_ id: Any?, result: Any? = nil, error: Any? = nil) {
        var message: [String: Any] = ["jsonrpc": "2.0", "id": id ?? NSNull()]
        if let result { message["result"] = result }
        if let error { message["error"] = error }
        guard let data = try? JSONSerialization.data(withJSONObject: message, options: [.withoutEscapingSlashes]) else { return }
        output.withLock { FileHandle.standardOutput.write(data + Data("\n".utf8)) }
    }
}
