import Foundation

// `narrateify`: Narrateify's text-to-speech from any shell, script or agent.
// A thin client over the app's local API (starts the app if it isn't running);
// `narrateify mcp` serves the same over stdio MCP.

let usage = """
narrateify: text-to-speech through the Narrateify app (same engines, voices and fallbacks)

USAGE
  narrateify say [TEXT…|-] [voice options] [--wait]       read aloud in the reader
  narrateify synth [TEXT…|-] -o FILE [voice options]      render to .wav/.m4a (-o - streams WAV to stdout)
        [--speed N] [--format wav|m4a] [--words] [--json]
  narrateify batch CLIPS.json --out-dir DIR [voice options] [--speed N] [--format wav|m4a] [--words]
        CLIPS.json: [{"id": "intro", "text": "…", "voice"?: …}, …]  →  JSON manifest on stdout
  narrateify voices [--engine E] [--language L] [--json]
  narrateify engines [--json]
  narrateify models [--json]                              local models: installed, installable, size, quality
  narrateify install MODEL                                download a model (kokoro ~345 MB, qwen3-tts-1.7b ~2.9 GB)
  narrateify uninstall MODEL
  narrateify status | stop
  narrateify mcp                                          stdio MCP server
  narrateify install-cli [--dir DIR]                      symlink this binary into DIR (default ~/.local/bin)

VOICE OPTIONS
  --voice V       voice id or name ("de-DE-KatjaNeural", "edge:en-US-AvaNeural", "F1", "Anna")
  --engine E      edge | supertonic | apple | elevenLabs | openAI | kokoro | qwen3 (tried first, chain follows)
  --model M       a local model from `narrateify models`: kokoro, qwen3-tts-1.7b (picks its engine)
  --language L    "en", "de-DE", … (skips detection)
  --strict        only that engine/voice, no fallback (the default for on-demand models: kokoro, qwen3)
  --fallback      on-demand model: fall back down the language's chain if it can't run
  --install       download the model first if it's missing
  --raw           skip the app's text cleanup and pronunciation rules

Kokoro voices: af_heart (default for English), af_bella, am_michael, bf_emma, … (`narrateify voices --engine kokoro`).
Qwen3 voices: F1–M5 (cloned from the Supertonic voices), any clip in
~/Library/Application Support/Narrateify/Voices by name, or --voice /path/to/clip.wav.

Text comes from the arguments, or stdin when there are none (or "-"). --file PATH reads a file.
Text starting with "-" goes after --:  narrateify say -- "-5 degrees outside"
Files default to 1× speed; `say` uses the app's speed.
"""

struct Arguments {
    var positional: [String] = []
    var flags: [String: String] = [:]
    var switches: Set<String> = []

    static let valued: Set<String> = ["voice", "engine", "model", "language", "speed", "format", "o", "out", "out-dir", "file", "dir"]
    static let known: Set<String> = ["strict", "fallback", "install", "raw", "words", "json", "wait", "h", "help"]

    /// Unknown flags are errors (a typo'd `--voise Anna` must not be read
    /// aloud). Everything after `--` is text, for text starting with "-".
    init(_ args: ArraySlice<String>) throws {
        var it = args.makeIterator()
        var textOnly = false
        while let arg = it.next() {
            if textOnly || arg == "-" || !arg.hasPrefix("-") { positional.append(arg); continue }
            if arg == "--" { textOnly = true; continue }
            var name = String(arg.drop { $0 == "-" })
            var value: String?
            if let eq = name.firstIndex(of: "=") {
                value = String(name[name.index(after: eq)...])
                name = String(name[..<eq])
            }
            if Self.valued.contains(name) {
                guard let v = value ?? it.next() else { throw Client.Failure(message: "--\(name) needs a value") }
                flags[name == "o" ? "out" : name] = v
            } else if Self.known.contains(name) {
                switches.insert(name)
            } else {
                throw Client.Failure(message: "Unknown option \(arg). Run narrateify help (text starting with \"-\" goes after --).")
            }
        }
    }

