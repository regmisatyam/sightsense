import AVFoundation

/// The connection to the Gemini Live agent: camera frames, the microphone (only while the person
/// is talking to it), and text go up; the agent's voice and tool calls come down. It can't hear
/// itself: with earphones its voice doesn't reach the mic, and on the phone's speaker the mic pauses
/// while it talks. Reconnects with a resumption handle when the server asks. Everything here is
/// `nonisolated`: audio and network callbacks arrive on their own threads.
nonisolated final class AgentSession: @unchecked Sendable {
    nonisolated struct Config: Sendable {
        let endpoint: URL
        let models: [String]
        let voice: String
        let pace: String
        /// False if the person hasn't allowed the microphone: the agent can still speak.
        let microphone: Bool
    }

    nonisolated enum Event: Sendable {
        /// The agent's voice started playing.
        case speechStarted
        /// The agent finished a turn and everything it said has been heard (or it was cut off).
        case speechFinished
        case userText(String)
        case aiText(String)
        case toolCall(id: String, name: String, args: [String: String])
        /// The connection dropped and couldn't be restored.
        case ended
    }

    /// Delivered on an arbitrary thread.
    var onEvent: (@Sendable (Event) -> Void)?

    private let lock = NSLock()
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var socket: URLSessionWebSocketTask?
    private var config: Config?
    private var model: String?
    private var resumeHandle: String?
    private var converter: AVAudioConverter?
    private var routeObservers: [NSObjectProtocol] = []
    private var active = false
    /// Sound goes to earphones, so the mic can stay open while the agent talks (you can talk over it).
    private var onHeadphones = false
    /// On the speaker, the mic stays paused until the agent's voice has died away.
    private var micPausedUntil: TimeInterval = 0
    private var audioStarted = false
    private var listening = false
    // The agent's current turn:
    private var generating = false      // the server is sending a turn
    private var playing = false         // we told the app speech started
    private var queuedBuffers = 0       // scheduled but not yet heard
    private var turnDone = false        // turnComplete arrived; finish once the queue drains
    private var droppingSince: TimeInterval?  // a cut-off turn's leftovers: ignored until it ends

    /// Connects to the first model that answers and starts the audio engine. Returns the model used.
    @concurrent func start(_ config: Config) async -> String? {
        lock.withLock { self.config = config }
        for model in config.models {
            guard await connect(model: model, handle: nil) else { continue }
            do {
                try startAudio()
                return model
            } catch {
                print("Agent audio: \(error)")
                stop()
                return nil
            }
        }
        return nil
    }

    func stop() {
        let (socket, observers) = lock.withLock { () -> (URLSessionWebSocketTask?, [NSObjectProtocol]) in
            active = false
            listening = false
            audioStarted = false
            defer {
                self.socket = nil
                routeObservers = []
            }
            return (self.socket, routeObservers)
        }
        socket?.cancel(with: .normalClosure, reason: nil)
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        engine.inputNode.removeTap(onBus: 0)
        if engine.isRunning { engine.stop() }
        player.stop()
    }

    /// Opens or closes the microphone to the agent. Closing tells it the person has finished.
    func setListening(_ value: Bool) {
        let wasListening = lock.withLock { () -> Bool in
            defer { listening = value }
            return listening
        }
        if wasListening && !value { send(AgentProtocol.audioStreamEnd) }
    }

    func sendFrame(_ jpeg: Data) { send(AgentProtocol.video(jpeg)) }
    func sendText(_ text: String) { send(AgentProtocol.text(text)) }
    func sendSay(_ words: String) { send(AgentProtocol.say(words)) }
    func sendContext(_ facts: String) { send(AgentProtocol.context(facts)) }
    func sendResult(of tool: String, _ text: String) { send(AgentProtocol.result(of: tool, text)) }
    func respond(toolCall id: String, name: String, result: String) {
        send(AgentProtocol.toolResponse(id: id, name: name, result: result))
    }

    /// Stops the agent's voice now (something more important needs the floor). If it was still
    /// answering, the rest of that answer is dropped when it arrives. `dropPending` also drops a
    /// turn that was asked for but hasn't started yet (it came too late to be useful).
    func interruptOutput(dropPending: Bool = false) {
        let finishNow = lock.withLock { () -> Bool in
            if generating || dropPending { droppingSince = ProcessInfo.processInfo.systemUptime }
            let wasPlaying = playing
            resetTurn()
            return wasPlaying
        }
        player.stop()
        if engine.isRunning { player.play() }
        if finishNow { onEvent?(.speechFinished) }
    }

    /// Only call with the lock held.
    private func resetTurn() {
        if playing { micPausedUntil = ProcessInfo.processInfo.systemUptime + 0.4 }
        generating = false
        playing = false
        queuedBuffers = 0
        turnDone = false
    }

    // MARK: - Connection

    private func connect(model: String, handle: String?) async -> Bool {
        guard let config = lock.withLock({ self.config }) else { return false }
        let socket = URLSession.shared.webSocketTask(with: config.endpoint)
        socket.maximumMessageSize = 8 << 20
        socket.resume()
        // Give up on this model if setup isn't confirmed within 8 s.
        let watchdog = Task {
            try? await Task.sleep(for: .seconds(8))
            if !Task.isCancelled { socket.cancel(with: .goingAway, reason: nil) }
        }
        defer { watchdog.cancel() }
        do {
            let setup = AgentProtocol.setup(model: model, voice: config.voice, pace: config.pace, resumeHandle: handle)
            try await socket.send(.string(Self.json(setup)))
            while true {
                if AgentProtocol.parse(Self.data(of: try await socket.receive())).contains(.setupComplete) { break }
            }
        } catch {
            print("Agent: \(model) didn't start (\(socket.closeCode.rawValue))")
            socket.cancel(with: .goingAway, reason: nil)
            return false
        }
        lock.withLock {
            self.socket = socket
            self.model = model
            active = true
        }
        receive(on: socket)
        return true
    }

    private func receive(on socket: URLSessionWebSocketTask) {
        Task.detached { [weak self] in
            while true {
                guard let self, lock.withLock({ self.socket === socket && active }) else { return }
                guard let message = try? await socket.receive() else {
                    await connectionLost(socket)
                    return
                }
                for event in AgentProtocol.parse(Self.data(of: message)) {
                    handle(event, from: socket)
                }
            }
        }
    }

    private func handle(_ event: AgentIncoming, from socket: URLSessionWebSocketTask) {
        switch event {
        case .audio(let pcm):
            play(pcm)
        case .interrupted, .turnComplete:
            endTurn(cutOff: event == .interrupted)
        case .aiText(let text):
            if !isDropping() { onEvent?(.aiText(text)) }
        case .userText(let text):
            onEvent?(.userText(text))
        case .toolCall(let id, let name, let args):
            onEvent?(.toolCall(id: id, name: name, args: args))
        case .resumeHandle(let handle):
            lock.withLock { resumeHandle = handle }
        case .goAway:
            Task { await reconnect(replacing: socket) }
        case .setupComplete:
            break
        }
    }

    /// Dropping ends with the cut-off turn, or after 4 s in case that turn never comes.
    private func isDropping() -> Bool {
        lock.withLock {
            guard let since = droppingSince else { return false }
            if ProcessInfo.processInfo.systemUptime - since > 4 { droppingSince = nil }
            return droppingSince != nil
        }
    }

    private func play(_ pcm: Data) {
        guard !isDropping() else { return }
        let started = lock.withLock { () -> Bool in
            generating = true
            queuedBuffers += 1
            defer { playing = true }
            return !playing
        }
        guard let buffer = PCM.floatBuffer(from: pcm) else {
            bufferHeard()
            return
        }
        if started { onEvent?(.speechStarted) }
        if !engine.isRunning { try? engine.start() }
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            self?.bufferHeard()
        }
        if engine.isRunning, !player.isPlaying { player.play() }
    }

    private func bufferHeard() {
        let finished = lock.withLock { () -> Bool in
            queuedBuffers = max(0, queuedBuffers - 1)
            guard turnDone, queuedBuffers == 0, playing else { return false }
            resetTurn()
            return true
        }
        if finished { onEvent?(.speechFinished) }
    }

    private func endTurn(cutOff: Bool) {
        let finished = lock.withLock { () -> Bool in
            if droppingSince != nil {  // the leftovers of an answer we already cut off
                droppingSince = nil
                return false
            }
            generating = false
            if cutOff || queuedBuffers == 0 {
                let wasPlaying = playing
                resetTurn()
                return wasPlaying
            }
            turnDone = true
            return false
        }
        if cutOff {
            player.stop()
            if engine.isRunning { player.play() }
        }
        if finished { onEvent?(.speechFinished) }
    }

    private func connectionLost(_ socket: URLSessionWebSocketTask) async {
        let stillWanted = lock.withLock { self.socket === socket && active }
        guard stillWanted else { return }
        await reconnect(replacing: socket)
    }

    /// Picks the conversation up again on a new connection (same model, same memory).
    private func reconnect(replacing old: URLSessionWebSocketTask) async {
        let (model, handle) = lock.withLock { () -> (String?, String?) in
            guard self.socket === old, active else { return (nil, nil) }
            self.socket = nil
            return (self.model, resumeHandle)
        }
        guard let model else { return }
        old.cancel(with: .goingAway, reason: nil)
        if await connect(model: model, handle: handle) { return }
        lock.withLock { active = false }
        onEvent?(.ended)
    }

    private func send(_ message: [String: Any]) {
        guard let socket = lock.withLock({ active ? self.socket : nil }),
              let text = try? Self.json(message) else { return }
        socket.send(.string(text)) { error in
            if let error { print("Agent send: \(error.localizedDescription)") }
        }
    }

    // MARK: - Audio

    private func startAudio() throws {
        guard !lock.withLock({ audioStarted }) else { return }
        try buildAudio()
        // A new route (earphones in or out, a call ending) stops the engine; wire it up again.
        let center = NotificationCenter.default
        let observers = [
            center.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { [weak self] _ in
                self?.routeChanged()
            },
            center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: nil) { [weak self] _ in
                self?.updateRoute()
            },
        ]
        lock.withLock {
            routeObservers = observers
            audioStarted = true
        }
    }

    /// Connects the agent's voice and (if allowed) the microphone for the current route, and starts.
    private func buildAudio() throws {
        updateRoute()
        if lock.withLock({ config?.microphone ?? false }) {
            do {
                try attachMicrophone()
            } catch {
                print("Agent microphone unavailable: \(error)")  // it can still speak
            }
        }
        if player.engine == nil { engine.attach(player) }
        engine.connect(player, to: engine.mainMixerNode, format: PCM.speech)
        engine.prepare()
        try engine.start()
        player.play()
    }

    private func attachMicrophone() throws {
        let input = engine.inputNode
        input.removeTap(onBus: 0)
        let hardware = input.outputFormat(forBus: 0)
        guard hardware.sampleRate > 0, hardware.channelCount > 0 else { return }
        let converter = AVAudioConverter(from: hardware, to: PCM.microphone)
        lock.withLock { self.converter = converter }
        input.installTap(onBus: 0, bufferSize: 2048, format: hardware) { [weak self] buffer, _ in
            self?.capture(buffer)
        }
    }

    private func updateRoute() {
        let headphones = AudioSession.headphonesConnected
        lock.withLock { onHeadphones = headphones }
    }

    private func routeChanged() {
        guard lock.withLock({ audioStarted }) else { return }
        do {
            try buildAudio()
        } catch {
            print("Agent audio restart: \(error)")
        }
    }

    /// Microphone audio → 16 kHz 16-bit mono → the agent, only while it's listening, and (on the
    /// speaker) not while its own voice is playing.
    private func capture(_ buffer: AVAudioPCMBuffer) {
        guard buffer.frameLength > 0, let converter = lock.withLock({ () -> AVAudioConverter? in
            let hearsItself = !onHeadphones && (playing || ProcessInfo.processInfo.systemUptime < micPausedUntil)
            return listening && active && !hearsItself ? self.converter : nil
        }) else { return }
        let ratio = PCM.microphone.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: PCM.microphone, frameCapacity: capacity) else { return }
        let source = SourceOnce(buffer)
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in source.next(status) }
        guard error == nil, output.frameLength > 0, let samples = output.int16ChannelData else { return }
        send(AgentProtocol.audio(Data(bytes: samples[0], count: Int(output.frameLength) * 2)))
    }

    private static func json(_ message: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: message), as: UTF8.self)
    }

    private static func data(of message: URLSessionWebSocketTask.Message) -> Data {
        switch message {
        case .data(let data): data
        case .string(let text): Data(text.utf8)
        @unknown default: Data()
        }
    }
}

/// Hands one buffer to an AVAudioConverter, then reports "no more data for now".
nonisolated private final class SourceOnce: @unchecked Sendable {
    private var buffer: AVAudioPCMBuffer?

    init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }

    func next(_ status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
        guard let buffer else {
            status.pointee = .noDataNow
            return nil
        }
        self.buffer = nil
        status.pointee = .haveData
        return buffer
    }
}
