import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        TabView {
            ReadingSettingsView(narrator: state.narrator)
                .tabItem { Label("Reading", systemImage: "character.bubble") }
            EnginesView()
                .tabItem { Label("Engines", systemImage: "waveform") }
            CloudView()
                .tabItem { Label("Cloud", systemImage: "cloud") }
            GeneralView()
                .tabItem { Label("General", systemImage: "gearshape") }
            HistoryView()
                .tabItem { Label("History", systemImage: "clock") }
        }
        .frame(width: 620, height: 600)
        .onAppear {
            state.supertonic.refresh()
            state.settingsWindowOpen = true
        }
        .onDisappear { state.settingsWindowOpen = false }
    }
}

// MARK: - Cloud (optional paid engines: keys + model choice)

struct CloudView: View {
    @EnvironmentObject var state: AppState

    private let elevenModels: [(id: String, label: String)] = [
        ("eleven_multilingual_v2", "Multilingual v2 — best quality"),
        ("eleven_flash_v2_5",      "Flash v2.5 — lowest latency"),
        ("eleven_v3",              "v3 — most expressive")
    ]

    var body: some View {
        Form {
            Section {
                Text("Optional. Add a key, then put the engine into a language's chain under Reading. Voices are picked there.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("ElevenLabs") {
                SecureField("API Key", text: $state.apiKey)
                HStack {
                    Button("Load voices") { state.refreshVoices() }
                        .disabled(state.apiKey.isEmpty)
                    if !state.voicesStatus.isEmpty {
                        Text(state.voicesStatus).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Picker("Model", selection: $state.modelId) {
                    ForEach(elevenModels, id: \.id) { Text($0.label).tag($0.id) }
                }
                slider("Stability", value: $state.stability, range: 0...1)
                slider("Similarity", value: $state.similarityBoost, range: 0...1)
                HStack {
                    Text("Price per 1,000 credits")
                    Spacer()
                    TextField("", value: $state.pricePerThousand, format: .currency(code: "USD"))
                        .multilineTextAlignment(.trailing)
                        .frame(width: 90)
                }
            }
            Section("OpenAI") {
                SecureField("API Key", text: $state.openAIKey)
                Picker("Model", selection: $state.openAIModel) {
                    ForEach(OpenAIClient.models, id: \.id) { Text($0.label).tag($0.id) }
                }
                Text(String(format: "≈ $%.3f per 1,000 characters. The key is also used for Translation.",
                            OpenAIClient.pricePerThousand(model: state.openAIModel)))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func slider(_ label: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label)
                Spacer()
                Text(String(format: "%.2f", value.wrappedValue)).foregroundStyle(.secondary).monospacedDigit()
            }
            Slider(value: value, in: range)
        }
    }
}

// MARK: - General (app behavior: overlay + shortcuts)

struct GeneralView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        Form {
            Section("Startup") {
                Toggle("Launch Narrateify at login", isOn: $state.launchAtLogin)
            }

            Section("Text") {
                Toggle("Clean text before speaking", isOn: $state.cleanText)
                Text("Strips markdown (**, #, links), reads URLs as just their host, "
                     + "and expands abbreviations like “e.g.” and “i.e.” so they're "
                     + "spoken naturally.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Picker("Academic citation cleanup", selection: $state.citationMode) {
                    ForEach(CitationCleanupMode.allCases) { Text($0.label).tag($0) }
                }
                Text("For scientific papers. Smart removes in-text citations like "
                     + "“[65]”, re-joins hyphenated line breaks, and expands Fig./Eq. "
                     + "Aggressive also strips “(Author, 2020)” citations, reads "
                     + "“et al.” aloud, and trims a trailing References section.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Translation") {
                Toggle("Translate before narrating", isOn: $state.translateEnabled)
                Picker("Into", selection: $state.translateLanguage) {
                    ForEach(TranslationLanguage.allCases) { Text($0.label).tag($0) }
                }
                .disabled(!state.translateEnabled)
                Text("Translates captured text — selected text or a screenshot — into "
                     + "the chosen language before it's spoken, so you can listen in a "
                     + "different language than the source. Uses your OpenAI key "
                     + "(Settings → Cloud); a few cents per long article. Pick a target "
                     + "that's one of your reading languages so it gets the right voice.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Screenshot") {
                Toggle("Review recognized text before narrating",
                       isOn: $state.reviewScreenshotText)
                Text("After capturing a region, show the recognized and cleaned text "
                     + "in an editable window so you can fix OCR mistakes before it's "
                     + "spoken. Multi-column papers are reconstructed into reading "
                     + "order automatically. Recommended for dense documents.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Pronunciations") {
                PronunciationEditor()
            }

            Section("Clipboard") {
                Toggle("Auto-narrate newly copied text", isOn: $state.clipboardWatch)
                Text("When on, Narrateify watches the clipboard and reads anything "
                     + "you copy. It pauses while narrating, skips repeats, and "
                     + "suspends itself in Low Power Mode. Turn off to use the ⌃⌥V "
                     + "hotkey on demand instead.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Reader") {
                Toggle("Show the reader while reading", isOn: $state.overlayEnabled)
                HStack {
                    Text("Shows the text with the current word highlighted; ←/→ jump by section. Drag it anywhere.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Reset Position") { state.resetOverlayPosition() }
                }
            }

            Section("Storage") {
                Picker("Keep at most", selection: $state.historyLimit) {
                    Text("Unlimited").tag(0)
                    Text("50 recordings").tag(50)
                    Text("100 recordings").tag(100)
                    Text("250 recordings").tag(250)
                    Text("500 recordings").tag(500)
                }
                Text("Older recordings beyond this limit are removed automatically to "
                     + "keep History tidy.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Shortcuts") {
                ShortcutsSettingsView()
            }

            UsageSection()

            Section("About & Updates") {
                LabeledContent("Version", value: state.updateChecker.currentVersion)

                HStack {
                    updateStatusView
                    Spacer()
                    Button("Check Now") {
                        Task { await state.updateChecker.check() }
                    }
                    .disabled(state.updateChecker.state == .checking)
                }

                Link(destination: UpdateChecker.releasesURL) {
                    Label("View releases on GitHub", systemImage: "arrow.up.right.square")
                        .font(.caption)
                }
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private var updateStatusView: some View {
        switch state.updateChecker.state {
        case .idle:
            Text("Not checked yet").foregroundStyle(.secondary)
        case .checking:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Checking…").foregroundStyle(.secondary)
            }
        case .upToDate:
            Label("You're up to date", systemImage: "checkmark.circle")
                .foregroundStyle(.green)
        case .available(let version, let url, let download):
            VStack(alignment: .leading, spacing: 6) {
                Link(destination: url) {
                    Label("Update available: \(version)", systemImage: "arrow.down.circle.fill")
                        .foregroundStyle(.blue)
                }
                if download != nil {
                    Button {
                        Task { await state.updateChecker.downloadAndOpen() }
                    } label: {
                        if state.updateChecker.isDownloading {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text("Downloading…")
                            }
                        } else {
                            Label("Download & Install", systemImage: "square.and.arrow.down")
                        }
                    }
                    .disabled(state.updateChecker.isDownloading)
                }
            }
        case .failed(let message):
            Label("Check failed: \(message)", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
                .font(.caption)
        }
    }
}

// MARK: - Pronunciation rules editor

/// Lets the user add "say X as Y" overrides applied before synthesis.
struct PronunciationEditor: View {
    @EnvironmentObject var state: AppState
    @State private var from = ""
    @State private var to = ""

    var body: some View {
        if state.pronunciations.isEmpty {
            Text("No rules yet. Add one to fix names or acronyms a voice mispronounces "
                 + "(e.g. say “Narrateify” as “Narrate-i-fy”).")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        ForEach($state.pronunciations) { $rule in
            HStack(spacing: 6) {
                TextField("Say", text: $rule.from)
                Image(systemName: "arrow.right").foregroundStyle(.secondary)
                TextField("as", text: $rule.to)
                Toggle("Whole word", isOn: $rule.wholeWord)
                    .labelsHidden()
                    .help("Match whole words only")
                Button(role: .destructive) {
                    state.pronunciations.removeAll { $0.id == rule.id }
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
            }
        }

        HStack(spacing: 6) {
            TextField("Say", text: $from)
            Image(systemName: "arrow.right").foregroundStyle(.secondary)
            TextField("as", text: $to)
            Button {
                let f = from.trimmingCharacters(in: .whitespacesAndNewlines)
                let t = to.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !f.isEmpty, !t.isEmpty else { return }
                state.pronunciations.append(PronunciationRule(from: f, to: t))
                from = ""; to = ""
            } label: {
                Label("Add", systemImage: "plus.circle.fill")
            }
            .buttonStyle(.borderless)
        }
    }
}

// History lives in HistoryView.swift.
