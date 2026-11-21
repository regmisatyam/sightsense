import QuartzCore

/// Calm Mode: gentle narration of the surroundings, only while no hazard is near and nothing
/// else is being said. It speaks no more often than the chosen interval, and only when the scene
/// changed (you walked on, turned, or different things are around), so it doesn't repeat itself.
///
/// The words come from the fast vision model and are spoken by the agent, at ambient priority:
/// any alert interrupts it instantly.
final class CalmNarrator {
    var interval: Double {
        get { gate.minInterval }
        set { gate.minInterval = newValue }
    }

    private let speech: SpeechQueue
    private let describer: SceneDescriber
    private var gate = NarrationGate()
    private var earliest: CFTimeInterval = 0
    private var lastLine: String?
    private var isWorking = false

    init(speech: SpeechQueue, describer: SceneDescriber) {
        self.speech = speech
        self.describer = describer
    }

    /// Narrate soon, e.g. right after switching into Calm Mode.
    func reset() {
        let interval = gate.minInterval
        gate = NarrationGate()
        gate.minInterval = interval
        earliest = CACurrentMediaTime() + 3
    }

    /// Called about once a second while in Calm Mode.
    /// - offlineLine: what to say if Gemini can't be reached (nil = stay quiet).
    /// - canSpeak: checked again after the network calls; a hazard may have appeared meanwhile.
    func tick(frame: Frame?, scene: SceneSnapshot, offlineLine: String?, canSpeak: () -> Bool) async {
        let now = CACurrentMediaTime()
        guard !isWorking, now >= earliest, let frame, canSpeak(), !speech.isBusy,
              gate.shouldNarrate(scene, now: now) else { return }
        isWorking = true
        defer { isWorking = false }

        var line = offlineLine
        do {
            var sentences: [String] = []
            for try await sentence in try await describer.describe(frame, style: .calm(previous: lastLine)) {
                sentences.append(sentence)
            }
            if !sentences.isEmpty { line = sentences.joined(separator: " ") }
        } catch {
            // keep the offline line
        }
        guard let line, canSpeak() else {
            earliest = CACurrentMediaTime() + 30  // nothing to say right now; don't retry every second
            return
        }

        speech.say(line, priority: .ambient)
        gate.didNarrate(scene, now: CACurrentMediaTime())
        lastLine = line
    }
}
