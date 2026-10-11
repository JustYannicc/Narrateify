import Foundation

/// Denoising steps per utterance. More steps = cleaner audio, linearly slower.
enum SupertonicQuality: Int, CaseIterable, Codable, Identifiable {
    case fastest = 2
    case fast = 3
    case balanced = 5
    case best = 8

    var id: Int { rawValue }
    var steps: Int { rawValue }

    var label: String {
        switch self {
        case .fastest:  return "Fastest (2 steps)"
        case .fast:     return "Fast (3 steps)"
        case .balanced: return "Balanced (5 steps)"
        case .best:     return "Best (8 steps)"
        }
    }

    static let `default`: SupertonicQuality = .balanced
}

/// Local Supertonic 3 TTS via ONNX Runtime. Models load lazily on the first
/// `synthesize` (or `preload()`) and stay warm until `unload()` or the optional
/// idle timeout. All inference runs serially on a private background queue.
final class SupertonicEngine: SpeechEngine, @unchecked Sendable {
    let kind: SpeechEngineKind = .supertonic

    /// The ten preset voices, named after Supertone's own descriptions. v3
    /// styles carry no language (the language is a per-call text tag), so each
    /// voice speaks all 31 languages.
    static let voices: [VoiceOption] = [
        ("F1", "Calm"), ("F2", "Bright"), ("F3", "Announcer"), ("F4", "Crisp"), ("F5", "Gentle"),
        ("M1", "Lively"), ("M2", "Deep"), ("M3", "Authoritative"), ("M4", "Soft"), ("M5", "Warm"),
    ].map { id, trait in
        VoiceOption(id: id, name: "\(trait) \(id.hasPrefix("F") ? "female" : "male") (\(id))", languages: ["*"])
    }
    static let defaultVoiceID = "F1"

    let modelDirectory: URL
    private let queue = DispatchQueue(label: "Narrateify.Supertonic", qos: .userInitiated)
    private let lock = NSLock()
    private var _quality: SupertonicQuality
    private var _idleUnloadAfter: TimeInterval?
    private var _isLoaded = false

    // Queue-confined state.
    private var runtime: SupertonicRuntime?
    private var styles: [String: SupertonicStyle] = [:]
    private var idleTimer: DispatchWorkItem?

    init(modelDirectory: URL = SupertonicModelStore.defaultDirectory,
         quality: SupertonicQuality = .default,
         idleUnloadAfter: TimeInterval? = nil) {
        self.modelDirectory = modelDirectory
        _quality = quality
        _idleUnloadAfter = idleUnloadAfter
    }

    /// Denoising steps used by subsequent calls. Safe to change from any thread.
    var quality: SupertonicQuality {
        get { lock.withLock { _quality } }
        set { lock.withLock { _quality = newValue } }
    }

    /// Drop the models after this many idle seconds (nil = keep warm forever).
    var idleUnloadAfter: TimeInterval? {
        get { lock.withLock { _idleUnloadAfter } }
        set {
            lock.withLock { _idleUnloadAfter = newValue }
            queue.async { self.scheduleIdleUnload() }
        }
    }

    /// Whether the ONNX sessions are currently in memory.
    var isLoaded: Bool { lock.withLock { _isLoaded } }

    // MARK: SpeechEngine

    func supports(_ language: ReadingLanguage) -> Bool {
        SupertonicText.languageSet.contains(language.base)
    }

    func voices(for language: ReadingLanguage) async -> [VoiceOption] {
        supports(language) ? Self.voices : []
    }

    func synthesize(_ text: String, language: ReadingLanguage, voiceID: String) async throws -> SynthesizedSpeech {
        guard supports(language) else {
            throw SpeechEngineError.unsupportedLanguage("Supertonic 3 doesn't support \(language.code)")
        }
        let steps = quality.steps
        let voice = Self.voices.contains { $0.id == voiceID } ? voiceID : Self.defaultVoiceID
        return try await onQueue {
            let runtime = try self.loadedRuntime()
            let style = try self.style(voice, runtime: runtime)
            let samples = try runtime.synthesize(text, lang: language.base, style: style, steps: steps)
            guard !samples.isEmpty else { throw SpeechEngineError.synthesisFailed("Empty audio") }
            return SynthesizedSpeech(audio: WAVEncoder.encode(samples, sampleRate: runtime.sampleRate),
                                     fileExtension: "wav", words: [])
        }
    }

    // MARK: Lifecycle

    /// Load the ONNX sessions now (e.g. right after install or at launch) so
    /// the first shortcut press doesn't pay the cold-load cost.
    func preload() async throws {
        try await onQueue { _ = try self.loadedRuntime() }
    }

    /// Free the models' memory. The next synthesize reloads them.
    func unload() {
        queue.async { self.unloadNow() }
    }

    private func onQueue<T>(_ work: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { cont in
            queue.async {
                self.idleTimer?.cancel()
                let result = Result { try autoreleasepool { try work() } }
                self.scheduleIdleUnload()
                cont.resume(with: result)
            }
        }
    }

    private func loadedRuntime() throws -> SupertonicRuntime {
        if let runtime { return runtime }
        do {
            let loaded = try SupertonicRuntime(directory: modelDirectory)
            runtime = loaded
            lock.withLock { _isLoaded = true }
            return loaded
        } catch let error as SpeechEngineError {
            throw error
        } catch {
            throw SpeechEngineError.notInstalled("Couldn't load Supertonic 3: \(error.localizedDescription)")
        }
    }

    private func style(_ id: String, runtime: SupertonicRuntime) throws -> SupertonicStyle {
        if let cached = styles[id] { return cached }
        let url = modelDirectory.appendingPathComponent(SupertonicFiles.voiceStyle(id))
        do {
            let style = try runtime.loadStyle(url)
            styles[id] = style
            return style
        } catch let error as SpeechEngineError {
            throw error
        } catch {
            throw SpeechEngineError.notInstalled("Voice \(id): \(error.localizedDescription)")
        }
    }

    private func unloadNow() {
        idleTimer?.cancel()
        idleTimer = nil
        styles = [:]
        runtime = nil
        lock.withLock { _isLoaded = false }
    }

    private func scheduleIdleUnload() {
        idleTimer?.cancel()
        idleTimer = nil
        guard runtime != nil, let delay = idleUnloadAfter else { return }
        let item = DispatchWorkItem { [weak self] in self?.unloadNow() }
        idleTimer = item
        queue.asyncAfter(deadline: .now() + delay, execute: item)
    }
}

/// 16-bit mono PCM WAV.
enum WAVEncoder {
    static func encode(_ samples: [Float], sampleRate: Int) -> Data {
        let dataSize = UInt32(samples.count * 2)
        var d = Data(capacity: 44 + Int(dataSize))
        func put<T: FixedWidthInteger>(_ v: T) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        d.append(contentsOf: Array("RIFF".utf8)); put(UInt32(36) + dataSize)
        d.append(contentsOf: Array("WAVEfmt ".utf8)); put(UInt32(16)); put(UInt16(1)); put(UInt16(1))
        put(UInt32(sampleRate)); put(UInt32(sampleRate * 2)); put(UInt16(2)); put(UInt16(16))
        d.append(contentsOf: Array("data".utf8)); put(dataSize)
        let pcm = samples.map { Int16((max(-1, min(1, $0)) * 32767).rounded()) }
        pcm.withUnsafeBytes { d.append(contentsOf: $0) } // Apple silicon/Intel are little-endian
        return d
    }
}
