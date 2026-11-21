import AVFoundation
import Observation
import QuartzCore

/// SightSense's AI agent: one Gemini Live conversation that runs the whole time the app is open.
/// - It sees through the camera continuously and hears the person when they talk to it
///   (press Ask, or always in Live mode).
/// - It is the app's one voice: its answers, and the exact words the app hands it (alerts,
///   guidance, hints), all in the same natural voice.
/// - It acts through tools: measuring, finding and guiding, reading, places, and changing the
///   app's settings (see `AgentProtocol.tools` and `AppModel.runTool`).
@Observable
final class Agent {
    enum State: Equatable { case off, connecting, ready, unavailable }

    private(set) var state = State.off
    private(set) var isListening = false
    private(set) var isSpeaking = false
    /// A slow tool (looking closely, finding, reading, places) is working.
    private(set) var isWorking = false
    /// What the person said last, and what the agent said last (for VoiceOver and the screen).
    private(set) var heard = ""
    private(set) var said = ""
    /// Live mode: the microphone stays open, hands-free.
    var alwaysListening = false { didSet { updateMicrophone() } }
    var isMuted = false { didSet { updateMicrophone() } }

    /// Runs a tool the agent called and returns the result it should hear.
    @ObservationIgnored var toolHandler: ((_ name: String, _ args: [String: String]) async -> String)?
    /// The agent finished speaking or connecting; queued app speech can go next.
    @ObservationIgnored var onIdle: (() -> Void)?
    /// The connection dropped and couldn't be restored.
    @ObservationIgnored var onDropped: (() -> Void)?
    /// A tool finished, with what the agent was told (for the laptop viewer).
    @ObservationIgnored var onToolUsed: ((_ name: String, _ args: [String: String], _ result: String) -> Void)?

    @ObservationIgnored private let client: GeminiClient
    @ObservationIgnored private var session: AgentSession?
    @ObservationIgnored private(set) var voice = ""
    @ObservationIgnored private(set) var pace = ""
    @ObservationIgnored private var lastFrameAt: CFTimeInterval = 0
    @ObservationIgnored private var sendingFrame = false
    @ObservationIgnored private var pendingSay: PendingSay?
    @ObservationIgnored private var listenWatchdog: Task<Void, Never>?
    /// Something was asked and the answer hasn't finished yet (cleared after 15 s at most).
    @ObservationIgnored private var awaitingAnswer = false
    @ObservationIgnored private var answerWatchdog: Task<Void, Never>?
    @ObservationIgnored private var toolsRunning = 0
    @ObservationIgnored private var slowToolsRunning = 0
    /// Slow-tool results waiting for the app's current line to finish.
    @ObservationIgnored private var pendingResults: [(tool: String, text: String)] = []
    @ObservationIgnored private var heardTurn = ""
    @ObservationIgnored private var saidTurn = ""

    private struct PendingSay {
        let onStart: () -> Void
        let onDone: (_ spoken: Bool) -> Void
        let watchdog: Task<Void, Never>
        var started = false
    }

    init(client: GeminiClient) {
        self.client = client
    }

    var isReady: Bool { state == .ready }
    /// There's a key that allows a live connection.
    var isConfigured: Bool { client.liveEndpoint != nil }

    /// Busy with its own turn (answering, or using a tool): app speech that isn't urgent waits.
    var isAnswering: Bool {
        awaitingAnswer || toolsRunning > 0 || (isSpeaking && pendingSay == nil)
    }

    // MARK: - Connection

    /// Connects (trying each Live model in turn). False if there's no key or no connection.
    /// - pace: how fast it speaks ("relaxed", "natural", "brisk").
    func connect(voice: String, pace: String) async -> Bool {
        switch state {
        case .ready: return true
        case .connecting: return false
        case .off, .unavailable: break
        }
        guard let endpoint = client.liveEndpoint else {
            state = .unavailable
            return false
        }
        self.voice = voice
        self.pace = pace
        state = .connecting
        defer { onIdle?() }
        let microphone = await AVAudioApplication.requestRecordPermission()
        let session = AgentSession()
        session.onEvent = { [weak self] event in Task { @MainActor in self?.handle(event) } }
        self.session = session
        let models = client.models.chain(for: .live).map(\.model)
        let model = await session.start(.init(endpoint: endpoint, models: models, voice: voice, pace: pace,
                                               microphone: microphone))
        guard self.session === session else {
            session.stop()
            return false
        }
        guard model != nil else {
            self.session = nil
            state = .unavailable
            return false
        }
        state = .ready
        updateMicrophone()
        return true
    }

    func disconnect() {
        session?.stop()
        session = nil
        state = .off
        reset()
    }

    private func reset() {
        isListening = false
        isSpeaking = false
        isWorking = false
        awaitingAnswer = false
        toolsRunning = 0
        slowToolsRunning = 0
        pendingResults.removeAll()
        finishSay(spoken: false)
    }

    // MARK: - Speaking for the app

    /// Says exactly `words` in the agent's voice. `onDone(false)` if it couldn't start within
    /// `timeout` seconds (or isn't connected): then it isn't said at all, rather than late.
    func say(_ words: String, timeout: Double, onStart: @escaping () -> Void, onDone: @escaping (_ spoken: Bool) -> Void) {
        guard let session, state == .ready else {
            onDone(false)
            return
        }
        pendingSay?.watchdog.cancel()
        let watchdog = Task { [weak self] in
            try? await Task.sleep(for: .seconds(timeout))
            guard !Task.isCancelled, let self, let pending = pendingSay, !pending.started else { return }
            self.session?.interruptOutput(dropPending: true)  // too late to be useful; don't say it twice
            finishSay(spoken: false)
        }
        pendingSay = PendingSay(onStart: onStart, onDone: onDone, watchdog: watchdog)
        session.sendSay(words)
    }

