import AudioToolbox
import AVFoundation

/// Decodes an MP3 byte stream to PCM in `SectionDecoder.playbackFormat` as the
/// bytes arrive, so playback can start on the first network chunk instead of
/// after the whole file. AudioFileStream finds the frame boundaries (chunks
/// may split frames); AVAudioConverter decodes and resamples in one pass.
/// Not thread-safe: feed it from one queue.
final class MP3StreamDecoder {
    private var stream: AudioFileStreamID?
    private var converter: AVAudioConverter?
    private var inputFormat: AVAudioFormat?
    private var maxPacketSize: UInt32 = 0
    private let output = SectionDecoder.playbackFormat
    private let onPCM: (AVAudioPCMBuffer) -> Void
    private(set) var failure: String?

    init(onPCM: @escaping (AVAudioPCMBuffer) -> Void) {
        self.onPCM = onPCM
        let status = AudioFileStreamOpen(Unmanaged.passUnretained(self).toOpaque(),
                                         { client, stream, property, _ in
                                             Unmanaged<MP3StreamDecoder>.fromOpaque(client)
                                                 .takeUnretainedValue().propertyChanged(stream, property)
                                         },
                                         { client, bytes, packets, data, descriptions in
                                             Unmanaged<MP3StreamDecoder>.fromOpaque(client)
                                                 .takeUnretainedValue()
                                                 .packets(bytes, packets, data, descriptions)
                                         },
                                         kAudioFileMP3Type, &stream)
        if status != noErr { failure = "AudioFileStreamOpen \(status)" }
    }

    deinit {
        if let stream { AudioFileStreamClose(stream) }
    }

    /// Load the MP3 codec ahead of the first stream (Edge sends 24 kHz mono),
    /// so the first hotkey doesn't pay for it. Call off the main thread.
    static func prewarm() {
        var asbd = AudioStreamBasicDescription(mSampleRate: 24_000, mFormatID: kAudioFormatMPEGLayer3,
                                               mFormatFlags: 0, mBytesPerPacket: 0, mFramesPerPacket: 1152,
                                               mBytesPerFrame: 0, mChannelsPerFrame: 1, mBitsPerChannel: 0,
                                               mReserved: 0)
        guard let format = AVAudioFormat(streamDescription: &asbd) else { return }
        _ = AVAudioConverter(from: format, to: SectionDecoder.playbackFormat)
    }

    func feed(_ data: Data) {
        guard let stream, failure == nil, !data.isEmpty else { return }
        let status = data.withUnsafeBytes {
            AudioFileStreamParseBytes(stream, UInt32(data.count), $0.baseAddress, [])
        }
        if status != noErr { failure = "AudioFileStreamParseBytes \(status)" }
    }

    /// Drain what the converter still holds (decoder/resampler tail).
    func finish() {
        guard let converter, failure == nil else { return }
        convert(using: converter, input: nil)
    }

    // MARK: Callbacks

    private func propertyChanged(_ stream: AudioFileStreamID, _ property: AudioFileStreamPropertyID) {
        guard property == kAudioFileStreamProperty_ReadyToProducePackets else { return }
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard AudioFileStreamGetProperty(stream, kAudioFileStreamProperty_DataFormat, &size, &asbd) == noErr,
              let format = AVAudioFormat(streamDescription: &asbd),
              let converter = AVAudioConverter(from: format, to: output) else {
            failure = "unsupported MP3 stream format"
            return
        }
        converter.downmix = true
        var maxSize: UInt32 = 0
        size = UInt32(MemoryLayout<UInt32>.size)
        if AudioFileStreamGetProperty(stream, kAudioFileStreamProperty_PacketSizeUpperBound, &size, &maxSize) != noErr
            || maxSize == 0 {
            maxSize = 2048   // largest MPEG-1 layer III frame is 1441 bytes
        }
        inputFormat = format
        maxPacketSize = maxSize
        self.converter = converter
    }

    private func packets(_ byteCount: UInt32, _ packetCount: UInt32, _ data: UnsafeRawPointer,
                         _ descriptions: UnsafeMutablePointer<AudioStreamPacketDescription>?) {
        guard let converter, let inputFormat, packetCount > 0 else { return }
        guard let descriptions else {
            failure = "MP3 packets without descriptions"   // → falls back to a full decode
            return
        }
        let buffer = AVAudioCompressedBuffer(format: inputFormat, packetCapacity: AVAudioPacketCount(packetCount),
                                             maximumPacketSize: Int(max(maxPacketSize, byteCount)))
        buffer.data.copyMemory(from: data, byteCount: Int(byteCount))
        buffer.packetDescriptions?.update(from: descriptions, count: Int(packetCount))
        buffer.packetCount = AVAudioPacketCount(packetCount)
        buffer.byteLength = byteCount
        convert(using: converter, input: buffer)
    }

    /// Feed one compressed buffer (nil = end of stream) and emit all PCM the
    /// converter produces from it.
    private func convert(using converter: AVAudioConverter, input: AVAudioCompressedBuffer?) {
        var pending = input
        let framesPerPacket = Double(max(inputFormat?.streamDescription.pointee.mFramesPerPacket ?? 1152, 1))
        let ratio = output.sampleRate / (inputFormat?.sampleRate ?? output.sampleRate)
        let capacity = AVAudioFrameCount(Double(max(input?.packetCount ?? 4, 4)) * framesPerPacket * ratio) + 256
        while true {
            guard let out = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: capacity) else { return }
            var error: NSError?
            let status = converter.convert(to: out, error: &error) { _, inputStatus in
                if let buffer = pending {
                    pending = nil
                    inputStatus.pointee = .haveData
                    return buffer
                }
                inputStatus.pointee = input == nil ? .endOfStream : .noDataNow
                return nil
            }
            if out.frameLength > 0 { onPCM(out) }
            switch status {
            case .haveData:
                continue   // output filled up; more is waiting
            case .error:
                failure = error?.localizedDescription ?? "MP3 decode failed"
                return
            default:
                return     // inputRanDry / endOfStream
            }
        }
    }
}
