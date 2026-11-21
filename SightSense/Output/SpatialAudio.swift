import AVFoundation

/// All non-speech sound:
/// - proximity beeps toward the most important thing ahead: panned left/right (needs headphones),
///   faster and higher as it gets closer;
/// - warning cues that play instantly, before any words, centered so they work on the phone
///   speaker too: double pulse = obstacle, falling tone = drop-off, rising tone = approaching;
///   two short notes when the mic starts and stops listening, two low notes when the AI
///   (the app's voice) can't be reached, and a friendly three-note chime when a saved person appears.
final class SpatialAudio {
    enum Cue { case obstacle, dropOff, approaching, listening, heard, offline, friend }

    private let engine = AVAudioEngine()
    private let beepNode = AVAudioPlayerNode()
    private let cueNode = AVAudioPlayerNode()
    private let highBeep: AVAudioPCMBuffer
    private let lowBeep: AVAudioPCMBuffer
    private let cues: [Cue: AVAudioPCMBuffer]
    private var target: (pan: Float, closeness: Closeness)?
    private var loop: Task<Void, Never>?

    init() {
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
        highBeep = Tone.make(format, [(1320, 1320, 0.07)])
        lowBeep = Tone.make(format, [(880, 880, 0.07)])
        cues = [
            .obstacle: Tone.make(format, [(700, 700, 0.07), (0, 0, 0.05), (700, 700, 0.07)]),
            .dropOff: Tone.make(format, [(900, 250, 0.35)]),
            .approaching: Tone.make(format, [(350, 1200, 0.16), (0, 0, 0.04), (350, 1200, 0.16)]),
            .listening: Tone.make(format, [(600, 600, 0.06), (900, 900, 0.08)]),  // "go ahead"
            .heard: Tone.make(format, [(900, 900, 0.06), (600, 600, 0.08)]),      // "got it"
            .offline: Tone.make(format, [(520, 520, 0.12), (0, 0, 0.06), (390, 390, 0.2)]),  // "uh-oh"
            .friend: Tone.make(format, [(660, 660, 0.07), (880, 880, 0.07), (1100, 1100, 0.12)]),  // "hello!"
        ]
        for node in [beepNode, cueNode] {
            engine.attach(node)
            engine.connect(node, to: engine.mainMixerNode, format: format)
        }
    }

    // MARK: Warning cues

    func play(_ cue: Cue) {
        guard ensureRunning(), let buffer = cues[cue] else { return }
        cueNode.scheduleBuffer(buffer, at: nil, options: .interrupts)
        if !cueNode.isPlaying { cueNode.play() }
    }

    // MARK: Proximity beeps

    /// Beep toward `pan` (-1 left … 1 right) at a rate set by `closeness`.
    func beep(pan: Float, closeness: Closeness) {
        target = (pan, closeness)
        if loop == nil {
            loop = Task { await runBeeps() }
        }
    }

    func silence() {
        target = nil
    }

    private func runBeeps() async {
        while let target {
            beep(target)
            let interval: Double = switch target.closeness {
            case .near: 0.25
            case .mid: 0.6
            case .far: 1.2
            }
            try? await Task.sleep(for: .seconds(interval))
        }
        loop = nil
    }

    /// Not async on purpose: from async code Swift would pick the `scheduleBuffer` overload that waits.
    private func beep(_ target: (pan: Float, closeness: Closeness)) {
        guard ensureRunning() else { return }
        beepNode.pan = target.pan
        beepNode.scheduleBuffer(target.closeness == .near ? highBeep : lowBeep, at: nil, options: .interrupts)
        if !beepNode.isPlaying { beepNode.play() }
    }

    /// Starts the engine if needed (first use, or after a phone call or headphone change).
    private func ensureRunning() -> Bool {
        engine.isRunning || (try? engine.start()) != nil
    }
}

/// Builds short tones from segments of (start Hz, end Hz, seconds); 0 Hz is silence.
/// Each segment fades in and out so there are no clicks.
enum Tone {
    static func make(_ format: AVAudioFormat, _ segments: [(Double, Double, Double)]) -> AVAudioPCMBuffer {
        let rate = format.sampleRate
        let total = AVAudioFrameCount(segments.map { $0.2 * rate }.reduce(0, +))
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: total)!
        buffer.frameLength = total
        let samples = buffer.floatChannelData![0]
        var index = 0
        var phase = 0.0
        for (start, end, seconds) in segments {
            let count = Int(seconds * rate)
            for i in 0..<count {
                let progress = Double(i) / Double(count)
                let frequency = start + (end - start) * progress
                phase += 2 * Double.pi * frequency / rate
                let envelope = sin(Double.pi * progress)
                samples[index] = frequency > 0 ? Float(sin(phase) * envelope * 0.5) : 0
                index += 1
            }
        }
        return buffer
    }
}
