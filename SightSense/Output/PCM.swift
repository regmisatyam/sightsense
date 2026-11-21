import AVFoundation

/// Raw audio for Gemini Live: 16-bit little-endian mono samples (24 kHz for the speech it sends,
/// 16 kHz for the microphone audio we send).
nonisolated enum PCM {
    static let speech = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24_000,
                                                          channels: 1, interleaved: false)!
    static let microphone = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000,
                                                              channels: 1, interleaved: true)!

    /// 16-bit little-endian samples → a buffer the audio engine can play.
    static func floatBuffer(from pcm: Data, format: AVAudioFormat = speech) -> AVAudioPCMBuffer? {
        let count = pcm.count / 2
        guard count > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)),
              let channel = buffer.floatChannelData?[0] else { return nil }
        buffer.frameLength = AVAudioFrameCount(count)
        pcm.withUnsafeBytes { raw in
            for i in 0..<count {
                let sample = Int16(littleEndian: raw.loadUnaligned(fromByteOffset: i * 2, as: Int16.self))
                channel[i] = Float(sample) / 32_768
            }
        }
        return buffer
    }
}
