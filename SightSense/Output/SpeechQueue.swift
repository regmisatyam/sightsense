import QuartzCore

enum SpeechPriority {
    /// Calm Mode chatter. Dropped if anything else is speaking or waiting.
    case ambient
    /// Answers to the user and mid-range hazards. Queued; cuts off ambient.
    case normal
    /// Close hazards. Cut off everything and speak now.
    case urgent
}

/// The app's voice queue. Higher-priority speech interrupts lower-priority speech.
///
/// One voice, and only one: the AI agent's own natural voice (Gemini Live), word for word. App lines
/// wait while the agent is answering the person; urgent ones cut in. There is no robotic backup
/// voice: while the agent can't be reached, lines aren't spoken (urgent warnings still sound and
/// buzz first, from AlertPresenter), and lines waiting for it are dropped once it's gone.
final class SpeechQueue {
    /// Receives the moment audio actually started (CACurrentMediaTime), for latency stats.
    typealias StartHandler = (CFTimeInterval) -> Void

    private struct Line {
        let text: String
        let onStart: StartHandler?
    }

    private struct Current {
        let token: Int
        let priority: SpeechPriority
        let line: Line
    }

    /// The one voice.
    var agent: Agent?
    /// Every line, and whether it could be spoken (false = the AI was offline), for the laptop viewer.
    var onSpeak: ((_ text: String, _ priority: SpeechPriority, _ spoken: Bool) -> Void)?

    private var pending: [Line] = []  // normal-priority lines waiting their turn
    private var current: Current?
    private var nextToken = 0

    /// True while something other than ambient chatter is playing or waiting, or the agent is answering.
    var isBusy: Bool {
        !pending.isEmpty || (current != nil && current?.priority != .ambient) || agentIsBusy
    }

    private var agentIsReady: Bool { agent?.isReady == true }

    /// The agent is answering, or still connecting (so its voice will be ready in a moment).
    private var agentIsBusy: Bool {
        guard let agent else { return false }
        return agent.isAnswering || agent.state == .connecting
    }

    func say(_ text: String, priority: SpeechPriority = .normal, onStart: StartHandler? = nil) {
        let line = Line(text: text, onStart: onStart)
        guard agentIsReady || agent?.state == .connecting else {
            onSpeak?(text, priority, false)  // no voice to say it with
            return
        }
        switch priority {
        case .urgent:
            pending.removeAll()
            speakNow(line, priority: .urgent)
        case .normal:
            if (current == nil || current?.priority == .ambient) && !agentIsBusy {
                speakNow(line, priority: .normal)
            } else {
                pending.append(line)
            }
        case .ambient:
            guard current == nil, pending.isEmpty, !agentIsBusy else { return }
            speakNow(line, priority: .ambient)
        }
    }

    /// Silences everything except an urgent alert that is already playing, including the agent's answer.
    func cancelNonUrgent() {
        pending.removeAll()
        guard current?.priority != .urgent else { return }
        current = nil
        agent?.interrupt()
    }

    /// The agent finished speaking or connecting: say the next waiting line (or drop them all if it's gone).
    func resume() {
        guard current == nil, !pending.isEmpty else { return }
        guard agentIsReady || agent?.state == .connecting else {
            pending.forEach { onSpeak?($0.text, .normal, false) }
            pending.removeAll()
            return
        }
        guard !agentIsBusy else { return }
        speakNow(pending.removeFirst(), priority: .normal)
    }

    // MARK: - Speaking

    private func speakNow(_ line: Line, priority: SpeechPriority) {
        guard let agent, agent.isReady else {
            pending.insert(line, at: 0)  // still connecting: wait for it
            return
        }
        agent.interrupt()
        nextToken += 1
        let token = nextToken
        current = Current(token: token, priority: priority, line: line)
        onSpeak?(line.text, priority, true)
        // An urgent warning that hasn't started within 3 s is stale; anything else gets 8 s.
        agent.say(line.text, timeout: priority == .urgent ? 3 : 8,
                  onStart: { [weak self] in self?.started(token, at: CACurrentMediaTime()) },
                  onDone: { [weak self] _ in self?.ended(token) })
    }

    private func started(_ token: Int, at time: CFTimeInterval) {
        guard let current, current.token == token else { return }
        current.line.onStart?(time)
    }

    /// Called when a line finishes, is cut off, or came too late. Ignores lines already replaced.
    private func ended(_ token: Int) {
        guard current?.token == token else { return }
        current = nil
        resume()
    }
}
