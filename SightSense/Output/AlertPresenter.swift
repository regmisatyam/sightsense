/// Plays alerts: sound and buzz first (instant, no words needed), then a short phrase.
/// Non-urgent alerts are spoken only when nothing else is, so they never go stale in a queue.
final class AlertPresenter {
    let audio = SpatialAudio()
    private let speech: SpeechQueue

    init(speech: SpeechQueue) {
        self.speech = speech
    }

    func present(_ alert: Alert, onStart: @escaping SpeechQueue.StartHandler) {
        if alert.urgent {
            audio.play(cue(for: alert.kind))
            Haptics.alert(alert.kind)
            speech.say(alert.text, priority: .urgent, onStart: onStart)
        } else if !speech.isBusy {
            speech.say(alert.text, priority: .normal, onStart: onStart)
        }
    }

    private func cue(for kind: Alert.Kind) -> SpatialAudio.Cue {
        switch kind {
        case .dropOff: .dropOff
        case .approaching: .approaching
        case .object, .obstacle, .crowd: .obstacle
        }
    }
}
