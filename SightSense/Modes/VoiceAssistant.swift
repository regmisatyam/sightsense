import Observation
import QuartzCore

/// The Ask button and microphone when the AI agent isn't connected (offline): speech is
/// recognized on the phone, and familiar phrases work as commands.
/// - Tap Ask (or press volume down / click AirPods): speak, and it stops when you pause.
/// - Or hold the hardware button while talking, like a walkie-talkie: it stops when you let go.
/// - Tap again while listening to finish early.
/// What was heard goes to `onRequest`: short familiar phrases are commands handled on the phone,
/// anything else is a question for the AI.
@Observable
final class VoiceAssistant {
    private(set) var isListening = false
    private(set) var lastHeard = ""

    @ObservationIgnored var onRequest: ((VoiceCommand, String) -> Void)?
    @ObservationIgnored private let listener = VoiceListener()
    @ObservationIgnored private let speech: SpeechQueue
    @ObservationIgnored private let audio: SpatialAudio
    @ObservationIgnored private var permitted: Bool?
    @ObservationIgnored private var session: Task<Void, Never>?
    @ObservationIgnored private var pressedAt: CFTimeInterval = 0
    @ObservationIgnored private var pressFinishedListening = false

    init(speech: SpeechQueue, audio: SpatialAudio) {
        self.speech = speech
        self.audio = audio
    }

    /// Tap Ask: start listening, or finish now if already listening.
    func toggle() {
        if isListening {
            listener.finish()
        } else {
            start()
        }
    }

    /// Hardware button. A quick press listens until you pause; holding it listens until you let go.
    func button(pressed: Bool) {
        let now = CACurrentMediaTime()
        if pressed {
            pressedAt = now
            pressFinishedListening = isListening
            toggle()
        } else if !pressFinishedListening, isListening, now - pressedAt > 0.8 {
            listener.finish()
        }
    }

    private func start() {
        guard session == nil else { return }
        isListening = true
        session = Task {
            defer {
                isListening = false
                session = nil
            }
            if permitted != true {
                permitted = await VoiceListener.requestPermission()
            }
            guard permitted == true else {
                speech.say("To ask questions, allow the microphone and speech recognition for SightSense in the Settings app.")
                return
            }
            speech.cancelNonUrgent()
            audio.play(.listening)
            Haptics.tap()
            let heard = await listener.listen()
            audio.play(.heard)
            guard !heard.isEmpty else {
                speech.say("I didn't catch that.")
                return
            }
            lastHeard = heard
            onRequest?(VoiceCommand.parse(heard), heard)
        }
    }
}
