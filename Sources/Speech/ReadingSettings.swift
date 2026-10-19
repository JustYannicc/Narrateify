import Foundation

/// The user's reading languages and, for each, the ordered engine/voice chain
/// to try. Persisted as JSON in UserDefaults.
///
/// Most people read in one or two languages; only those are ever detected.
/// With a single language, detection is skipped entirely.
@MainActor
final class ReadingSettings: ObservableObject {
    @Published var profiles: [LanguageProfile] { didSet { persist() } }
    /// Keep local models loaded between narrations (instant start, costs RAM).
    @Published var keepModelsWarm: Bool {
        didSet { UserDefaults.standard.set(keepModelsWarm, forKey: Keys.warm) }
    }
    /// When not kept warm, unload local models after this many idle minutes.
    @Published var unloadAfterMinutes: Int {
        didSet { UserDefaults.standard.set(unloadAfterMinutes, forKey: Keys.unload) }
    }

    var languages: [ReadingLanguage] { profiles.map(\.language) }

    private enum Keys {
        static let profiles = "readingProfiles.v1"
        static let warm = "keepModelsWarm"
        static let unload = "unloadModelsAfterMinutes"
        static let plainEdgeVoices = "migratedToPlainEdgeVoices"
    }

    init() {
        let d = UserDefaults.standard
        let stored = d.data(forKey: Keys.profiles)
            .flatMap { try? JSONDecoder().decode([LanguageProfile].self, from: $0) }
        let migrated = stored.map(Self.migratingToPlainEdgeVoices)
        profiles = migrated ?? Self.initialLanguages().map(Self.defaultProfile)
        d.set(true, forKey: Keys.plainEdgeVoices)   // fresh installs start plain already
        keepModelsWarm = d.object(forKey: Keys.warm) as? Bool ?? true
        unloadAfterMinutes = d.object(forKey: Keys.unload) as? Int ?? 10
        if migrated != stored { persist() }   // didSet doesn't run in init
    }

    func profile(for language: ReadingLanguage) -> LanguageProfile {
        profiles.first { $0.language == language } ?? Self.defaultProfile(language)
    }

    func addLanguage(_ language: ReadingLanguage) {
        guard !profiles.contains(where: { $0.language == language }) else { return }
        profiles.append(Self.defaultProfile(language))
    }

    func removeLanguage(_ language: ReadingLanguage) {
        guard profiles.count > 1 else { return }   // always keep one
        profiles.removeAll { $0.language == language }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(profiles) {
            UserDefaults.standard.set(data, forKey: Keys.profiles)
        }
    }

    // MARK: Defaults

    /// First run: the system's preferred languages (max two), normalized to a
    /// region we have good voices for (plain "de" → de-DE, not de-CH).
    static func initialLanguages() -> [ReadingLanguage] {
        var seen = Set<String>()
        let langs = Locale.preferredLanguages.compactMap { tag -> ReadingLanguage? in
            let base = ReadingLanguage(code: tag).base
            guard !base.isEmpty, seen.insert(base).inserted else { return nil }
            return ReadingLanguage(code: preferredRegion[base] ?? tag)
        }
        return Array(langs.prefix(2)).isEmpty ? [.englishUS] : Array(langs.prefix(2))
    }

    /// Region with the best neural voices per base language.
    static let preferredRegion: [String: String] = [
        "en": "en-US", "de": "de-DE", "fr": "fr-FR", "es": "es-ES", "it": "it-IT",
        "pt": "pt-BR", "nl": "nl-NL", "ja": "ja-JP", "ko": "ko-KR", "zh": "zh-CN",
        "tr": "tr-TR", "pl": "pl-PL", "sv": "sv-SE", "da": "da-DK", "ru": "ru-RU",
        "ar": "ar-SA", "bg": "bg-BG", "hr": "hr-HR", "cs": "cs-CZ", "et": "et-EE", "fi": "fi-FI",
        "el": "el-GR", "hi": "hi-IN", "hu": "hu-HU", "id": "id-ID", "lv": "lv-LV", "lt": "lt-LT",
        "ro": "ro-RO", "sk": "sk-SK", "sl": "sl-SI", "uk": "uk-UA", "vi": "vi-VN",
    ]

    /// Edge (best quality when reachable) → Supertonic (local, fast) → Apple
    /// (always there).
    static func defaultProfile(_ language: ReadingLanguage) -> LanguageProfile {
        var routes: [VoiceRoute] = []
        if let edge = defaultEdgeVoice[language.code] {
            routes.append(VoiceRoute(engine: .edge, voiceID: edge))
        }
        routes.append(VoiceRoute(engine: .supertonic, voiceID: SupertonicEngine.defaultVoiceID))
        routes.append(VoiceRoute(engine: .apple, voiceID: AppleSpeechEngine.defaultVoice(for: language) ?? ""))
        return LanguageProfile(language: language, routes: routes)
    }

    /// Plain (single-language) voices: sections are already split by
    /// language, and plain voices start faster than the Multilingual ones.
    static let defaultEdgeVoice: [String: String] = [
        "en-US": "en-US-AvaNeural",
        "en-GB": "en-GB-SoniaNeural",
        "de-DE": "de-DE-KatjaNeural",
        "fr-FR": "fr-FR-DeniseNeural",
        "es-ES": "es-ES-ElviraNeural",
        "it-IT": "it-IT-ElsaNeural",
    ]

    /// The multilingual defaults shipped before 2.0.0 build 6. Once, wherever
    /// one of these is an Edge route, it becomes that language's plain default
    /// (even if it was picked by hand). Voices picked after that are left alone.
    private static let oldDefaultEdgeVoices: Set<String> = [
        "en-US-AvaMultilingualNeural", "de-DE-SeraphinaMultilingualNeural", "fr-FR-VivienneMultilingualNeural",
    ]

    private static func migratingToPlainEdgeVoices(_ profiles: [LanguageProfile]) -> [LanguageProfile] {
        guard !UserDefaults.standard.bool(forKey: Keys.plainEdgeVoices) else { return profiles }
        return profiles.map { profile in
            var p = profile
            for i in p.routes.indices where p.routes[i].engine == .edge
                && oldDefaultEdgeVoices.contains(p.routes[i].voiceID) {
                p.routes[i].voiceID = defaultEdgeVoice[p.language.code] ?? p.routes[i].voiceID
            }
            return p
        }
    }
}
