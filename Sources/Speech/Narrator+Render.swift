import AVFoundation
import OSLog

private let log = Logger(category: "render")

/// A caller's pick of engine/voice/language (local API, CLI, MCP). Anything
/// left nil comes from the user's settings, same as the hotkey.
struct VoiceChoice {
    /// Pins the whole text to one language (no detection).
    var language: ReadingLanguage?
    /// Tried first; an empty `voiceID` means the voice configured for that
    /// engine in the section's language (or the engine's first voice).
    var route: VoiceRoute?
    /// Only `route`, no fallback down the language's chain.
    var strict = false
}

/// One section of a rendered file: where it sits and who spoke it.
struct RenderedSection {
    let section: ReadingSection
    let route: VoiceRoute
    /// Seconds into the output, after speed is applied.
    let start: TimeInterval
    let duration: TimeInterval
    /// Word timings in output time (offset and speed applied).
    let words: [WordTiming]
}

enum RenderError: LocalizedError {
    case nothingToRead

    var errorDescription: String? {
        switch self {
        case .nothingToRead: return "There's no readable text."
        }
    }
}

extension Narrator {
    /// The chain for `language` with `choice` applied: its route first, then
    /// the rest of the user's chain (unless strict).
    func profile(for language: ReadingLanguage, choice: VoiceChoice?) async -> LanguageProfile {
        let base = settings.profile(for: language)
        guard var route = choice?.route else { return base }
        if route.voiceID.isEmpty, !route.engine.isCloudPaid {   // cloud "" = the Cloud-tab voice
            route.voiceID = base.routes.first { $0.engine == route.engine }?.voiceID ?? ""
            if route.voiceID.isEmpty {
                route.voiceID = await voices(route.engine, language: language).first?.id ?? ""
            }
        }
        if choice?.strict == true { return LanguageProfile(language: language, routes: [route]) }
        return LanguageProfile(language: language, routes: [route] + base.routes.filter { $0.engine != route.engine })
    }

    /// Synthesizes `text` the way the reader would (same sections, routing and
    /// fallbacks) but into PCM instead of the speakers. `onAudio` gets
    /// `SectionDecoder.playbackFormat` chunks in order, speed already applied;
    /// it can throw (client gone) to stop. Stops between sections when cancelled.
    func render(_ text: String, choice: VoiceChoice?, speed: Float,
                onAudio: (AVAudioPCMBuffer) async throws -> Void) async throws -> [RenderedSection] {
        let sections = ReadingPlanner.plan(text, languages: choice?.language.map { [$0] } ?? settings.languages)
        guard !sections.isEmpty else { throw RenderError.nothingToRead }

        // Same lookahead as the reader: the next section synthesizes while this one decodes.
        var jobs: [Int: Task<SpeechRouter.Result, Error>] = [:]
        func job(_ i: Int) -> Task<SpeechRouter.Result, Error>? {
            guard sections.indices.contains(i) else { return nil }
            if let existing = jobs[i] { return existing }
            let section = sections[i]
            let task = Task { @MainActor in
                try await self.synthesize(section, profile: await self.profile(for: section.language, choice: choice))
            }
            jobs[i] = task
            return task
        }
        defer { jobs.values.forEach { $0.cancel() } }

        let stretcher = SpeechStretcher(speed: speed)
        let factor = Double(stretcher.speed)
        var rendered: [RenderedSection] = []
        var clock: TimeInterval = 0
        for (i, section) in sections.enumerated() {
            try Task.checkCancellation()
            let result = try await job(i)!.value
            log.notice("render \(i + 1)/\(sections.count) → \(result.route.id, privacy: .public)")
            _ = job(i + 1)
            let speech = result.speech
            let decoded = try await Task.detached(priority: .userInitiated) {
                try SectionDecoder.decode(speech, section: section)
            }.value
            // Kokoro ends sentences with almost no silence; the Athena voiceover
            // put 0.28 s between them. Fed through the stretcher so order holds.
            let gap = i < sections.count - 1 ? result.route.engine.sectionGap : 0
            let chunks = await Task.detached(priority: .userInitiated) { () -> [AVAudioPCMBuffer] in
                var out: [AVAudioPCMBuffer] = []
                let slice = AVAudioFrameCount(decoded.buffer.format.sampleRate / 2)
                var offset: AVAudioFrameCount = 0
                while offset < decoded.buffer.frameLength {
                    let count = min(slice, decoded.buffer.frameLength - offset)
                    if let part = SectionDecoder.slice(of: decoded.buffer, from: offset, count: count),
                       let stretched = stretcher.process(part) { out.append(stretched) }
                    offset += count
                }
                let format = SectionDecoder.playbackFormat
                if gap > 0, let silence = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(gap * format.sampleRate)) {
                    silence.frameLength = silence.frameCapacity
                    memset(silence.floatChannelData![0], 0, Int(silence.frameLength) * MemoryLayout<Float>.size)
                    if let stretched = stretcher.process(silence) { out.append(stretched) }
                }
                if i == sections.count - 1, let tail = stretcher.flush() { out.append(tail) }
                return out
            }.value
            for chunk in chunks { try await onAudio(chunk) }
            let duration = decoded.duration / factor
            rendered.append(RenderedSection(
                section: section, route: result.route, start: clock, duration: duration,
                words: decoded.words.map {
                    WordTiming(range: $0.range, start: clock + $0.start / factor, duration: $0.duration / factor)
                }))
            clock += duration + gap / factor
        }
        return rendered
    }
}
