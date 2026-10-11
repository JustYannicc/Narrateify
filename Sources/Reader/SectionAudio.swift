import AVFoundation

/// A synthesized section decoded into memory, ready for the player: PCM in the
/// reader's fixed playback format plus the word timings to highlight with.
struct DecodedSection {
    let sectionID: Int
    let buffer: AVAudioPCMBuffer
    /// Seconds of audio at 1× (source time).
    let duration: TimeInterval
    /// Real timings from the engine, or estimated from `duration` when it had none.
    let words: [WordTiming]
}

enum SectionDecoderError: LocalizedError {
    case unreadable(String)
    case empty

    var errorDescription: String? {
        switch self {
        case .unreadable(let s): return "Couldn't decode audio: \(s)"
        case .empty:             return "The engine returned no audio."
        }
    }
}

/// Turns engine output (WAV/MP3 bytes at whatever rate the engine likes) into
/// PCM in one fixed format. Every section ends up identical on the wire, so the
/// player graph never has to be reconnected between sections — a 24 kHz Edge
/// MP3 followed by a 44.1 kHz Apple WAV just works.
enum SectionDecoder {
    /// Mono float at 48 kHz. TTS is mono anyway; the mixer upmixes for output.
    static let playbackFormat = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!

    /// Blocking (file I/O + resampling); call it off the main thread.
    static func decode(_ speech: SynthesizedSpeech, section: ReadingSection) throws -> DecodedSection {
        guard !speech.audio.isEmpty else { throw SectionDecoderError.empty }

        // AVAudioFile only reads from disk, and needs the extension to sniff MP3.
        let ext = speech.fileExtension.isEmpty ? "wav" : speech.fileExtension
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("narrateify-reader-\(UUID().uuidString).\(ext)")
        try speech.audio.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let source: AVAudioPCMBuffer
        do {
            let file = try AVAudioFile(forReading: url)
            let capacity = AVAudioFrameCount(max(file.length, 1))
            guard let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: capacity) else {
                throw SectionDecoderError.unreadable("buffer allocation failed")
            }
            try file.read(into: buf)
            source = buf
        } catch let error as SectionDecoderError {
            throw error
        } catch {
            throw SectionDecoderError.unreadable(error.localizedDescription)
        }
        guard source.frameLength > 0 else { throw SectionDecoderError.empty }

        let buffer = try convert(source, to: playbackFormat)
        let duration = Double(buffer.frameLength) / playbackFormat.sampleRate
        let words = speech.words.isEmpty
            ? WordTiming.estimate(text: section.text, duration: duration)
            : speech.words
        return DecodedSection(sectionID: section.id, buffer: buffer, duration: duration, words: words)
    }

    /// Resample / downmix / reformat `source` into `format` in one pass.
    static func convert(_ source: AVAudioPCMBuffer, to format: AVAudioFormat) throws -> AVAudioPCMBuffer {
        if source.format == format { return source }
        guard let converter = AVAudioConverter(from: source.format, to: format) else {
            throw SectionDecoderError.unreadable("no converter from \(source.format)")
        }
        converter.downmix = true
        let ratio = format.sampleRate / source.format.sampleRate
        let capacity = AVAudioFrameCount((Double(source.frameLength) * ratio).rounded(.up)) + 1024
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
            throw SectionDecoderError.unreadable("buffer allocation failed")
        }

        var fed = false
        var convError: NSError?
        let status = converter.convert(to: out, error: &convError) { _, inputStatus in
            if fed {
                inputStatus.pointee = .endOfStream
                return nil
            }
            fed = true
            inputStatus.pointee = .haveData
            return source
        }
        if status == .error {
            throw SectionDecoderError.unreadable(convError?.localizedDescription ?? "conversion failed")
        }
        return out
    }

    /// A copy of `buffer` starting at `frame` — used to resume mid-section
    /// (restart after an output-device change).
    static func tail(of buffer: AVAudioPCMBuffer, from frame: AVAudioFramePosition) -> AVAudioPCMBuffer? {
        let start = AVAudioFrameCount(max(0, min(frame, AVAudioFramePosition(buffer.frameLength))))
        if start == 0 { return buffer }
        let remaining = buffer.frameLength - start
        guard remaining > 0,
              let out = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: remaining),
              let src = buffer.floatChannelData, let dst = out.floatChannelData else { return nil }
        for ch in 0..<Int(buffer.format.channelCount) {
            dst[ch].update(from: src[ch].advanced(by: Int(start)), count: Int(remaining))
        }
        out.frameLength = remaining
        return out
    }
}

/// Maps a playback position (source seconds) to the word being spoken.
enum WordTimeline {
    /// Index of the last word whose start ≤ `time`. Before the first word we
    /// already point at it (feels more responsive than an empty highlight).
    static func index(at time: TimeInterval, in words: [WordTiming]) -> Int? {
        guard !words.isEmpty else { return nil }
        var lo = 0, hi = words.count - 1, found = 0
        while lo <= hi {
            let mid = (lo + hi) / 2
            if words[mid].start <= time {
                found = mid
                lo = mid + 1
            } else {
                hi = mid - 1
            }
        }
        return found
    }
}
