import AVFoundation

/// Soundscape-style audio beacon: a soft repeating ping that seems to come from the direction of
/// the destination (3D audio, clearest with headphones). It turns into a brighter two-note ping
/// when you face it, so you can walk toward it by sound alone.
final class BeaconAudio {
    private let engine = AVAudioEngine()
    private let environment = AVAudioEnvironmentNode()
    private let player = AVAudioPlayerNode()
    private let facing: AVAudioPCMBuffer
    private let offToSide: AVAudioPCMBuffer
    private var direction: Double?
    private var loop: Task<Void, Never>?

    init() {
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!  // 3D sources must be mono
        facing = Tone.make(format, [(660, 660, 0.09), (0, 0, 0.04), (990, 990, 0.12)])
        offToSide = Tone.make(format, [(520, 520, 0.12)])
        engine.attach(environment)
        engine.attach(player)
        engine.connect(player, to: environment, format: format)
        engine.connect(environment, to: engine.mainMixerNode, format: nil)
        player.renderingAlgorithm = .HRTFHQ
        player.sourceMode = .pointSource
    }

    /// Place the beacon `relativeDegrees` from where you face (0 ahead, negative left, positive right).
    /// Nil silences it.
    func point(_ relativeDegrees: Double?) {
        direction = relativeDegrees
        if relativeDegrees != nil, loop == nil {
            loop = Task { await run() }
        }
    }

    private func run() async {
        while let direction {
            ping(direction)
            try? await Task.sleep(for: .seconds(1.3))
        }
        loop = nil
    }

    /// Not async on purpose: from async code Swift would pick the `scheduleBuffer` overload that waits.
    private func ping(_ relative: Double) {
        guard engine.isRunning || (try? engine.start()) != nil else { return }
        let angle = relative * .pi / 180  // listener faces -z; +x is to the right
        player.position = AVAudio3DPoint(x: Float(sin(angle)) * 2, y: 0, z: Float(-cos(angle)) * 2)
        player.scheduleBuffer(abs(relative) < 15 ? facing : offToSide, at: nil, options: .interrupts)
        if !player.isPlaying { player.play() }
    }
}
