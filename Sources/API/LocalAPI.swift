import AVFoundation
import OSLog

private let log = Logger(category: "api")

/// The local API: everything the hotkey can do, for any program on this Mac
/// (the bundled `narrateify` CLI and its MCP server are just clients).
/// Same planner, engine chains and fallbacks as reading a selection.
///
///   GET  /v1/status                      app version, reading?, languages + chains
///   GET  /v1/engines                     engines and their health per language
///   GET  /v1/voices?engine=&language=    voices you can pass as `voice`
///   GET  /v1/models                      local models: installed, installable, size, quality
///   POST /v1/models/install {model}      download one (blocks until done; poll /v1/models)
///   POST /v1/models/uninstall {model}
///   POST /v1/speak       {text, …}       read aloud in the reader, like the hotkey
///   POST /v1/stop                        stop reading
///   POST /v1/synthesize  {text, …}       audio file / bytes / WAV stream
///
/// Port 47801 unless taken; the real one is in
/// ~/Library/Application Support/Narrateify/api.json (`APIEndpoint`).
@MainActor
final class LocalAPI {
    static let shared = LocalAPI()
    static let enabledKey = "localAPIEnabled"

    private(set) var port: UInt16?
    private var server: HTTPServer?

    static var isEnabled: Bool { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }

    func start() {
        guard server == nil, Self.isEnabled else { return }
        let server = HTTPServer { request, response in
            await LocalAPI.shared.handle(request, response)
        }
        self.server = server
        server.start(preferred: APIEndpoint.preferredPort) { port in
            Task { @MainActor in LocalAPI.shared.didStart(port) }
        }
    }

    func stop() {
        server?.stop()
        server = nil
        port = nil
        try? FileManager.default.removeItem(at: APIEndpoint.discoveryFile)
    }

