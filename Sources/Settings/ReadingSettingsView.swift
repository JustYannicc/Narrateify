import AVFoundation
import SwiftUI

/// Settings → Reading: which languages you read, and for each one the ordered
/// engine/voice chain to try (first that works wins). Observes the narrator
/// and settings only — not AppState, which republishes on every audio tick.
struct ReadingSettingsView: View {
    @ObservedObject var narrator: Narrator
    @ObservedObject var settings: ReadingSettings

    init(narrator: Narrator) {
        self.narrator = narrator
        self.settings = narrator.settings
    }

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
                    ForEach(LanguageCatalog.addable(excluding: settings.languages)) { lang in
                        Button(lang.displayName) { settings.addLanguage(lang) }
                    }
                }
            } header: {
                Text("Languages you read")
            } footer: {
                Text("Only these are detected. Anything else is read as whichever of them it's closest to. With one language, detection is skipped. Drag to reorder — the first is used when a snippet is too short to tell.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            ForEach($settings.profiles) { $profile in
                LanguageChainSection(profile: $profile, narrator: narrator)
            }

            Section("Speed & memory") {
                Toggle("Keep local models loaded", isOn: $settings.keepModelsWarm)
                Stepper("Unload after \(settings.unloadAfterMinutes) min idle",
                        value: $settings.unloadAfterMinutes, in: 1...120)
                Text(settings.keepModelsWarm
                     ? "Supertonic stays loaded (~120 MB) while it's the engine actually reading; as an unused fallback it unloads after the idle time."
                     : "Frees the memory between narrations; the first read after unloading takes a moment longer.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

/// One language's fallback chain.
private struct LanguageChainSection: View {
    @Binding var profile: LanguageProfile
    @ObservedObject var narrator: Narrator
    @State private var testResult: String?
    @State private var testing = false

    var body: some View {
        Section {
            ForEach(profile.routes.indices, id: \.self) { index in
                RouteRow(route: $profile.routes[index], index: index, count: profile.routes.count,
                         language: profile.language, narrator: narrator) { action in
                    perform(action, at: index)
                }
            }
            HStack {
                Menu("Add fallback") {
                    ForEach(SpeechEngineKind.allCases.filter { kind in
                        !profile.routes.contains { $0.engine == kind }
                    }) { kind in
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

    private func perform(_ action: RouteRow.Action, at index: Int) {
        switch action {
        case .moveUp where index > 0:
            profile.routes.swapAt(index, index - 1)
        case .moveDown where index < profile.routes.count - 1:
            profile.routes.swapAt(index, index + 1)
        case .delete where profile.routes.count > 1:
            profile.routes.remove(at: index)
        default:
            break
        }
    }

    /// New fallback with a working voice: the language default if there is
    /// one, else the engine's first voice for this language.
    private func add(_ kind: SpeechEngineKind) {
        let language = profile.language
        if let route = ReadingSettings.defaultProfile(language).routes.first(where: { $0.engine == kind }),
           !route.voiceID.isEmpty {
            profile.routes.append(route)
            return
        }
        profile.routes.append(VoiceRoute(engine: kind, voiceID: ""))
        let index = profile.routes.count - 1
        Task {
            guard let first = await narrator.voices(kind, language: language).first,
                  profile.routes.indices.contains(index), profile.routes[index].engine == kind,
                  profile.routes[index].voiceID.isEmpty else { return }
            profile.routes[index].voiceID = first.id
        }
    }

    private func runTest() {
        testing = true
        testResult = nil
        Task {
            testResult = await narrator.test(profile.language)
            testing = false
        }
    }
}

private struct RouteRow: View {
    enum Action { case moveUp, moveDown, delete }

    @Binding var route: VoiceRoute
    let index: Int
    let count: Int
    let language: ReadingLanguage
    @ObservedObject var narrator: Narrator
    let perform: (Action) -> Void
    @State private var voices: [VoiceOption] = []

    var body: some View {
        HStack(spacing: 8) {
            Text("\(index + 1).").monospacedDigit().foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(route.engine.label).font(.callout)
                HealthLabel(health: narrator.health(route.engine, language: language))
            }
            Spacer()
            Picker("", selection: $route.voiceID) {
                if !voices.contains(where: { $0.id == route.voiceID }) {
                    Text(VoiceNames.display(route)).tag(route.voiceID)
                }
                ForEach(voices) { Text($0.name).tag($0.id) }
            }
            .labelsHidden()
            .frame(maxWidth: 210)
            Button { narrator.preview(route, language: language) } label: { Image(systemName: "play.circle") }
                .buttonStyle(.borderless).help("Preview this voice")
            Button { perform(.moveUp) } label: { Image(systemName: "chevron.up") }
                .buttonStyle(.borderless).disabled(index == 0)
            Button { perform(.moveDown) } label: { Image(systemName: "chevron.down") }
                .buttonStyle(.borderless).disabled(index == count - 1)
            Button(role: .destructive) { perform(.delete) } label: { Image(systemName: "xmark") }
                .buttonStyle(.borderless).disabled(count == 1)
        }
        .task(id: route.engine) {
            voices = await narrator.voices(route.engine, language: language)
        }
    }
}

/// A one-line status under an engine name.
private struct HealthLabel: View {
    let health: EngineHealth

    var body: some View {
        switch health {
        case .ok: EmptyView()
        case .needsSetup(let text), .unsupported(let text):
            Text(text).font(.caption2).foregroundStyle(.orange)
        case .unreachable:
            Text("Unreachable — skipped for now").font(.caption2).foregroundStyle(.red)
        }
    }
}

/// Readable name for a saved voice before (or without) the engine's voice list.
enum VoiceNames {
    static func display(_ route: VoiceRoute) -> String {
        guard !route.voiceID.isEmpty else { return "Default" }
        switch route.engine {
        case .apple:
            return AVSpeechSynthesisVoice(identifier: route.voiceID).map { AppleSpeechEngine.option(for: $0).name }
                ?? route.voiceID
        case .edge:
            let locale = route.voiceID.split(separator: "-").prefix(2).joined(separator: "-")
            return EdgeVoice(shortName: route.voiceID, locale: locale).displayName
        case .supertonic:
            return SupertonicEngine.voices.first { $0.id == route.voiceID }?.name ?? route.voiceID
        case .elevenLabs, .openAI:
            return route.voiceID
        }
    }
}

/// Languages offered in "Add language": anything at least one engine can speak
/// (Supertonic's 31 plus the regions Edge has strong voices for), each in the
/// region from `ReadingSettings.preferredRegion` unless a region is listed.
enum LanguageCatalog {
    private static let all: [ReadingLanguage] = {
        let supertonicBases = ["ar", "bg", "hr", "cs", "da", "nl", "en", "et", "fi", "fr", "de", "el",
                               "hi", "hu", "id", "it", "ja", "ko", "lv", "lt", "pl", "pt", "ro", "ru",
                               "sk", "sl", "es", "sv", "tr", "uk", "vi"]
        let extraRegions = ["en-GB", "de-AT", "de-CH", "pt-PT", "zh-CN"]
        let primary = supertonicBases.map { ReadingSettings.preferredRegion[$0] ?? $0 }
        return (primary + extraRegions).map(ReadingLanguage.init(code:))
            .sorted { $0.displayName < $1.displayName }
    }()

    static func addable(excluding existing: [ReadingLanguage]) -> [ReadingLanguage] {
        // Detection can't tell en-US from en-GB, so one region per language.
        all.filter { lang in !existing.contains { $0.base == lang.base } }
    }
}
