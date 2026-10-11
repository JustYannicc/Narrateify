import SwiftUI
import Combine
import AppKit
import AVFoundation
import ServiceManagement

/// Single source of truth. Holds settings (persisted in UserDefaults) and
/// orchestrates: capture text -> clean -> `Narrator` (sections, language
/// routing, reader overlay).
@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    // MARK: Settings (persisted)
    @Published var apiKey: String {
        didSet { Keychain.set(apiKey, account: "elevenLabsAPIKey") }
    }
    @Published var voiceId: String {
        didSet { UserDefaults.standard.set(voiceId, forKey: "elevenLabsVoiceId") }
    }
    @Published var modelId: String {
        didSet { UserDefaults.standard.set(modelId, forKey: "elevenLabsModelId") }
    }
    @Published var stability: Double {
        didSet { UserDefaults.standard.set(stability, forKey: "elevenLabsStability") }
    }
    @Published var similarityBoost: Double {
        didSet { UserDefaults.standard.set(similarityBoost, forKey: "elevenLabsSimilarity") }
    }
    @Published var pricePerThousand: Double {
        didSet { UserDefaults.standard.set(pricePerThousand, forKey: "pricePerThousandCredits") }
    }
    /// Master switch for the floating overlay. When off, nothing floats.
    @Published var overlayEnabled: Bool {
        didSet {
            UserDefaults.standard.set(overlayEnabled, forKey: "overlayEnabled")
        }
    }
    /// Whether Narrateify launches automatically at login (macOS login item).
    @Published var launchAtLogin: Bool {
        didSet {
            guard launchAtLogin != oldValue else { return }
            do {
                if launchAtLogin { try SMAppService.mainApp.register() }
                else             { try SMAppService.mainApp.unregister() }
            } catch {
                status = "Login item error: \(error.localizedDescription)"
            }
        }
    }
    /// When on, newly copied clipboard text is narrated automatically.
    @Published var clipboardWatch: Bool {
        didSet {
            UserDefaults.standard.set(clipboardWatch, forKey: "clipboardWatch")
            clipboardWatch ? startClipboardWatch() : stopClipboardWatch()
        }
    }
    /// Optional monthly spend cap (USD) for cloud engines; 0 = no budget.
    @Published var monthlyBudget: Double {
        didSet { UserDefaults.standard.set(monthlyBudget, forKey: "monthlyBudget") }
    }
    /// Clean text before synthesis (strip markdown, expand abbreviations, tidy
    /// URLs) so voices stop reading literal `**` and raw links.
    @Published var cleanText: Bool {
        didSet { UserDefaults.standard.set(cleanText, forKey: "cleanText") }
    }
    /// User "say X as Y" pronunciation overrides, applied before synthesis.
    @Published var pronunciations: [PronunciationRule] {
        didSet {
            if let data = try? JSONEncoder().encode(pronunciations) {
                UserDefaults.standard.set(data, forKey: "pronunciations")
            }
        }
    }
    /// How aggressively to strip scientific-paper citation noise ([65], author-
    /// year, reference lists) before synthesis.
    @Published var citationMode: CitationCleanupMode {
        didSet { UserDefaults.standard.set(citationMode.rawValue, forKey: "citationMode") }
    }
    /// Show the recognized text in an editable window before narrating a
    /// screenshot, so OCR mistakes can be fixed first.
    @Published var reviewScreenshotText: Bool {
        didSet { UserDefaults.standard.set(reviewScreenshotText, forKey: "reviewScreenshotText") }
    }
    /// Translate captured text into `translateLanguage` before synthesis (uses
    /// the OpenAI key). Off by default — narration stays in the source language.
    @Published var translateEnabled: Bool {
        didSet { UserDefaults.standard.set(translateEnabled, forKey: "translateEnabled") }
    }
    /// Target language for the translate-before-narrate stage.
    @Published var translateLanguage: TranslationLanguage {
        didSet { UserDefaults.standard.set(translateLanguage.rawValue, forKey: "translateLanguage") }
    }
    /// Maximum number of history recordings to keep (0 = unlimited). Older
    /// recordings beyond this are pruned automatically.
    @Published var historyLimit: Int {
        didSet {
            UserDefaults.standard.set(historyLimit, forKey: "historyLimit")
            history.prune(maxItems: historyLimit)
        }
    }
    // OpenAI (cloud) settings.
    @Published var openAIKey: String {
        didSet { Keychain.set(openAIKey, account: "openAIKey") }
    }
    @Published var openAIVoice: String {
        didSet { UserDefaults.standard.set(openAIVoice, forKey: "openAIVoice") }
    }
    @Published var openAIModel: String {
        didSet { UserDefaults.standard.set(openAIModel, forKey: "openAIModel") }
    }

    // MARK: Runtime state
    @Published var status: String = "Ready"
    /// True while the reader waits on synthesis (drives the menu bar icon).
    var isSynthesizing: Bool { narrator.session?.isBuffering ?? false }
    /// A narration is on screen / playing.
    var isReading: Bool { narrator.isActive }
    /// True while a short voice preview is being fetched/synthesized.
    @Published private(set) var isPreviewing = false
    /// Whether the Settings window is currently on screen (drives the menu's
    /// "Settings (open)" affordance).
    @Published var settingsWindowOpen = false
    /// Pending reading-queue items (played back-to-back after the current one).
    @Published var queue: [QueueItem] = []
    /// When set, playback auto-pauses at this time (sleep timer).
    @Published private(set) var sleepTimerEnds: Date?
    /// Voices fetched from the ElevenLabs API (not persisted).
    @Published var voices: [ElevenLabsClient.Voice] = []
    @Published var voicesStatus: String = ""
    let audio = AudioController()
    let history = NarrationHistory()
    let supertonic = SupertonicModelStore()
    let supertonicEngine = SupertonicEngine()
    lazy var narrator: Narrator = makeNarrator()
    let shortcutStore = ShortcutStore()
    let updateChecker = UpdateChecker()

    private init() {
        let d = UserDefaults.standard
        // API keys live in the Keychain; transparently migrate any legacy
        // plaintext value stored in UserDefaults by older builds.
        apiKey  = Keychain.migratingValue(account: "elevenLabsAPIKey",
                                          legacyDefaultsKey: "elevenLabsAPIKey")
        voiceId = d.string(forKey: "elevenLabsVoiceId") ?? "21m00Tcm4TlvDq8ikWAM" // "Rachel" demo voice
        modelId = d.string(forKey: "elevenLabsModelId") ?? "eleven_multilingual_v2"
        stability       = d.object(forKey: "elevenLabsStability") as? Double ?? 0.5
        similarityBoost = d.object(forKey: "elevenLabsSimilarity") as? Double ?? 0.75
        pricePerThousand = d.object(forKey: "pricePerThousandCredits") as? Double ?? 0.30
        overlayEnabled    = d.object(forKey: "overlayEnabled") as? Bool ?? true
        // Reflect the real login-item state rather than a stored guess.
        launchAtLogin = (SMAppService.mainApp.status == .enabled)
        openAIKey   = Keychain.migratingValue(account: "openAIKey",
                                              legacyDefaultsKey: "openAIKey")
        openAIVoice = d.string(forKey: "openAIVoice") ?? "alloy"
        openAIModel = d.string(forKey: "openAIModel") ?? "gpt-4o-mini-tts"
        clipboardWatch = d.object(forKey: "clipboardWatch") as? Bool ?? false
        monthlyBudget = d.object(forKey: "monthlyBudget") as? Double ?? 0
        cleanText = d.object(forKey: "cleanText") as? Bool ?? true
        pronunciations = (d.data(forKey: "pronunciations"))
            .flatMap { try? JSONDecoder().decode([PronunciationRule].self, from: $0) } ?? []
        citationMode = CitationCleanupMode(rawValue: d.string(forKey: "citationMode") ?? "") ?? .smart
        reviewScreenshotText = d.object(forKey: "reviewScreenshotText") as? Bool ?? true
        translateEnabled = d.object(forKey: "translateEnabled") as? Bool ?? false
        translateLanguage = TranslationLanguage(rawValue: d.string(forKey: "translateLanguage") ?? "")
            ?? .english
        historyLimit = d.object(forKey: "historyLimit") as? Int ?? 0

        // Re-publish AppState when the audio controller's published state changes,
        // so the menu bar icon/status stay in sync — and keep the system
        // Now Playing info (media keys / Control Center) current.
        audio.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in
                guard let self else { return }
                self.objectWillChange.send()
                self.refreshNowPlaying()
            }
            .store(in: &cancellables)
        // Likewise for history changes (so the Settings list updates live).
        history.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &cancellables)
        // …and the narrator (reader session, engine health) + Supertonic model.
        for publisher in [narrator.objectWillChange.eraseToAnyPublisher(),
                          supertonic.objectWillChange.eraseToAnyPublisher()] {
            publisher.receive(on: RunLoop.main)
                .sink { [weak self] in self?.objectWillChange.send() }
                .store(in: &cancellables)
        }
        // …and the editable keyboard-shortcut bindings.
        shortcutStore.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &cancellables)
        // …and the GitHub update checker's result.
        updateChecker.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &cancellables)

        // Re-apply the local-model memory policy whenever Reading settings change.
        narrator.settings.objectWillChange
            .debounce(for: .milliseconds(300), scheduler: RunLoop.main)
            .sink { [weak self] in self?.applyModelMemoryPolicy() }
            .store(in: &cancellables)

        // Begin watching the clipboard if the user left it enabled.
        if clipboardWatch { startClipboardWatch() }

        // Advance the reading queue (and clear Now Playing) when reading ends.
        narrator.onFinished = { [weak self] in self?.handlePlaybackFinished() }

        // Hook the media keys / Control Center transport to playback.
        NowPlayingController.shared.activate(
            play:   { [weak self] in self?.togglePlayback(wantPlaying: true) },
            pause:  { [weak self] in self?.togglePlayback(wantPlaying: false) },
            toggle: { [weak self] in self?.togglePlayback() },
            skipBy: { [weak self] s in self?.skip(by: s) },
            seekTo: { [weak self] t in self?.audio.seek(to: t) }
        )
    }

    /// Title shown in the system Now Playing panel for the current narration.
    private func startNowPlaying(_ title: String) {
        NowPlayingController.shared.setTrack(title: title, duration: audio.duration)
    }

    private func refreshNowPlaying() {
        guard audio.hasAudio else { return }
        NowPlayingController.shared.updatePlayback(elapsed: audio.currentTime,
                                                   rate: audio.rate,
                                                   isPlaying: audio.isPlaying,
                                                   duration: audio.duration)
    }
    private var cancellables = Set<AnyCancellable>()

    private var voiceSettings: ElevenLabsClient.VoiceSettings {
        .init(stability: stability, similarityBoost: similarityBoost, speed: 1.0)
    }

    /// Preprocessor built from the current settings. Pronunciation rules always
    /// apply; the markdown/abbreviation/URL stages follow the `cleanText` toggle.
    var textPreprocessor: TextPreprocessor {
        TextPreprocessor(stripMarkdown: cleanText,
                         expandAbbreviations: cleanText,
                         simplifyURLs: cleanText,
                         citationMode: citationMode,
                         pronunciations: pronunciations)
    }

    // MARK: Triggers

    func narrateSelection() {
        status = "Reading selection…"
        // The selection grab copies (and restores) the clipboard; keep the
        // clipboard watcher from reacting to that.
        suppressClipboardWatch()
        TextCapture.selectedText { [weak self] text in
            guard let self else { return }
            let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !trimmed.isEmpty else {
                self.status = AXIsProcessTrusted()
                    ? "No text selected"
                    : "Grant Accessibility access in System Settings"
                return
            }
            self.narrate(trimmed)
        }
    }

    func narrateScreenshot() {
        status = "Select a region…"
        ScreenshotOCR.captureAndRecognize { [weak self] text in
            guard let self else { return }
            let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !trimmed.isEmpty else {
                self.status = "No text found (or capture cancelled)"
                return
            }
            // OCR is imperfect on dense papers — let the user review/fix the
            // cleaned text before it's spoken (unless they've opted out).
            if self.reviewScreenshotText {
                let cleaned = self.textPreprocessor.process(trimmed)
                self.status = "Review the recognized text"
                TextReviewWindow.shared.show(text: cleaned, title: "Review Screenshot Text")
            } else {
                self.narrate(trimmed)
            }
        }
    }

    func narrateClipboard() {
        let text = NSPasteboard.general.string(forType: .string)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !text.isEmpty else {
            status = "Clipboard has no text"
            return
        }
        narrate(text)
    }

    func stop() {
        narrator.stop()
        audio.stop()
        queue.removeAll()
        status = "Stopped"
        NowPlayingController.shared.clear()
    }

    /// Opens the Quick Narrate window (type/paste text → narrate).
    func showQuickNarrate() {
        QuickNarrateWindow.shared.show()
    }

    /// Fetch a web page's readable text and narrate it (queues if busy).
    func narrateURL(_ url: URL) {
        status = "Fetching \(url.host ?? "page")…"
        Task {
            do {
                let article = try await ArticleExtractor.fetch(url)
                self.enqueue(article.text, title: article.title)
            } catch {
                self.status = error.localizedDescription
            }
        }
    }

    /// A bare http(s) URL (no surrounding text), suitable for article fetching.
    nonisolated static func bareURL(in text: String) -> URL? {
        let s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.contains(where: { $0 == " " || $0 == "\n" || $0 == "\t" }),
              s.lowercased().hasPrefix("http://") || s.lowercased().hasPrefix("https://"),
              let url = URL(string: s), url.host != nil else { return nil }
        return url
    }

    // MARK: Reading queue

    /// Narrate text now if idle, otherwise add it to the queue.
    func enqueue(_ text: String, title: String? = nil) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if audio.hasAudio || isReading {
            queue.append(QueueItem(title: title ?? String(trimmed.prefix(50)), text: trimmed))
            status = "Queued — \(queue.count) waiting"
        } else {
            narrate(trimmed)
        }
    }

    func clearQueue() { queue.removeAll() }

    /// Remove a single queued item.
    func removeFromQueue(_ item: QueueItem) {
        queue.removeAll { $0.id == item.id }
    }

    /// Reorder queued items (driven by the menu's drag handles).
    func moveQueue(from offsets: IndexSet, to destination: Int) {
        queue.move(fromOffsets: offsets, toOffset: destination)
    }

    // MARK: Sleep timer

    private var sleepTimer: Timer?

    /// Auto-pause playback (and stop advancing the queue) after `minutes`.
    func startSleepTimer(minutes: Int) {
        cancelSleepTimer()
        guard minutes > 0 else { return }
        let ends = Date().addingTimeInterval(TimeInterval(minutes) * 60)
        sleepTimerEnds = ends
        let t = Timer(timeInterval: TimeInterval(minutes) * 60, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.fireSleepTimer() }
        }
        RunLoop.main.add(t, forMode: .common)
        sleepTimer = t
    }

    func cancelSleepTimer() {
        sleepTimer?.invalidate()
        sleepTimer = nil
        sleepTimerEnds = nil
    }

    private func fireSleepTimer() {
        sleepTimer = nil
        sleepTimerEnds = nil
        queue.removeAll()      // don't roll into the next queued item
        audio.pause()
        if narrator.session?.isPlaying == true { narrator.togglePlayPause() }
        status = "Paused by sleep timer"
    }

    private func playNextInQueue() {
        guard !queue.isEmpty else { return }
        let next = queue.removeFirst()
        narrate(next.text)
    }

    private func handlePlaybackFinished() {
        if queue.isEmpty {
            NowPlayingController.shared.clear()
        } else {
            playNextInQueue()
        }
    }

    /// Prompts for one or more documents (PDF/txt/rtf/md), extracts their text,
    /// and narrates / queues them.
    func narrateFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = FileTextExtractor.allowedTypes
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK else { return }

        var added = 0
        var failed: [String] = []
        for url in panel.urls {
            if let text = FileTextExtractor.extract(from: url)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                enqueue(text, title: url.lastPathComponent)
                added += 1
            } else {
                failed.append(url.lastPathComponent)
            }
        }
        if added == 0 && !failed.isEmpty {
            status = "Couldn't read text from \(failed.joined(separator: ", "))"
        } else if !failed.isEmpty {
            status = "Skipped \(failed.count) unreadable file(s)"
        }
    }

    // MARK: Clipboard watch

    private var clipboardTimer: Timer?
    private var lastClipboardChange = NSPasteboard.general.changeCount
    private var lastClipboardText = ""
    /// Programmatic pasteboard use (e.g. the selection grab) sets this so the
    /// watcher ignores the resulting changes.
    private var suppressClipboardUntil = Date.distantPast

    private func suppressClipboardWatch(for seconds: TimeInterval = 1.5) {
        suppressClipboardUntil = Date().addingTimeInterval(seconds)
    }

    private var powerObserver: NSObjectProtocol?

    private func startClipboardWatch() {
        // Suspend the poll loop in Low Power Mode to save battery; resume when it
        // turns off. (Observe the power-state change once.)
        if powerObserver == nil {
            powerObserver = NotificationCenter.default.addObserver(
                forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.reconcileClipboardWatch() }
            }
        }
        reconcileClipboardWatch()
    }

    private func stopClipboardWatch() {
        clipboardTimer?.invalidate()
        clipboardTimer = nil
        if let powerObserver {
            NotificationCenter.default.removeObserver(powerObserver)
            self.powerObserver = nil
        }
    }

    /// Start/stop the poll loop to match the watch setting and power state.
    private func reconcileClipboardWatch() {
        guard clipboardWatch else {
            clipboardTimer?.invalidate(); clipboardTimer = nil
            return
        }
        if ProcessInfo.processInfo.isLowPowerModeEnabled {
            clipboardTimer?.invalidate(); clipboardTimer = nil
            status = "Clipboard watch paused (Low Power Mode)"
            return
        }
        guard clipboardTimer == nil else { return }
        lastClipboardChange = NSPasteboard.general.changeCount
        let t = Timer(timeInterval: 0.6, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkClipboard() }
        }
        RunLoop.main.add(t, forMode: .common)
        clipboardTimer = t
        status = "Watching clipboard…"
    }

    private func checkClipboard() {
        let pb = NSPasteboard.general
        guard pb.changeCount != lastClipboardChange else { return }
        lastClipboardChange = pb.changeCount
        // Skip our own pipeline activity and the selection-copy round-trip.
        guard !isReading, Date() >= suppressClipboardUntil else { return }
        let text = pb.string(forType: .string)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !text.isEmpty, text != lastClipboardText else { return }
        lastClipboardText = text
        narrate(text)
    }

    // MARK: Voices

    func refreshVoices() {
        let key = apiKey
        guard !key.isEmpty else {
            voicesStatus = "Enter your API key first."
            return
        }
        voicesStatus = "Loading voices…"
        Task {
            do {
                let fetched = try await ElevenLabsClient.fetchVoices(apiKey: key)
                self.voices = fetched.sorted { $0.name.lowercased() < $1.name.lowercased() }
                self.voicesStatus = "\(fetched.count) voices loaded"
            } catch {
                self.voicesStatus = error.localizedDescription
            }
        }
    }

    // MARK: Voice preview

    /// Plays a short sample of the currently-selected voice so the user can
    /// audition it before narrating. Uses ElevenLabs' free hosted preview when
    /// available; otherwise synthesizes a brief sample with the active engine.
    /// Previews are NOT saved to history.
    /// The fixed sentence spoken by all voice previews.
    static let previewSample = "Hi! This is a quick preview of how this voice sounds."

    /// Audition a specific ElevenLabs voice without changing the selection.
    /// Uses the free hosted preview when available; otherwise synthesizes.
    func auditionElevenLabs(_ voice: ElevenLabsClient.Voice) {
        guard !isPreviewing else { return }
        isPreviewing = true
        status = "Previewing \(voice.name)…"
        Task {
            do {
                let data: Data
                if let preview = voice.previewURL {
                    (data, _) = try await URLSession.shared.data(from: preview)
                } else {
                    let client = ElevenLabsClient(apiKey: apiKey, voiceId: voice.voiceId,
                                                  modelId: modelId, settings: voiceSettings)
                    data = try await client.synthesize(text: Self.previewSample)
                }
                self.audio.load(data: data)
                self.status = "Voice preview"
                self.startNowPlaying("Voice preview")
            } catch {
                self.status = error.localizedDescription
            }
            self.isPreviewing = false
        }
    }

    // MARK: History playback

    /// Re-play a previously saved narration from history.
    func play(_ record: NarrationRecord) {
        narrator.stop()
        audio.load(url: history.fileURL(for: record))
        status = "Playing"
        startNowPlaying(record.preview.isEmpty ? "Narration" : record.preview)
    }

    func delete(_ record: NarrationRecord) {
        history.delete(record)
    }

    // MARK: Transport

    /// Play/pause whatever is active: the reader, else a History recording.
    func togglePlayback(wantPlaying: Bool? = nil) {
        if let session = narrator.session {
            if wantPlaying == nil || wantPlaying != session.isPlaying { session.togglePlayPause() }
        } else if audio.hasAudio {
            switch wantPlaying {
            case true?: audio.play()
            case false?: audio.pause()
            case nil: audio.togglePlayPause()
            }
        }
    }

    /// Media-key skip: section-wise in the reader, seconds in a recording.
    func skip(by seconds: TimeInterval) {
        if let session = narrator.session {
            seconds < 0 ? session.previous() : session.next()
        } else {
            audio.skip(by: seconds)
        }
    }

    func resetOverlayPosition() {
        ReaderOverlayController.shared.resetPosition()
    }

    // MARK: Engines

    /// Launch-time warm-up so the first shortcut press reads immediately.
    func warmUpEngines() {
        Task { await EdgeVoiceCatalog.shared.refresh() }
        applyModelMemoryPolicy()
    }

    /// Keep Supertonic resident, or let it unload after the idle timeout.
    func applyModelMemoryPolicy() {
        let settings = narrator.settings
        supertonicEngine.idleUnloadAfter = settings.keepModelsWarm ? nil
            : TimeInterval(settings.unloadAfterMinutes * 60)
        let usesSupertonic = settings.profiles.contains { $0.routes.contains { $0.engine == .supertonic } }
        if settings.keepModelsWarm, usesSupertonic, supertonic.isInstalled, !supertonicEngine.isLoaded {
            Task { try? await supertonicEngine.preload() }
        }
    }

    // MARK: Pipeline

    private func makeNarrator() -> Narrator {
        let narrator = Narrator(engines: [
            EdgeTTSEngine(),
            supertonicEngine,
            AppleSpeechEngine(),
            ElevenLabsSpeechEngine { [unowned self] in
                .init(apiKey: apiKey, modelId: modelId, settings: voiceSettings, voices: voices)
            },
            OpenAISpeechEngine { [unowned self] in .init(apiKey: openAIKey, model: openAIModel) },
        ])
        narrator.onStatus = { [weak self] in self?.status = $0 }
        narrator.saveToHistory = { [weak self] text, audio, routes, characters in
            self?.saveNarration(text: text, audio: audio, routes: routes, characters: characters)
        }
        return narrator
    }

    func narrate(_ text: String) {
        // Remember the raw text so the clipboard watcher won't repeat it, then
        // clean it (markdown/URLs/abbreviations + pronunciation rules).
        lastClipboardText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let spoken = textPreprocessor.process(text)
        guard !spoken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        audio.stop()

        guard translateEnabled else {
            narrator.read(spoken, showOverlay: overlayEnabled)
            startNowPlaying(String(spoken.prefix(80)))
            return
        }
        status = "Translating…"
        Task {
            do {
                let translated = try await Translator(apiKey: openAIKey, target: translateLanguage).translate(spoken)
                narrator.read(translated, showOverlay: overlayEnabled)
                startNowPlaying(String(translated.prefix(80)))
            } catch {
                status = error.localizedDescription
            }
        }
    }

    /// Store a finished narration. Engines can differ per section, so History
    /// records the one that read most of it; cloud cost is summed per section.
    private func saveNarration(text: String, audio: Data, routes: [VoiceRoute], characters: [Int]) {
        var credits = 0.0, cost = 0.0
        var share: [SpeechEngineKind: Int] = [:]
        for (route, chars) in zip(routes, characters) {
            share[route.engine, default: 0] += chars
            switch route.engine {
            case .elevenLabs:
                let c = Pricing.credits(characters: chars, modelId: modelId)
                credits += c
                cost += Pricing.cost(credits: c, pricePerThousand: pricePerThousand)
            case .openAI:
                cost += Double(chars) / 1000 * OpenAIClient.pricePerThousand(model: openAIModel)
            default:
                break
            }
        }
        guard let main = share.max(by: { $0.value < $1.value })?.key,
              let route = routes.first(where: { $0.engine == main }) else { return }
        do {
            _ = try history.save(audio: audio, text: text, engine: main.engineName,
                                 voiceId: route.voiceID, voiceName: route.voiceID,
                                 modelId: main.rawValue, credits: credits,
                                 estimatedCost: cost, fileExtension: "m4a")
            history.prune(maxItems: historyLimit)
        } catch {
            status = "Couldn't save to History: \(error.localizedDescription)"
        }
    }
}