    private func didStart(_ port: UInt16?) {
        self.port = port
        guard let port else { return log.error("local API couldn't bind") }
        let info: [String: Any] = ["port": Int(port), "url": "http://127.0.0.1:\(port)",
                                   "pid": Int(ProcessInfo.processInfo.processIdentifier),
                                   "version": Bundle.main.shortVersion]
        try? FileManager.default.createDirectory(at: APIEndpoint.discoveryFile.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? JSONSerialization.data(withJSONObject: info, options: [.sortedKeys]).write(to: APIEndpoint.discoveryFile)
    }

    // MARK: Routing

    struct APIError: Error {
        let status: Int
        let message: String
        init(_ status: Int, _ message: String) { self.status = status; self.message = message }
    }

    private var state: AppState { AppState.shared }
    private var narrator: Narrator { state.narrator }

    private func handle(_ request: HTTPServer.Request, _ response: HTTPServer.Response) async {
        do {
            switch (request.method, request.path) {
            case ("GET", "/v1/status"), ("GET", "/"):    response.json(status())
            case ("GET", "/v1/engines"):                 response.json(engines())
            case ("GET", "/v1/voices"):                  response.json(try await voices(request.query))
            case ("POST", "/v1/speak"):                  response.json(try await speak(try decode(request.body)))
            case ("POST", "/v1/stop"):
                state.stop()
                response.json(["ok": true])
            case ("POST", "/v1/synthesize"):             try await synthesize(try decode(request.body), response)
            case ("GET", "/v1/models"):                  response.json(state.models)
            case ("POST", "/v1/models/install"):
                let engine = try modelEngine(try decode(request.body) as ModelRef)
                try await state.installModel(for: engine)
                response.json(state.models.first { $0.engine == engine.rawValue })
            case ("POST", "/v1/models/uninstall"):
                let engine = try modelEngine(try decode(request.body) as ModelRef)
                try await state.uninstallModel(for: engine)
                response.json(["ok": true])
            case (_, "/v1/models"), (_, "/v1/models/install"), (_, "/v1/models/uninstall"),
                 (_, "/v1/status"), (_, "/v1/engines"), (_, "/v1/voices"),
                 (_, "/v1/speak"), (_, "/v1/stop"), (_, "/v1/synthesize"):
                throw APIError(405, "Wrong method for \(request.path)")
            default:
                throw APIError(404, "No such endpoint: \(request.path). Try GET /v1/status.")
            }
        } catch let error as APIError {
            response.error(error.status, error.message)
        } catch {
            response.error(500, error.localizedDescription)
        }
    }

    private func decode<T: Decodable>(_ body: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        do {
            return try decoder.decode(T.self, from: body.isEmpty ? Data("{}".utf8) : body)
        } catch {
            throw APIError(400, "Bad JSON body: \(error.localizedDescription)")
        }
    }

    // MARK: Endpoints

    private struct Status: Encodable {
        struct Chain: Encodable { let language: String; let routes: [String] }
        let app = "Narrateify"
        let version: String
        let reading: Bool
        let speed: Float
        let languages: [Chain]
    }

    private func status() -> Status {
        Status(version: Bundle.main.shortVersion, reading: narrator.isActive, speed: state.audio.rate,
               languages: narrator.settings.profiles.map { .init(language: $0.language.code, routes: $0.routes.map(\.id)) })
    }

    private struct Engine: Encodable {
        let id: String
        let name: String
        let local: Bool
        let cloudPaid: Bool
        /// Never in a reading chain; only used when a call asks for it.
        let onDemand: Bool
        /// Per reading language: "ok", "unreachable", or why not.
        let health: [String: String]

        enum CodingKeys: String, CodingKey { case id, name, local, cloudPaid = "cloud_paid", onDemand = "on_demand", health }
    }

    private func engines() -> [Engine] {
        SpeechEngineKind.allCases.map { kind in
            var health: [String: String] = [:]
            for language in narrator.settings.languages {
                switch narrator.health(kind, language: language) {
                case .ok: health[language.code] = "ok"
                case .unreachable: health[language.code] = "unreachable"
                case .needsSetup(let why), .unsupported(let why): health[language.code] = why
                }
            }
            return Engine(id: kind.rawValue, name: kind.label, local: kind.isLocal, cloudPaid: kind.isCloudPaid,
                          onDemand: kind.isOnDemand, health: health)
        }
    }

    private struct Voice: Encodable {
        let engine: String
        let id: String
        let name: String
        let language: String
        /// In this language's chain in Settings.
        let configured: Bool
    }

    private func voices(_ query: [String: String]) async throws -> [Voice] {
        let kinds = try query["engine"].map { [try engineKind($0)] } ?? SpeechEngineKind.allCases
        let languages = try query["language"].map { [try readingLanguage($0)] } ?? narrator.settings.languages
        var out: [Voice] = []
        for language in languages {
            let chain = Set(narrator.settings.profile(for: language).routes.map(\.id))
            for kind in kinds {
                guard case .ok = narrator.health(kind, language: language) else { continue }
                for voice in await narrator.voices(kind, language: language) {
                    let route = VoiceRoute(engine: kind, voiceID: voice.id)
                    out.append(Voice(engine: kind.rawValue, id: voice.id, name: voice.name,
                                     language: language.code, configured: chain.contains(route.id)))
                }
            }
        }
        return out
    }

    private struct ModelRef: Decodable { var model: String? }

    private func modelEngine(_ ref: ModelRef) throws -> SpeechEngineKind {
        guard let id = ref.model, let engine = state.modelEngine(id) else {
            throw APIError(400, "Unknown model \"\(ref.model ?? "")\". Models: \(state.models.map(\.id).joined(separator: ", "))")
        }
        return engine
    }

    struct Pick: Decodable {
        var text: String?
        var language: String?
        var engine: String?
        /// A local model id from /v1/models ("qwen3-tts-1.7b"); picks its engine.
        var model: String?
        var voice: String?
        /// Only that engine/voice. Default: off, but on for on-demand models.
        var strict: Bool?
        /// On-demand models: allow falling back down the chain (= strict false).
        var fallback: Bool?
        /// Download the model first if it's missing (can be GBs).
        var install: Bool?
        /// Run the app's text cleanup + pronunciation rules (default on).
        var clean: Bool?
    }

    private func speak(_ body: Pick) async throws -> [String: Bool] {
        let text = try readableText(body)
        let choice = try await choice(body)
        state.narrate(text, choice: choice, preprocessed: true)
        return ["ok": true]
    }

    private struct SynthesizeBody: Decodable {
        var pick: Pick
        var speed: Float?
        var format: String?
        /// Absolute path: write the file there and reply with JSON.
        var out: String?
        /// Reply with a WAV stream that starts as soon as the first section is ready.
        var stream: Bool?
        /// Include per-word timings in the JSON reply.
        var words: Bool?

        enum CodingKeys: String, CodingKey { case speed, format, out, stream, words }
        init(from decoder: Decoder) throws {
            pick = try Pick(from: decoder)
            let c = try decoder.container(keyedBy: CodingKeys.self)
            speed = try c.decodeIfPresent(Float.self, forKey: .speed)
            format = try c.decodeIfPresent(String.self, forKey: .format)
            out = try c.decodeIfPresent(String.self, forKey: .out)
            stream = try c.decodeIfPresent(Bool.self, forKey: .stream)
            words = try c.decodeIfPresent(Bool.self, forKey: .words)
        }
    }

    private struct Rendered: Encodable {
        struct Section: Encodable {
            let text: String
            let language: String
            let engine: String
            /// The local model behind `engine`, when it is one.
            let model: String?
            let voice: String
            let start: Double
            let duration: Double
        }
        struct Word: Encodable { let text: String; let start: Double; let end: Double }

        let path: String?
        let format: String
        let duration: Double
        let sampleRate: Int
        let speed: Float
        /// A section came from a later engine in the chain than the one asked for.
        let fellBack: Bool
        let sections: [Section]
        let words: [Word]?

        enum CodingKeys: String, CodingKey {
            case path, format, duration, sampleRate = "sample_rate", speed, fellBack = "fell_back", sections, words
        }
    }

    private func synthesize(_ body: SynthesizeBody, _ response: HTTPServer.Response) async throws {
        let text = try readableText(body.pick)
        let choice = try await choice(body.pick)
        // Files default to 1×: the app's reading speed is a listening
        // preference, not something a voiceover should inherit.
        let speed = min(max(body.speed ?? 1, 0.5), 3)

        if body.stream == true {
            // Headers go out with the first audio, so an engine failure before
            // that is still a proper error response. A failure after it drops
            // the connection, so the client can't mistake a cut-off file for a
            // whole one. Writes wait for the socket (backpressure), and the
            // task is cancelled if the client hangs up.
            var started = false
            do {
                _ = try await narrator.render(text, choice: choice, speed: speed) { buffer in
                    if !started {
                        started = true
                        try await response.begin(contentType: "audio/wav", headers: ["X-Narrateify-Speed": "\(speed)"])
                        try await response.write(WAVEncoder.header(dataSize: .max, sampleRate: Int(AudioOutput.sampleRate)))
                    }
                    try await response.write(AudioOutput.int16Data(buffer))
                }
            } catch where started {
                log.error("stream ended early: \(error.localizedDescription, privacy: .public)")
                return response.abort()
            }
            return started ? response.end() : response.error(500, "No audio")
        }

        let out = try body.out.map { try outputURL($0, format: body.format) }
        let format = try outputFormat(body.format, out: out)

        var buffers: [AVAudioPCMBuffer] = []
        let sections = try await narrator.render(text, choice: choice, speed: speed) { buffers.append($0) }

        // Joining, encoding and file I/O can be hundreds of MB for long texts:
        // keep them off the main thread.
        nonisolated(unsafe) let parts = buffers
        let (data, duration) = try await Task.detached { () throws -> (Data?, TimeInterval) in
            guard let pcm = SectionDecoder.concatenate(parts) else { throw APIError(500, "No audio") }
            if let out { return (nil, try AudioOutput.write(pcm, to: out, format: format)) }
            return try AudioOutput.encode(pcm, format: format)
        }.value
        let result = describe(sections, path: out?.path, format: format, duration: duration, speed: speed,
                              choice: choice, words: body.words == true)
        guard let data else { return response.json(result) }
        response.send(status: 200, contentType: format.mimeType, body: data, headers: [
            "X-Narrateify-Duration": String(format: "%.3f", duration),
            "X-Narrateify-Voices": Set(sections.map(\.route.id)).sorted().joined(separator: ","),
            "X-Narrateify-Fell-Back": String(result.fellBack),
        ])
    }

    /// Absolute, a .wav/.m4a file (never an existing directory: writing
    /// replaces whatever is at the path).
    private func outputURL(_ path: String, format: String?) throws -> URL {
        let expanded = (path as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/") else { throw APIError(400, "`out` must be an absolute path") }
        var url = URL(fileURLWithPath: expanded)
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
            throw APIError(400, "`out` is a directory; give a file path ending in .wav or .m4a")
        }
        if url.pathExtension.isEmpty {
            guard let format else { throw APIError(400, "`out` needs a .wav or .m4a extension") }
            url.appendPathExtension(format)
        }
        return url
    }

    private func ms(_ t: Double) -> Double { (t * 1000).rounded() / 1000 }

    private func describe(_ sections: [RenderedSection], path: String?, format: AudioOutput.Format,
                          duration: Double, speed: Float, choice: VoiceChoice?, words: Bool) -> Rendered {
        // Fell back = a section wasn't read by the engine that should have
        // gone first: the one asked for, else the top of that language's chain.
        let models = Dictionary(state.models.map { ($0.engine, $0.id) }, uniquingKeysWith: { a, _ in a })
        let fellBack = sections.contains { s in
            let first = choice?.route?.engine ?? narrator.settings.profile(for: s.section.language).routes.first?.engine
            return first.map { $0 != s.route.engine } ?? false
        }
        return Rendered(
            path: path, format: format.rawValue, duration: ms(duration), sampleRate: Int(AudioOutput.sampleRate),
            speed: speed, fellBack: fellBack,
            sections: sections.map {
                .init(text: $0.section.text, language: $0.section.language.code, engine: $0.route.engine.rawValue,
                      model: models[$0.route.engine.rawValue], voice: $0.route.voiceID, start: ms($0.start), duration: ms($0.duration))
            },
            words: words ? sections.flatMap { s in
                s.words.map { w in
                    Rendered.Word(text: (s.section.text as NSString).substring(with: w.range),
                                  start: ms(w.start), end: ms(w.start + w.duration))
                }
            } : nil)
    }

    // MARK: Parameters

    private func readableText(_ pick: Pick) throws -> String {
        let raw = pick.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let text = pick.clean == false ? raw : state.textPreprocessor.process(raw)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw APIError(400, "`text` is empty")
        }
        return text
    }

