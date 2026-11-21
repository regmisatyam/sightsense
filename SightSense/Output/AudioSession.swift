import AVFoundation

nonisolated enum AudioSession {
    /// One setup for the whole session, so nothing has to switch (switching stops audio engines):
    /// - play and record: the AI agent can listen whenever the person talks to it;
    /// - plays through earphones whenever they're connected (wired, or Bluetooth in full stereo
    ///   quality, which the 3D beacon needs), otherwise the speaker. The phone's own mic listens;
    ///   it's on the chest, close to the mouth. (No voice processing / call mode: that would force
    ///   Bluetooth earphones off, or down to low-quality mono call audio.)
    /// - ignores the silent switch, and mixes with the person's own music or podcasts.
    /// Runs off the main thread: activating the session can block for a while.
    @concurrent static func configure() async {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .default,
                                    options: [.defaultToSpeaker, .allowBluetoothA2DP, .mixWithOthers])
            try session.setActive(true)
        } catch {
            print("AudioSession: \(error)")
        }
    }

    /// Sound is going to earphones or headphones (wired, Bluetooth, USB, AirPlay), not the phone's
    /// own speaker, so the microphone can't pick it up.
    static var headphonesConnected: Bool {
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
        return !outputs.isEmpty && outputs.allSatisfy { $0.portType != .builtInSpeaker && $0.portType != .builtInReceiver }
    }
}
