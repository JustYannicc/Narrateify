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
    }

    init() {
        let d = UserDefaults.standard
        profiles = d.data(forKey: Keys.profiles)
            .flatMap { try? JSONDecoder().decode([LanguageProfile].self, from: $0) }
            ?? Self.initialLanguages().map(Self.defaultProfile)
        keepModelsWarm = d.object(forKey: Keys.warm) as? Bool ?? true
        unloadAfterMinutes = d.object(forKey: Keys.unload) as? Int ?? 10
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

    static let defaultEdgeVoice: [String: String] = [
        "en-US": "en-US-AvaMultilingualNeural",
        "en-GB": "en-GB-SoniaNeural",
        "de-DE": "de-DE-SeraphinaMultilingualNeural",
        "fr-FR": "fr-FR-VivienneMultilingualNeural",
        "es-ES": "es-ES-ElviraNeural",
        "it-IT": "it-IT-ElsaNeural",
    ]
}
