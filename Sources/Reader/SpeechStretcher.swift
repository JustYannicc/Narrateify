import Accelerate
import AVFoundation

/// Changes speech speed without changing pitch, using Sonic (pitch-synchronous
/// overlap-add, built for speeding up speech — what Android TTS and ExoPlayer
/// use). AVAudioUnitTimePitch is a general phase vocoder and sounds phasey on
/// voices. Streams: feed chunks as they come, `flush()` at the end.
/// Mono `SectionDecoder.playbackFormat` in and out. Not thread-safe: the
/// player only touches it from its serial stretch queue.
final class SpeechStretcher: @unchecked Sendable {
    let speed: Float
    private let stream: sonicStream?

    init(speed: Float) {
        self.speed = speed
        let format = SectionDecoder.playbackFormat
        // 1× is a passthrough: no processing, no added latency.
        stream = speed == 1 ? nil : sonicCreateStream(Int32(format.sampleRate), 1)
        if let stream { sonicSetSpeed(stream, speed) }
    }

    deinit {
        if let stream { sonicDestroyStream(stream) }
    }

    /// Stretched audio for `buffer` (may be shorter: Sonic holds back a few
    /// pitch periods until it sees more input or `flush()`).
    func process(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let stream else { return buffer.frameLength > 0 ? buffer : nil }
        if let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 {
            // Sonic converts to Int16 without clamping: a decoded peak just
            // over 1.0 would wrap into a loud crack.
            var clipped = [Float](repeating: 0, count: Int(buffer.frameLength))
            var lo: Float = -1, hi: Float = 1
            vDSP_vclip(samples, 1, &lo, &hi, &clipped, 1, vDSP_Length(buffer.frameLength))
            sonicWriteFloatToStream(stream, clipped, Int32(buffer.frameLength))
        }
        return drain(stream)
    }

    /// Whatever is still held back, at the end of the input.
    func flush() -> AVAudioPCMBuffer? {
        guard let stream else { return nil }
        sonicFlushStream(stream)
        return drain(stream)
    }

    private func drain(_ stream: sonicStream) -> AVAudioPCMBuffer? {
        let available = sonicSamplesAvailable(stream)
        guard available > 0,
              let out = AVAudioPCMBuffer(pcmFormat: SectionDecoder.playbackFormat,
                                         frameCapacity: AVAudioFrameCount(available)),
              let dst = out.floatChannelData?[0] else { return nil }
        let read = sonicReadFloatFromStream(stream, dst, available)
        out.frameLength = AVAudioFrameCount(max(0, read))
        return out.frameLength > 0 ? out : nil
    }
}