    /// Body keys for the API from the voice options.
    func options() throws -> Operations.Options {
        var o: Operations.Options = [:]
        for key in ["voice", "engine", "model", "language", "format"] { if let v = flags[key] { o[key] = v } }
        if let speed = flags["speed"] {
            guard let value = Double(speed) else { throw Client.Failure(message: "--speed needs a number, got \(speed)") }
            o["speed"] = value
        }
        if switches.contains("strict") { o["strict"] = true }
        if switches.contains("fallback") { o["fallback"] = true }
        if switches.contains("install") { o["install"] = true }
        if switches.contains("raw") { o["clean"] = false }
        if switches.contains("words") { o["words"] = true }
        return o
    }

    func text() throws -> String {
        if let file = flags["file"] { return try String(contentsOfFile: Operations.absolute(file), encoding: .utf8) }
        if positional.isEmpty || positional == ["-"] {
            return String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
        }
        return positional.joined(separator: " ")
    }
}

func printJSON(_ value: Any) { print(JSONOutput.pretty(value)) }

func describe(_ result: [String: Any]) -> String {
    let duration = (result["duration"] as? Double).map { String(format: "%.3fs", $0) } ?? "?"
    let voices = ((result["sections"] as? [[String: Any]]) ?? [])
        .map { "\($0["engine"] ?? "?"):\($0["voice"] ?? "?")" }
    var line = "\(result["path"] ?? "?")  \(duration)  \(Array(NSOrderedSet(array: voices)).map { "\($0)" }.joined(separator: ", "))"
    if result["fell_back"] as? Bool == true { line += "  (fell back)" }
    return line
}

func describeModel(_ m: [String: Any]) -> String {
    let gb = Double(m["download_bytes"] as? Int64 ?? Int64(m["download_bytes"] as? Int ?? 0)) / 1e9
    var state = m["installed"] as? Bool == true ? (m["loaded"] as? Bool == true ? "installed, loaded" : "installed") : "not installed"
    if let p = m["installing"] as? Double { state = "downloading \(Int(p * 100))%" }
    if let why = m["unsupported"] as? String { state = "unavailable: \(why)" }
    let tag = m["on_demand"] as? Bool == true ? "on demand" : "reading chain"
    return "\(m["id"] ?? "")\t\(m["name"] ?? "")\t\(String(format: "%.2f GB", gb))\tquality \(m["quality"] ?? "?")/10\t\(tag)\t\(state)"
}

func modelIDs() async throws -> String {
    ((try await Client.json("GET", "v1/models") as? [[String: Any]]) ?? []).compactMap { $0["id"] as? String }
        .joined(separator: ", ")
}

/// Starts the download and prints progress until the app says it's done.
func installModel(_ model: String) async throws {
    final class Outcome: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Result<Any, Error>?
        var result: Result<Any, Error>? { lock.withLock { value } }
        func set(_ r: Result<Any, Error>) { lock.withLock { value = r } }
    }
    let outcome = Outcome()
    Task {
        do { outcome.set(.success(try await Client.json("POST", "v1/models/install", body: ["model": model]))) }
        catch { outcome.set(.failure(error)) }
    }
    var last = -1
    while true {
        if let result = outcome.result {
            if last >= 0 { FileHandle.standardError.write(Data("\n".utf8)) }
            print(describeModel(try result.get() as? [String: Any] ?? [:]))
            return
        }
        if let models = try? await Client.json("GET", "v1/models") as? [[String: Any]],
           let m = models.first(where: { $0["id"] as? String == model }),
           let p = m["installing"] as? Double, Int(p * 100) != last {
            last = Int(p * 100)
            FileHandle.standardError.write(Data("\rDownloading \(model)… \(last)%".utf8))
        }
        try await Task.sleep(for: .milliseconds(500))
    }
}

