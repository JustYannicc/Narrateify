import Foundation

/// One entry of the service's voice list (only the fields we use).
struct EdgeVoice: Codable, Hashable {
    let shortName: String
    let locale: String
    var gender: String? = nil
    var friendlyName: String? = nil

    enum CodingKeys: String, CodingKey {
        case shortName = "ShortName", locale = "Locale", gender = "Gender", friendlyName = "FriendlyName"
    }

    var isMultilingual: Bool { shortName.contains("Multilingual") }

    /// "en-US-AvaMultilingualNeural" → "Ava (Multilingual)".
    var displayName: String {
        var core = shortName.hasPrefix(locale + "-") ? String(shortName.dropFirst(locale.count + 1)) : shortName
        if core.hasSuffix("Neural") { core.removeLast("Neural".count) }
        var suffix = ""
        if core.hasSuffix("Multilingual") {
            core.removeLast("Multilingual".count)
            suffix = " (Multilingual)"
        }
        return core + suffix
    }

    var option: VoiceOption {
        let gender = gender.map { " · \($0)" } ?? ""
        // We only route by the voice's own locale for now, even for multilingual voices.
        return VoiceOption(id: shortName, name: "\(displayName)\(gender)", languages: [locale])
    }
}

/// Voice list: memory → disk cache (7 days) → network → hardcoded fallback.
actor EdgeVoiceCatalog {
    static let shared = EdgeVoiceCatalog()

    static let fallback: [EdgeVoice] = [
        EdgeVoice(shortName: "en-US-AvaMultilingualNeural", locale: "en-US", gender: "Female"),
        EdgeVoice(shortName: "en-US-AndrewMultilingualNeural", locale: "en-US", gender: "Male"),
        EdgeVoice(shortName: "en-US-EmmaMultilingualNeural", locale: "en-US", gender: "Female"),
        EdgeVoice(shortName: "en-US-BrianMultilingualNeural", locale: "en-US", gender: "Male"),
        EdgeVoice(shortName: "en-US-AriaNeural", locale: "en-US", gender: "Female"),
        EdgeVoice(shortName: "en-US-JennyNeural", locale: "en-US", gender: "Female"),
        EdgeVoice(shortName: "en-US-GuyNeural", locale: "en-US", gender: "Male"),
        EdgeVoice(shortName: "en-US-ChristopherNeural", locale: "en-US", gender: "Male"),
        EdgeVoice(shortName: "en-GB-SoniaNeural", locale: "en-GB", gender: "Female"),
        EdgeVoice(shortName: "en-GB-RyanNeural", locale: "en-GB", gender: "Male"),
        EdgeVoice(shortName: "de-DE-SeraphinaMultilingualNeural", locale: "de-DE", gender: "Female"),
        EdgeVoice(shortName: "de-DE-FlorianMultilingualNeural", locale: "de-DE", gender: "Male"),
        EdgeVoice(shortName: "de-DE-KatjaNeural", locale: "de-DE", gender: "Female"),
        EdgeVoice(shortName: "de-DE-ConradNeural", locale: "de-DE", gender: "Male"),
        EdgeVoice(shortName: "de-DE-AmalaNeural", locale: "de-DE", gender: "Female"),
        EdgeVoice(shortName: "de-DE-KillianNeural", locale: "de-DE", gender: "Male"),
        EdgeVoice(shortName: "de-CH-LeniNeural", locale: "de-CH", gender: "Female"),
        EdgeVoice(shortName: "de-CH-JanNeural", locale: "de-CH", gender: "Male"),
        EdgeVoice(shortName: "de-AT-IngridNeural", locale: "de-AT", gender: "Female"),
        EdgeVoice(shortName: "de-AT-JonasNeural", locale: "de-AT", gender: "Male"),
    ]

    static let cacheTTL: TimeInterval = 7 * 24 * 3600
    /// After a failed fetch, serve stale/fallback voices this long before retrying.
    static let retryAfter: TimeInterval = 5 * 60

    private let endpoints: [EdgeEndpoint]
    private let session: URLSession
    private let cacheURL: URL?
    private var memory: [EdgeVoice]
    /// When `memory` stops being good enough and the network should be tried.
    private var memoryExpires: Date
    private var inflight: Task<[EdgeVoice]?, Never>?

    private let localesLock = NSLock()
    private nonisolated(unsafe) var _knownLocales: Set<String>

    init(endpoints: [EdgeEndpoint] = EdgeEndpointV1.all,
         session: URLSession = EdgeHTTP.makeSession(),
         cacheURL: URL? = EdgeVoiceCatalog.defaultCacheURL) {
        self.endpoints = endpoints
        self.session = session
        self.cacheURL = cacheURL
        let cached = cacheURL.flatMap(Self.readCache)
        memory = cached?.voices ?? Self.fallback
        memoryExpires = cached.map { $0.fetched.addingTimeInterval(Self.cacheTTL) } ?? .distantPast
        _knownLocales = Self.locales(of: memory)
    }

    static var defaultCacheURL: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Narrateify", isDirectory: true)
            .appendingPathComponent("edge-voices.json")
    }

    /// Lowercased locales we have voices for, without waiting (for `supports(_:)`).
    nonisolated func knownLocales() -> Set<String> {
        localesLock.withLock { _knownLocales }
    }

    private static func locales(of voices: [EdgeVoice]) -> Set<String> {
        Set((voices + fallback).map { $0.locale.lowercased() })
    }

    /// All voices. Never throws; worst case is the stale cache or the hardcoded fallback.
    func allVoices() async -> [EdgeVoice] {
        if Date() < memoryExpires { return memory }
        if let fetched = await refresh() { return fetched }
        memoryExpires = Date().addingTimeInterval(Self.retryAfter)
        return memory
    }

    func voices(for language: ReadingLanguage) async -> [EdgeVoice] {
        Self.filter(await allVoices(), for: language)
    }

    /// Exact locale first ("de-DE"); if none, any voice with the same base ("de").
    static func filter(_ voices: [EdgeVoice], for language: ReadingLanguage) -> [EdgeVoice] {
        let exact = voices.filter { $0.locale.caseInsensitiveCompare(language.code) == .orderedSame }
        if !exact.isEmpty { return sorted(exact) }
        return sorted(voices.filter { $0.locale.lowercased().hasPrefix(language.base + "-") })
    }

    private static func sorted(_ v: [EdgeVoice]) -> [EdgeVoice] {
        v.sorted { a, b in
            a.isMultilingual != b.isMultilingual ? a.isMultilingual : a.shortName < b.shortName
        }
    }

    /// Fetch from the network (deduplicated). Returns nil on failure.
    @discardableResult
    func refresh() async -> [EdgeVoice]? {
        if let inflight { return await inflight.value }
        let task = Task { await self.fetch() }
        inflight = task
        let result = await task.value
        inflight = nil
        if let result {
            memory = result
            memoryExpires = Date().addingTimeInterval(Self.cacheTTL)
            let locales = Self.locales(of: result)
            localesLock.withLock { _knownLocales = locales }
            if let cacheURL { Self.writeCache(result, to: cacheURL) }
        }
        return result
    }

    private func fetch() async -> [EdgeVoice]? {
        for endpoint in endpoints {
            var request = endpoint.voiceListRequest(now: EdgeClock.shared.now())
            request.timeoutInterval = 6
            guard let (data, response) = try? await session.data(for: request),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let voices = try? JSONDecoder().decode([EdgeVoice].self, from: data),
                  !voices.isEmpty
            else { continue }
            return voices
        }
        return nil
    }

    // MARK: Disk cache

    private struct CacheFile: Codable {
        let fetched: Date
        let voices: [EdgeVoice]
    }

    private static func readCache(_ url: URL) -> CacheFile? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(CacheFile.self, from: data)
    }

    private static func writeCache(_ voices: [EdgeVoice], to url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(CacheFile(fetched: Date(), voices: voices)) {
            try? data.write(to: url, options: .atomic)
        }
    }
}
