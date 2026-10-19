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
    /// A narration is on screen / playing.
    var isReading: Bool { narrator.isActive }
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
        // …and every other model object the menu/Settings render from.
        let children: [AnyPublisher<Void, Never>] = [
            history.objectWillChange.eraseToAnyPublisher(),
            narrator.objectWillChange.eraseToAnyPublisher(),
            supertonic.objectWillChange.eraseToAnyPublisher(),
            shortcutStore.objectWillChange.eraseToAnyPublisher(),
            updateChecker.objectWillChange.eraseToAnyPublisher(),
        ]
        for publisher in children {
            publisher.receive(on: RunLoop.main)
                .sink { [weak self] in self?.objectWillChange.send() }
                .store(in: &cancellables)
        }

        supertonic.$installedBackend
            .removeDuplicates()
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.supertonicInstallChanged() }
            .store(in: &cancellables)

        // Re-apply the local-model memory policy whenever Reading settings change.
        narrator.settings.objectWillChange
            .debounce(for: .milliseconds(300), scheduler: RunLoop.main)
            .sink { [weak self] in self?.applyModelMemoryPolicy() }
            .store(in: &cancellables)

        // Begin watching the clipboard if the user left it enabled.
        if clipboardWatch { startClipboardWatch() }

        // Advance the reading queue (and clear Now Playing) when reading or a
        // History recording ends.
        narrator.onFinished = { [weak self] in self?.handlePlaybackFinished() }
        audio.onFinished = { [weak self] in self?.handlePlaybackFinished() }
        // The reader's close button behaves like Stop (clears the queue too).
        ReaderOverlayController.shared.onClose = { [weak self] in self?.stop() }

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
        narrator.prewarmEngines()   // overlaps text capture
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
        narrator.prewarmEngines()   // overlaps text capture
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
        narrator.prewarmEngines()   // overlaps text capture
        let text = NSPasteboard.general.string(forType: .string)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !text.isEmpty else {
            status = "Clipboard has no text"
            return
        }
        narrate(text)
    }

    func stop() {
        translationTask?.cancel()
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
        if audio.isPlaying || isReading || translationTask != nil {
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
        togglePlayback(wantPlaying: false)
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
        Task { await loadVoices(force: true) }
    }

    /// Fetch the ElevenLabs voice list into `voices` (also used when a
    /// language is switched to ElevenLabs before the Cloud tab loaded them).
    /// Concurrent callers share one request; without `force`, a key that
    /// already failed isn't retried (every voice row asks on appear).
    @discardableResult
    func loadVoices(force: Bool = false) async -> [ElevenLabsClient.Voice] {
        let key = apiKey
        guard !key.isEmpty, force || voicesFailedKey != key else { return voices }
        if let voicesLoad { return await voicesLoad.value }
        voicesStatus = "Loading voices…"
        let load = Task { () -> [ElevenLabsClient.Voice] in
            do {
                let fetched = try await ElevenLabsClient.fetchVoices(apiKey: key)
                voices = fetched.sorted { $0.name.lowercased() < $1.name.lowercased() }
                voicesStatus = "\(fetched.count) voices loaded"
                voicesFailedKey = nil
            } catch {
                voicesStatus = error.localizedDescription
                voicesFailedKey = key
            }
            return voices
        }
        voicesLoad = load
        defer { voicesLoad = nil }
        return await load.value
    }
    private var voicesLoad: Task<[ElevenLabsClient.Voice], Never>?
    private var voicesFailedKey: String?

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

    func nextSection() { narrator.session?.next() }
    func previousSection() { narrator.session?.previous() }
    func readFaster() { narrator.session?.faster() }
    func readSlower() { narrator.session?.slower() }

    func resetOverlayPosition() {
        ReaderOverlayController.shared.resetPosition()
    }

    // MARK: Engines

    /// Launch-time warm-up so the first shortcut press reads immediately.
    func warmUpEngines() {
        Task { await EdgeVoiceCatalog.shared.refresh() }
        // Existing ONNX installs move to the much faster Core ML decoder in the
        // background; ONNX keeps reading meanwhile.
        if supertonic.upgradeAvailable { supertonic.upgrade() }
        applyModelMemoryPolicy()
        narrator.prewarm()
    }

    /// After an upgrade lands, drop the ONNX runtime so the next read loads
    /// Core ML (~0.4 s), then re-apply the preload policy.
    private func supertonicInstallChanged() {
        // Removed, or upgraded past what's loaded → drop the runtime.
        if let loaded = supertonicEngine.loadedBackend, loaded != supertonic.installedBackend {
            supertonicEngine.unload()
        }
        applyModelMemoryPolicy()
    }

    /// Keep Supertonic resident while it's actually reading something (first
    /// usable engine for a language — e.g. Edge is down or has no voice);
    /// otherwise let it unload after the idle timeout, even if a fallback,
    /// test or benchmark loaded it.
    func applyModelMemoryPolicy() {
        let settings = narrator.settings
        let needed = narrator.isEngineNeeded(.supertonic)
        let keepWarm = settings.keepModelsWarm && needed
        supertonicEngine.idleUnloadAfter = keepWarm ? nil : TimeInterval(settings.unloadAfterMinutes * 60)
        if keepWarm, supertonic.isInstalled, !supertonicEngine.isLoaded {
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
                .init(apiKey: apiKey, modelId: modelId, settings: voiceSettings, voices: voices,
                      defaultVoice: voiceId, loadVoices: { [unowned self] in await self.loadVoices() })
            },
            OpenAISpeechEngine { [unowned self] in
                .init(apiKey: openAIKey, model: openAIModel, defaultVoice: openAIVoice)
            },
        ])
        narrator.onStatus = { [weak self] in self?.status = $0 }
        // Edge just went down → warm Supertonic now so later sections are fast.
        narrator.onEngineHealthChange = { [weak self] in self?.applyModelMemoryPolicy() }
        narrator.saveToHistory = { [weak self] in self?.saveNarration($0) }
        return narrator
    }

    private var translationTask: Task<Void, Never>?

    /// `choice` (local API) pins engine/voice/language and skips translation;
    /// `preprocessed` means the caller already cleaned (or chose not to).
    func narrate(_ text: String, choice: VoiceChoice? = nil, preprocessed: Bool = false) {
        // Remember the raw text so the clipboard watcher won't repeat it, then
        // clean it (markdown/URLs/abbreviations + pronunciation rules).
        lastClipboardText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let spoken = preprocessed ? text : textPreprocessor.process(text)
        guard !spoken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        audio.stop()
        translationTask?.cancel()
        translationTask = nil

        guard translateEnabled, choice == nil else {
            narrator.read(spoken, choice: choice, showOverlay: overlayEnabled)
            startNowPlaying(String(spoken.prefix(80)))
            return
        }
        narrator.stop()
        status = "Translating…"
        let target = translationTarget
        translationTask = Task {
            defer { translationTask = nil }
            do {
                let translated = try await Translator(apiKey: openAIKey, target: translateLanguage).translate(spoken)
                // A newer narration or Stop superseded this one.
                guard !Task.isCancelled else { return }
                narrator.read(translated, language: target, showOverlay: overlayEnabled)
                startNowPlaying(String(translated.prefix(80)))
            } catch {
                if !Task.isCancelled { status = error.localizedDescription }
            }
        }
    }

    /// The translation's language is known, so it's read with that language's
    /// chain (one of the user's languages if it matches, else a default one).
    private var translationTarget: ReadingLanguage {
        let base = translateLanguage.rawValue
        return narrator.settings.languages.first { $0.base == base }
            ?? ReadingLanguage(code: ReadingSettings.preferredRegion[base] ?? base)
    }

    /// Store a finished narration. Engines can differ per section, so History
    /// records the one that read most of it; cloud cost is summed per section.
    private func saveNarration(_ summary: NarrationSummary) {
        var credits = 0.0, cost = 0.0
        var share: [SpeechEngineKind: Int] = [:]
        for (route, chars) in summary.parts {
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
              let route = summary.parts.first(where: { $0.route.engine == main })?.route else { return }
        let model: String
        switch main {
        case .elevenLabs: model = modelId
        case .openAI: model = openAIModel
        default: model = main.rawValue
        }
        do {
            _ = try history.save(audio: summary.audio, text: summary.text, engine: main.engineName,
                                 voiceId: route.voiceID, voiceName: VoiceNames.display(route),
                                 modelId: model, credits: credits,
                                 estimatedCost: cost, fileExtension: "m4a")
            history.prune(maxItems: historyLimit)
        } catch {
            status = "Couldn't save to History: \(error.localizedDescription)"
        }
    }
}
