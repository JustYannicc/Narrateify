import AVFoundation

/// Merges synthesized sections into one AAC (.m4a) file for History. Sections
/// can come from different engines (24 kHz MP3 from Edge, 44.1 kHz WAV from
/// Supertonic, Apple's WAV…), so each is decoded into the reader's playback
/// format first — byte-level concatenation would produce garbage.
/// Blocking (file I/O + encoding); call it off the main thread.
enum SectionAudioJoiner {
    static func joinToM4A(_ parts: [SynthesizedSpeech]) throws -> Data {
        let format = SectionDecoder.playbackFormat
        let outURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("narrateify-join-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: outURL) }

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 64_000,
        ]
        do {
            let out = try AVAudioFile(forWriting: outURL, settings: settings,
                                      commonFormat: .pcmFormatFloat32, interleaved: false)
            // Decoding only needs a section for word estimates, which we ignore.
            let placeholder = ReadingSection(id: 0, text: "", language: .englishUS)
            for part in parts {
                try out.write(from: SectionDecoder.decode(part, section: placeholder).buffer)
            }
        }   // file closes (and finalizes the m4a) here
        return try Data(contentsOf: outURL)
    }
}
