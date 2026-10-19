import AVFoundation

/// Rendered PCM (`SectionDecoder.playbackFormat`) out to files and streams.
enum AudioOutput {
    enum Format: String, CaseIterable {
        case wav, m4a

        init?(fileExtension ext: String) {
            switch ext.lowercased() {
            case "wav", "wave": self = .wav
            case "m4a", "aac", "mp4": self = .m4a
            default: return nil
            }
        }

        var mimeType: String { self == .wav ? "audio/wav" : "audio/mp4" }
    }

    static var sampleRate: Double { SectionDecoder.playbackFormat.sampleRate }

    /// Writes `buffer` to `url` (via a temp file beside it, so a failure
    /// never leaves half a file) and returns the file's real duration, read
    /// back so AAC padding is accounted for. Blocking.
    static func write(_ buffer: AVAudioPCMBuffer, to url: URL, format: Format) throws -> TimeInterval {
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temp = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).\(format.rawValue)")
        defer { try? fm.removeItem(at: temp) }
        let duration = try writeFile(buffer, to: temp, format: format)
        if fm.fileExists(atPath: url.path) {
            _ = try fm.replaceItemAt(url, withItemAt: temp)
        } else {
            try fm.moveItem(at: temp, to: url)
        }
        return duration
    }

    /// The encoded bytes, for replying without a file. Blocking.
    static func encode(_ buffer: AVAudioPCMBuffer, format: Format) throws -> (Data, TimeInterval) {
        let duration = Double(buffer.frameLength) / sampleRate
        if format == .wav {
            return (WAVEncoder.header(dataSize: UInt32(buffer.frameLength) * 2, sampleRate: Int(sampleRate))
                    + int16Data(buffer), duration)
        }
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("narrateify-api-\(UUID().uuidString).\(format.rawValue)")
        defer { try? FileManager.default.removeItem(at: temp) }
        let real = try writeFile(buffer, to: temp, format: format)
        return (try Data(contentsOf: temp), real)
    }

    private static func writeFile(_ buffer: AVAudioPCMBuffer, to url: URL, format: Format) throws -> TimeInterval {
        let settings: [String: Any]
        switch format {
        case .wav:
            settings = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 1,
                        AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false]
        case .m4a:
            settings = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 1,
                        AVEncoderBitRateKey: 96_000]
        }
        do {
            let file = try AVAudioFile(forWriting: url, settings: settings,
                                       commonFormat: .pcmFormatFloat32, interleaved: false)
            try file.write(from: buffer)
        }   // closing the file finalizes the header
        let written = try AVAudioFile(forReading: url)
        return Double(written.length) / written.fileFormat.sampleRate
    }

    /// 16-bit little-endian PCM (clamped), for streaming and in-memory WAVs.
    static func int16Data(_ buffer: AVAudioPCMBuffer) -> Data {
        guard let samples = buffer.floatChannelData?[0] else { return Data() }
        return WAVEncoder.pcm16(UnsafeBufferPointer(start: samples, count: Int(buffer.frameLength)))
    }
}
