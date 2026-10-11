import SwiftUI

/// Settings → Reading: which languages you read, and for each one the ordered
/// engine/voice chain to try (first that works wins).
struct ReadingSettingsView: View {
    @EnvironmentObject var state: AppState
    @ObservedObject var settings: ReadingSettings

    var body: some View {
        Form {
            Section {
                ForEach(settings.profiles) { profile in
                    HStack {
                        Text(profile.language.displayName)
                        if profile.language == settings.languages.first {
                            Text("default").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(role: .destructive) {
                            settings.removeLanguage(profile.language)
                        } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                        .disabled(settings.profiles.count == 1)
                        .help("Stop detecting this language")
                    }
                }
                .onMove { settings.profiles.move(fromOffsets: $0, toOffset: $1) }
                Menu("Add language") {
                    ForEach(LanguageCatalog.addable(excluding: settings.languages), id: \.self) { lang in
                        Button(lang.displayName) { settings.addLanguage(lang) }
                    }
                }
            } header: {
                Text("Languages you read")
            } footer: {
                Text("Only these are detected. Anything else is read as whichever of them it's closest to. With one language, detection is skipped. Drag to reorder — the first is used when a snippet is too short to tell.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            ForEach(settings.profiles) { profile in
                LanguageChainSection(profile: profile, settings: settings)
            }

            Section("Speed & memory") {
                Toggle("Keep local models loaded", isOn: $settings.keepModelsWarm)
                if !settings.keepModelsWarm {
                    Stepper("Unload after \(settings.unloadAfterMinutes) min idle",
                            value: $settings.unloadAfterMinutes, in: 1...120)
                }
                Text(settings.keepModelsWarm
                     ? "Instant start every time. Supertonic stays in memory (see Engines)."
                     : "Frees the memory between narrations; the first read after unloading takes a moment longer.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

/// One language's fallback chain.
private struct LanguageChainSection: View {
    @EnvironmentObject var state: AppState
    let profile: LanguageProfile
    @ObservedObject var settings: ReadingSettings
    @State private var testResult: String?
    @State private var testing = false

    var body: some View {
        Section {
            ForEach(Array(profile.routes.enumerated()), id: \.element.id) { index, route in
                RouteRow(index: index, route: route, language: profile.language,
                         onChange: { replace(index, with: $0) },
                         onMove: { move(index, by: $0) },
                         onDelete: { remove(index) },
                         isFirst: index == 0,
                         isLast: index == profile.routes.count - 1)
            }
            HStack {
                Menu("Add fallback") {
                    ForEach(SpeechEngineKind.allCases) { kind in
                        Button(kind.label) { add(kind) }
                    }
                }
                .fixedSize()
                Spacer()
                if let testResult {
                    Text(testResult).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Button(testing ? "Testing…" : "Test") { runTest() }
                    .disabled(testing)
            }
        } header: {
            Text(profile.language.displayName)
        } footer: {
            Text("Tried top to bottom. If an online engine is unreachable it's skipped for 10 minutes.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func replace(_ index: Int, with route: VoiceRoute) {
        var p = profile
        p.routes[index] = route
        settings.update(p)
    }

    private func move(_ index: Int, by delta: Int) {
        var p = profile
        let target = index + delta
        guard p.routes.indices.contains(target) else { return }
        p.routes.swapAt(index, target)
        settings.update(p)
    }

    private func remove(_ index: Int) {
        var p = profile
        guard p.routes.count > 1 else { return }
        p.routes.remove(at: index)
        settings.update(p)
    }

    private func add(_ kind: SpeechEngineKind) {
        var p = profile
        let fallback = ReadingSettings.defaultProfile(profile.language).routes.first { $0.engine == kind }
        p.routes.append(fallback ?? VoiceRoute(engine: kind, voiceID: ""))
        settings.update(p)
    }

    private func runTest() {
        testing = true
        testResult = nil
        Task {
            testResult = await state.narrator.test(profile.language)
            testing = false
        }
    }
}

private struct RouteRow: View {
    @EnvironmentObject var state: AppState
    let index: Int
    let route: VoiceRoute
    let language: ReadingLanguage
    let onChange: (VoiceRoute) -> Void
    let onMove: (Int) -> Void
    let onDelete: () -> Void
    let isFirst: Bool
    let isLast: Bool
    @State private var voices: [VoiceOption] = []

    var body: some View {
        HStack(spacing: 8) {
            Text("\(index + 1).").monospacedDigit().foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(route.engine.label).font(.callout)
                EngineHealthLabel(kind: route.engine, language: language)
            }
            Spacer()
            Picker("", selection: Binding(get: { route.voiceID },
                                          set: { onChange(VoiceRoute(engine: route.engine, voiceID: $0)) })) {
                if voices.isEmpty { Text(route.voiceID.isEmpty ? "Default" : route.voiceID).tag(route.voiceID) }
                ForEach(voices) { Text($0.name).tag($0.id) }
            }
            .labelsHidden()
            .frame(maxWidth: 210)
            Button { state.narrator.preview(route, language: language) } label: { Image(systemName: "play.circle") }
                .buttonStyle(.borderless).help("Preview this voice")
            Button { onMove(-1) } label: { Image(systemName: "chevron.up") }
                .buttonStyle(.borderless).disabled(isFirst)
            Button { onMove(1) } label: { Image(systemName: "chevron.down") }
                .buttonStyle(.borderless).disabled(isLast)
            Button(role: .destructive, action: onDelete) { Image(systemName: "xmark") }
                .buttonStyle(.borderless).disabled(isFirst && isLast)
        }
        .task(id: route.engine) {
            voices = await state.narrator.voices(route.engine, language: language)
        }
    }
}

/// A one-line status under an engine name: unsupported / not installed /
/// unreachable / ok.
private struct EngineHealthLabel: View {
    @EnvironmentObject var state: AppState
    let kind: SpeechEngineKind
    let language: ReadingLanguage

    var body: some View {
        let (text, color) = state.narrator.health(kind, language: language)
        if !text.isEmpty {
            Text(text).font(.caption2).foregroundStyle(color)
        }
    }
}

/// Languages offered in "Add language": anything at least one engine can speak,
/// in the region we have the best voices for.
enum LanguageCatalog {
    /// Supertonic 3's 31 languages ∪ the regions Edge has strong voices for.
    static let codes: [String] = [
        "en-US", "en-GB", "de-DE", "de-AT", "de-CH", "fr-FR", "es-ES", "it-IT", "pt-BR", "pt-PT",
        "nl-NL", "da-DK", "sv-SE", "fi-FI", "pl-PL", "cs-CZ", "sk-SK", "sl-SI", "hr-HR", "hu-HU",
        "ro-RO", "bg-BG", "el-GR", "et-EE", "lv-LV", "lt-LT", "ru-RU", "uk-UA", "tr-TR", "ar-SA",
        "hi-IN", "id-ID", "vi-VN", "ja-JP", "ko-KR",
    ]

    static func addable(excluding existing: [ReadingLanguage]) -> [ReadingLanguage] {
        codes.map(ReadingLanguage.init(code:))
            // Detection can't tell en-US from en-GB, so one region per language.
            .filter { lang in !existing.contains { $0.base == lang.base } }
            .sorted { $0.displayName < $1.displayName }
    }
}