    private func outputFormat(_ name: String?, out: URL?) throws -> AudioOutput.Format {
        if let name {
            guard let format = AudioOutput.Format(fileExtension: name) else {
                throw APIError(400, "`format` must be wav or m4a")
            }
            return format
        }
        guard let ext = out?.pathExtension, !ext.isEmpty else { return .wav }
        guard let format = AudioOutput.Format(fileExtension: ext) else {
            throw APIError(400, "Can't write .\(ext); use .wav or .m4a")
        }
        return format
    }

    private func engineKind(_ name: String) throws -> SpeechEngineKind {
        let key = name.lowercased().replacingOccurrences(of: "-", with: "").replacingOccurrences(of: " ", with: "")
        if let kind = SpeechEngineKind.allCases.first(where: {
            $0.rawValue.lowercased() == key || $0.shortName.lowercased() == key
        }) { return kind }
        throw APIError(400, "Unknown engine \"\(name)\". Engines: \(SpeechEngineKind.allCases.map(\.rawValue).joined(separator: ", "))")
    }

    /// "de" → de-DE (or whichever German the user reads), "en-GB" stays.
    private func readingLanguage(_ code: String) throws -> ReadingLanguage {
        let tag = code.replacingOccurrences(of: "_", with: "-").trimmingCharacters(in: .whitespaces)
        guard !tag.isEmpty else { throw APIError(400, "Empty language") }
        let asked = ReadingLanguage(code: tag)
        guard !tag.contains("-") else { return asked }
        return narrator.settings.languages.first { $0.base == asked.base }
            ?? ReadingLanguage(code: ReadingSettings.preferredRegion[asked.base] ?? tag)
    }