    /// Stops the agent's voice now. An app line that hasn't started yet is dropped too; so is an answer
    /// that hasn't started, if `dropAnswer` (the person said stop). Otherwise a new question replaces it
    /// on the server, which ends the old answer itself.
    func interrupt(dropAnswer: Bool = false) {
        let unstarted = pendingSay.map { !$0.started } ?? false
        session?.interruptOutput(dropPending: unstarted || (dropAnswer && awaitingAnswer))
        pendingSay?.watchdog.cancel()
        pendingSay = nil
        setAwaiting(false)
    }

    // MARK: - Asking

    /// A question or request as if the person had said it.
    func ask(_ text: String) {
        guard let session, state == .ready else { return }
        setAwaiting(true)
        session.sendText(text)
    }

    /// An instruction from the app ("[APP] …") that the agent answers by speaking to the person.
    func request(_ instruction: String) {
        ask("[APP] \(instruction)")
    }

    /// Facts for the agent to keep in mind; it doesn't reply.
    func tell(_ facts: String) {
        guard state == .ready else { return }
        session?.sendContext(facts)
    }

    /// Opens the microphone until the agent starts answering, `stopListening()`, or 12 s.
    func startListening() {
        guard state == .ready else { return }
        isListening = true
        setAwaiting(true)
        updateMicrophone()
        listenWatchdog?.cancel()
        listenWatchdog = Task { [weak self] in
            try? await Task.sleep(for: .seconds(12))
            if !Task.isCancelled { self?.stopListening() }
        }
    }

    func stopListening() {
        listenWatchdog?.cancel()
        guard isListening else { return }
        isListening = false
        updateMicrophone()
    }

    /// Sends a camera frame once a second (Gemini Live looks at video at 1 frame per second);
    /// encoding and face blurring happen off the main thread.
    func send(_ frame: Frame) {
        guard state == .ready, !sendingFrame, let session, CACurrentMediaTime() - lastFrameAt >= 1 else { return }
        lastFrameAt = CACurrentMediaTime()
        sendingFrame = true
        Task.detached { [weak self] in
            if let jpeg = FrameImage.jpeg(frame, maxSide: 640, quality: 0.6, blurFaces: true) {
                session.sendFrame(jpeg)
            }
            await MainActor.run { self?.sendingFrame = false }
        }
    }

    // MARK: - Events

    private func updateMicrophone() {
        session?.setListening(isListening || (alwaysListening && !isMuted))
    }

    private func setAwaiting(_ value: Bool) {
        answerWatchdog?.cancel()
        awaitingAnswer = value
        guard value else { return }
        answerWatchdog = Task { [weak self] in
            try? await Task.sleep(for: .seconds(15))
            guard !Task.isCancelled, let self else { return }
            awaitingAnswer = false
            onIdle?()
        }
    }

    private func handle(_ event: AgentSession.Event) {
        switch event {
        case .speechStarted:
            isSpeaking = true
            if isListening && !alwaysListening { stopListening() }  // it heard the question and is answering
            if let pending = pendingSay, !pending.started {
                pendingSay?.started = true
                pending.watchdog.cancel()
                pending.onStart()
            }
        case .speechFinished:
            isSpeaking = false
            heardTurn = ""
            saidTurn = ""
            if pendingSay?.started == true {
                finishSay(spoken: true)
            } else {
                setAwaiting(false)  // its own answer is done
            }
            if !pendingResults.isEmpty {
                let next = pendingResults.removeFirst()
                deliver(next.text, of: next.tool)
            }
            onIdle?()
        case .userText(let text):
            heardTurn += text
            heard = heardTurn
        case .aiText(let text):
            saidTurn += text
            said = saidTurn
        case .toolCall(let id, let name, let args):
            run(tool: name, id: id, args: args)
        case .ended:
            session = nil
            state = .unavailable
            reset()
            onDropped?()
            onIdle?()
        }
    }

    /// Quick tools answer the call directly. Slow ones answer "Started" at once and send the result
    /// later, so the conversation (and any urgent alert) never waits on them.
    private func run(tool name: String, id: String, args: [String: String]) {
        guard let session else { return }
        if AgentProtocol.slowTools.contains(name) {
            session.respond(toolCall: id, name: name, result: "Started. The result will follow in a few seconds.")
            slowToolsRunning += 1
            isWorking = true
            Task {
                let result = await toolHandler?(name, args) ?? "That isn't available."
                onToolUsed?(name, args, result)
                slowToolsRunning -= 1
                isWorking = slowToolsRunning > 0
                deliver(result, of: name)
            }
        } else {
            toolsRunning += 1
            Task {
                let result = await toolHandler?(name, args) ?? "That isn't available."
                onToolUsed?(name, args, result)
                toolsRunning -= 1
                setAwaiting(true)  // it will tell them the result
                self.session?.respond(toolCall: id, name: name, result: result)
            }
        }
    }

    /// A slow tool's result, told to the person once the app's current line (if any) is done.
    private func deliver(_ result: String, of tool: String) {
        guard let session, state == .ready else { return }
        if pendingSay != nil {
            pendingResults.append((tool, result))
            return
        }
        setAwaiting(true)
        session.sendResult(of: tool, result)
    }

    private func finishSay(spoken: Bool) {
        guard let pending = pendingSay else { return }
        pending.watchdog.cancel()
        pendingSay = nil
        pending.onDone(spoken)
    }
}