func run() async throws {
    let all = CommandLine.arguments
    guard all.count > 1 else { print(usage); return }
    let command = all[1]
    let args = try Arguments(all.dropFirst(2))

    switch command {
    case "say", "speak":
        try await Operations.speak(try args.text(), try args.options(), wait: args.switches.contains("wait"))

    case "synth", "synthesize":
        guard let out = args.flags["out"] else { throw Client.Failure(message: "synth needs -o FILE (or -o - for a WAV stream)") }
        let text = try args.text()
        if out == "-" {
            var body = try args.options()
            body["text"] = text
            body["stream"] = true
            try await Client.stream("v1/synthesize", body: body, to: .standardOutput)
            return
        }
        let result = try await Operations.synthesize(text, to: out, try args.options())
        if args.switches.contains("json") { printJSON(result) } else { print(describe(result)) }

    case "batch":
        guard let manifest = args.positional.first, let dir = args.flags["out-dir"] ?? args.flags["out"] else {
            throw Client.Failure(message: "batch needs CLIPS.json and --out-dir DIR")
        }
        let data = manifest == "-" ? FileHandle.standardInput.readDataToEndOfFile()
            : try Data(contentsOf: URL(fileURLWithPath: Operations.absolute(manifest)))
        let parsed = try JSONSerialization.jsonObject(with: data)
        guard let clips = (parsed as? [[String: Any]]) ?? ((parsed as? [String: Any])?["clips"] as? [[String: Any]]) else {
            throw Client.Failure(message: "CLIPS.json must be an array of {id, text} (or {\"clips\": [...]})")
        }
        printJSON(try await Operations.batch(clips, outDir: dir, try args.options()))

    case "voices":
        var query: [String: String] = [:]
        if let engine = args.flags["engine"] { query["engine"] = engine }
        if let language = args.flags["language"] { query["language"] = language }
        let voices = try await Client.json("GET", "v1/voices", query: query) as? [[String: Any]] ?? []
        if args.switches.contains("json") { return printJSON(voices) }
        for v in voices {
            let mark = v["configured"] as? Bool == true ? "*" : " "
            print("\(mark) \(v["language"] ?? "")\t\(v["engine"] ?? "")\t\(v["id"] ?? "")\t\(v["name"] ?? "")")
        }
        print("(* = in that language's chain in Settings)")

    case "engines":
        let engines = try await Client.json("GET", "v1/engines") as? [[String: Any]] ?? []
        if args.switches.contains("json") { return printJSON(engines) }
        for e in engines {
            let health = (e["health"] as? [String: String] ?? [:]).sorted { $0.key < $1.key }
                .map { "\($0.key): \($0.value)" }.joined(separator: ", ")
            print("\(e["id"] ?? "")\t\(e["name"] ?? "")\t\(health)")
        }

    case "status":
        printJSON(try await Client.json("GET", "v1/status"))

    case "stop":
        _ = try await Client.json("POST", "v1/stop")

    case "mcp":
        await MCPServer.run()

    case "models":
        let models = try await Client.json("GET", "v1/models") as? [[String: Any]] ?? []
        if args.switches.contains("json") { return printJSON(models) }
        for m in models { print(describeModel(m)) }

    case "install":
        guard let model = args.positional.first else {
            throw Client.Failure(message: "install needs a model: \(try await modelIDs()). (Symlinking the CLI is install-cli.)")
        }
        try await installModel(model)

    case "uninstall":
        guard let model = args.positional.first else { throw Client.Failure(message: "uninstall needs a model") }
        _ = try await Client.json("POST", "v1/models/uninstall", body: ["model": model])
        print("Removed \(model).")

    case "install-cli":
        let dir = Operations.absolute(args.flags["dir"] ?? "~/.local/bin")
        let me = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().path
        let link = (dir as NSString).appendingPathComponent("narrateify")
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(atPath: link)
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: me)
        print("\(link) → \(me)")
        if !(ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").contains(Substring(dir)) {
            print("Note: \(dir) isn't on your PATH.")
        }

    case "help", "-h", "--help":
        print(usage)

    default:
        throw Client.Failure(message: "Unknown command \"\(command)\". Run narrateify help.")
    }
}

do {
    try await run()
} catch {
    FileHandle.standardError.write(Data("narrateify: \(error.localizedDescription)\n".utf8))
    exit(1)
}
