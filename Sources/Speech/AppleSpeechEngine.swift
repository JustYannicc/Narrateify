import Foundation
import AVFoundation

/// macOS's built-in voices as a `SpeechEngine`: zero install, zero extra RAM,
/// always available — the end of every fallback chain. Uses the marker
/// callback to get real word timings for highlighting.
final class AppleSpeechEngine: SpeechEngine {
    let kind: SpeechEngineKind = .apple

    func supports(_ language: ReadingLanguage) -> Bool {
        !Self.installed(for: language).isEmpty
    }

    func voices(for language: ReadingLanguage) async -> [VoiceOption] {
        Self.installed(for: language)
            .sorted { lhs, rhs in
                // Exact locale and better quality first.
                let l = (lhs.language == language.code ? 0 : 1, -lhs.quality.rawValue)
                let r = (rhs.language == language.code ? 0 : 1, -rhs.quality.rawValue)
                return l != r ? l < r : lhs.name < rhs.name
            }
            .map(Self.option(for:))
    }

    static func option(for v: AVSpeechSynthesisVoice) -> VoiceOption {
        let tier = v.quality == .premium ? " ✦" : v.quality == .enhanced ? " +" : ""
        return VoiceOption(id: v.identifier, name: "\(v.name)\(tier) (\(v.language))", languages: [v.language])
    }

    // `speechVoices()` is slow-ish and called per section and per settings
    // render, so cache the filtered list per language until voices change.
    private static let cacheLock = NSLock()
    private static var cache: [String: [AVSpeechSynthesisVoice]] = [:]
    private static let invalidator: NSObjectProtocol = NotificationCenter.default.addObserver(
        forName: AVSpeechSynthesizer.availableVoicesDidChangeNotification, object: nil, queue: nil
    ) { _ in cacheLock.withLock { cache.removeAll() } }

    private static func installed(for language: ReadingLanguage) -> [AVSpeechSynthesisVoice] {
        _ = invalidator
        return cacheLock.withLock {
            if let hit = cache[language.code] { return hit }
            let voices = AVSpeechSynthesisVoice.speechVoices().filter { matches($0, language) }
            cache[language.code] = voices
            return voices
        }
    }

    /// Best installed voice for `language` — used when a route has no voice.
    static func defaultVoice(for language: ReadingLanguage) -> String? {
        let all = installed(for: language)
        let exact = all.filter { $0.language == language.code }
        return (exact.max { $0.quality.rawValue < $1.quality.rawValue }
                ?? all.max { $0.quality.rawValue < $1.quality.rawValue })?.identifier
    }

    func synthesize(_ text: String, language: ReadingLanguage, voiceID: String) async throws -> SynthesizedSpeech {
        let utterance = AVSpeechUtterance(string: text)
        let voice = AVSpeechSynthesisVoice(identifier: voiceID)
            ?? Self.defaultVoice(for: language).flatMap(AVSpeechSynthesisVoice.init(identifier:))
        guard let voice else { throw SpeechEngineError.unsupportedLanguage(language.code) }
        utterance.voice = voice

        let synth = AVSpeechSynthesizer()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("narrateify-apple-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }

        // Markers report positions as BYTE offsets into the PCM stream (verified:
        // treating them as samples overshoots the audio ~4× for Float32 mono);
        // convert once the buffer format is known.
        var marks: [(range: NSRange, byte: Int)] = []
        var bytesPerSecond: Double = 22_050 * 4

        let data: Data = try await withCheckedThrowingContinuation { cont in
            var file: AVAudioFile?
            var done = false
            func finish(_ result: Swift.Result<Data, Error>) {
                guard !done else { return }
                done = true
                file = nil
                _ = synth   // keep the synthesizer alive until completion
                cont.resume(with: result)
            }
            synth.write(utterance, toBufferCallback: { buffer in
                guard let pcm = buffer as? AVAudioPCMBuffer else { return }
                guard pcm.frameLength > 0 else {
                    file = nil
                    let data = (try? Data(contentsOf: url)) ?? Data()
                    finish(data.isEmpty ? .failure(SpeechEngineError.synthesisFailed("Apple TTS produced no audio"))
                                        : .success(data))
                    return
                }
                do {
                    if file == nil {
                        let bytesPerFrame = Double(pcm.format.streamDescription.pointee.mBytesPerFrame)
                        bytesPerSecond = pcm.format.sampleRate * max(1, bytesPerFrame)
                        file = try AVAudioFile(forWriting: url, settings: pcm.format.settings,
                                               commonFormat: pcm.format.commonFormat,
                                               interleaved: pcm.format.isInterleaved)
                    }
                    try file?.write(from: pcm)
                } catch {
                    finish(.failure(SpeechEngineError.synthesisFailed(error.localizedDescription)))
                }
            }, toMarkerCallback: { markers in
                for m in markers where m.mark == .word {
                    marks.append((m.textRange, m.byteSampleOffset))
                }
            })
        }

        let words = marks.enumerated().map { i, m -> WordTiming in
            let start = Double(m.byte) / bytesPerSecond
            let end = i + 1 < marks.count ? Double(marks[i + 1].byte) / bytesPerSecond : start + 0.3
            return WordTiming(range: m.range, start: start, duration: max(0.05, end - start))
        }
        return SynthesizedSpeech(audio: data, fileExtension: "wav", words: words)
    }

    private static func matches(_ voice: AVSpeechSynthesisVoice, _ language: ReadingLanguage) -> Bool {
        // Skip novelty (Bells, Bad News…) and Eloquence (Grandma, Eddy…) voices —
        // nobody wants to read an article in them.
        let id = voice.identifier
        guard !id.contains("speech.synthesis.voice"), !id.hasPrefix("com.apple.eloquence") else { return false }
        return language.matches(localeTag: voice.language)
    }
}
