import AVFoundation

/// Merges synthesized sections into one AAC (.m4a) file for History. Sections
/// can come from different engines (24 kHz MP3 from Edge, 44.1 kHz WAV from
/// Supertonic, Apple's WAV…), so everything is decoded and resampled to one
/// mono format first — byte-level concatenation would produce garbage.
enum SectionAudioJoiner {
    static let sampleRate: Double = 24_000

    static func joinToM4A(_ parts: [SynthesizedSpeech]) throws -> Data {
        guard let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                                         channels: 1, interleaved: false) else {
            throw SpeechEngineError.synthesisFailed("Couldn't create audio format")
        }
        let tmp = FileManager.default.temporaryDirectory
        let outURL = tmp.appendingPathComponent("narrateify-join-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: outURL) }

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 64_000,
        ]
        do {
            let out = try AVAudioFile(forWriting: outURL, settings: settings,
                                      commonFormat: .pcmFormatFloat32, interleaved: false)
            for part in parts {
                try append(part, to: out, format: target, tmp: tmp)
            }
        }   // file closes (and finalizes the m4a) here
        return try Data(contentsOf: outURL)
    }

    private static func append(_ part: SynthesizedSpeech, to out: AVAudioFile,
                               format target: AVAudioFormat, tmp: URL) throws {
        let inURL = tmp.appendingPathComponent("narrateify-part-\(UUID().uuidString).\(part.fileExtension)")
        try part.audio.write(to: inURL)
        defer { try? FileManager.default.removeItem(at: inURL) }

        let input = try AVAudioFile(forReading: inURL)
        let srcFormat = input.processingFormat
        guard let src = AVAudioPCMBuffer(pcmFormat: srcFormat, frameCapacity: AVAudioFrameCount(input.length)) else { return }
        try input.read(into: src)
        guard src.frameLength > 0, let converter = AVAudioConverter(from: srcFormat, to: target) else { return }

        let ratio = target.sampleRate / srcFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(src.frameLength) * ratio) + 1024
        guard let dst = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
        var consumed = false
        var error: NSError?
        converter.convert(to: dst, error: &error) { _, status in
            if consumed { status.pointee = .endOfStream; return nil }
            consumed = true
            status.pointee = .haveData
            return src
        }
        if let error { throw error }
        try out.write(from: dst)
    }
}