    /// Exact id, display name, or their short forms: "Anna" finds
    /// "com.apple.voice.compact.de-DE.Anna" / "Anna (de-DE)".
    private static func voice(_ option: VoiceOption, matches query: String) -> Bool {
        let shortName = option.name.components(separatedBy: " (").first ?? option.name
        let shortID = option.id.split(separator: ".").last.map(String.init) ?? option.id
        return [option.id, option.name, shortName, shortID].contains { $0.caseInsensitiveCompare(query) == .orderedSame }
    }

    /// Turns engine/voice/language into a choice. A voice pins the language
    /// (given, or the voice's own), so a German voice never reads English.
    private func choice(_ pick: Pick) async throws -> VoiceChoice? {
        var language = try pick.language.map(readingLanguage)
        var engine = try pick.engine.map(engineKind)
        if let model = pick.model {
            let kind = try modelEngine(ModelRef(model: model))
            if let engine, engine != kind {
                throw APIError(400, "`engine` is \(engine.rawValue) but model \(model) runs on \(kind.rawValue)")
            }
            engine = kind
        }
        var voice = pick.voice?.trimmingCharacters(in: .whitespaces)
        if let v = voice, let colon = v.firstIndex(of: ":"),
           let kind = try? engineKind(String(v[..<colon])) {   // "edge:de-DE-KatjaNeural"
            if let engine, engine != kind {
                throw APIError(400, "`engine` is \(engine.rawValue) but the voice is a \(kind.rawValue) voice")
            }
            engine = kind
            voice = String(v[v.index(after: colon)...])
        }
        if let v = voice, v.hasPrefix("/") || v.hasPrefix("~") {   // a reference clip to clone (Qwen3)
            if let engine, engine != .qwen3 { throw APIError(400, "Only qwen3 clones a voice from a file") }
            engine = .qwen3
            voice = (v as NSString).expandingTildeInPath
        }
        guard language != nil || engine != nil || !(voice ?? "").isEmpty else { return nil }
        let onDemand = engine?.isOnDemand ?? false
        if let strict = pick.strict, let fallback = pick.fallback, strict == fallback {
            throw APIError(400, "`strict` and `fallback` contradict each other; pass one")
        }
        let strict = pick.fallback.map { !$0 } ?? pick.strict ?? onDemand
        if let engine, engine.isOnDemand, let why = ModelHelper.unsupportedReason, strict {
            throw APIError(400, "\(engine.label) can't run here: \(why)")
        }
        if let engine, !state.isInstalled(engine) {
            if pick.install == true {
                try await state.installModel(for: engine)
            } else if strict {
                throw APIError(409, engine == .qwen3 ? Qwen3Engine.notInstalledMessage
                               : engine == .kokoro ? KokoroEngine.notInstalledMessage
                               : "\(engine.label) isn't installed. Pass install: true, or install it in Settings → Engines.")
            }
        }
        if let voice, voice.hasPrefix("/") {
            guard FileManager.default.fileExists(atPath: voice) else { throw APIError(400, "No reference clip at \(voice)") }
            return VoiceChoice(language: language, route: VoiceRoute(engine: .qwen3, voiceID: voice), strict: strict)
        }

        guard let voice, !voice.isEmpty else {
            return VoiceChoice(language: language, route: engine.map { VoiceRoute(engine: $0, voiceID: "") }, strict: strict)
        }

        // Where to look: the asked language, else the user's, else the locale
        // an Edge-style id starts with ("de-DE-KatjaNeural").
        var languages = language.map { [$0] } ?? narrator.settings.languages
        let parts = voice.split(separator: "-")
        if language == nil, parts.count >= 3, parts[0].count == 2, parts[1].count == 2 {
            languages.insert(ReadingLanguage(code: "\(parts[0])-\(parts[1])"), at: 0)
        }
        // On-demand engines only when asked for: "F1" alone means Supertonic's.
        let kinds = engine.map { [$0] } ?? SpeechEngineKind.chainable
        for lang in languages {
            for kind in kinds where narrator.hasEngine(kind) {
                let options = await narrator.voices(kind, language: lang)
                if let match = options.first(where: { Self.voice($0, matches: voice) }) {
                    language = language ?? lang
                    return VoiceChoice(language: language, route: VoiceRoute(engine: kind, voiceID: match.id), strict: strict)
                }
            }
        }
        throw APIError(400, "Unknown voice \"\(voice)\"\(engine.map { " for \($0.rawValue)" } ?? ""). List them with GET /v1/voices.")
    }
}
