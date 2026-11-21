import CoreGraphics
import Observation
import QuartzCore
import UIKit

/// Wires the app together: camera → fast loop (on-device safety), the AI agent (the app's one
/// voice and brain, which acts through the tools in AgentTools.swift), Describe, Ask, Read, modes,
/// Calm narration, settings, the tutorial, and walk recording. Without a connection, everything
/// that can falls back to the phone (on-device speech recognition, REST answers); there's no second
/// voice, so while the AI is offline the app warns with sounds and vibration only.
@Observable
final class AppModel {
    private(set) var mode: AppMode = .navigate
    private(set) var preview: CGImage?  // debug overlay only
    var showingSettings = false
    var showingPlaces = false
    var showingMenu = false
    var showingQuickQuestions = false
    let settings: Settings
    let stats = FrameStats()
    let speech: SpeechQueue
    let fastLoop: FastLoop
    let reader: TextReader
    let recorder: WalkRecorder
    let explorer: Explorer
    let assistant: VoiceAssistant
    let agent: Agent
    let wayFinder: WayFinder
    /// The laptop viewer (Settings › Testing).
    let viewer = ViewerFeed()
    /// People the user saved, recognized on the phone.
    let people = PeopleWatcher()

    /// Long-press Ask: tap one to test without speaking.
    static let quickQuestions = [
        "What's in front of me?",
        "Show me the way out",
        "Find the door",
        "Is there an empty seat?",
        "Read the sign",
        "Is anyone in front of me?",
        "Where am I?",
        "What's around me?",
        "Look carefully, what's on the table?",
        "Save the person in front of me as Alex",
        "Who's here that I know?",
    ]

    @ObservationIgnored private let camera: any FrameSource
    @ObservationIgnored let describer: SceneDescriber
    @ObservationIgnored private let calm: CalmNarrator
    @ObservationIgnored private(set) var latestFrame: Frame?
    @ObservationIgnored let modelLog: ModelLog
    /// What Find or guidance last pointed at (shown in the laptop viewer).
    @ObservationIgnored var lastSighting: Sighting?
    @ObservationIgnored private var frameCount = 0
    @ObservationIgnored private var lastDescription: String?
    /// Instant Describe: a fresh quick description kept ready in the background.
    @ObservationIgnored private var readyLook: (sentences: [String], time: CFTimeInterval, focus: String)?
    @ObservationIgnored private var isPreparingLook = false
    @ObservationIgnored private var describeTask: Task<Void, Never>?
    @ObservationIgnored private var readTask: Task<Void, Never>?
    @ObservationIgnored private var started = false
    @ObservationIgnored private var wasInBackground = false
    @ObservationIgnored private var savedBrightness: CGFloat?
    @ObservationIgnored private var inBackground = false
    /// Ask held like a walkie-talkie: when it was pressed, and whether that press opened the mic.
    @ObservationIgnored private var askPressedAt: CFTimeInterval = 0
    @ObservationIgnored private var askPressOpenedMic = false

    init(settings: Settings, camera: any FrameSource) {
        let client = GeminiClient()
        let agent = Agent(client: client)
        let speech = SpeechQueue()
        speech.agent = agent
        let describer = SceneDescriber(client: client)
        let recorder = WalkRecorder()
        self.settings = settings
        self.camera = camera
        self.speech = speech
        self.describer = describer
        self.recorder = recorder
        fastLoop = FastLoop(speech: speech, settings: settings, recorder: recorder)
        reader = TextReader(speech: speech)
        calm = CalmNarrator(speech: speech, describer: describer)
        explorer = Explorer(speech: speech, settings: settings)
        assistant = VoiceAssistant(speech: speech, audio: fastLoop.audio)
        self.agent = agent
        modelLog = client.log
        wayFinder = WayFinder(speech: speech, describer: describer, fastLoop: fastLoop, explorer: explorer, settings: settings)

        assistant.onRequest = { [weak self] command, _ in self?.handle(command) }
        reader.onNoText = { [weak self] frame in self?.readWithAI(frame) }
        reader.onText = { [weak self] text in self?.readAloudByAgent(text) ?? false }
        wayFinder.latestFrame = { [weak self] in self?.latestFrame }
        agent.toolHandler = { [weak self] name, args in await self?.runTool(name, args) ?? "The app isn't ready." }
        agent.onIdle = { [weak speech] in speech?.resume() }
        agent.onDropped = { [weak self] in self?.agentDropped() }
        // The laptop viewer's corners.
        speech.onSpeak = { [weak viewer] text, priority, spoken in viewer?.logSpeech(text, priority: priority, spoken: spoken) }
        agent.onToolUsed = { [weak viewer] name, args, result in viewer?.logTool(name, args: args, result: result) }
        wayFinder.onSighting = { [weak self] sighting in self?.lastSighting = sighting }
        people.onArrival = { [weak self] name, face in self?.announceArrival(name, face) }
    }

    func start() {
        guard !started, !Self.isRunningTests else { return }
        started = true
        UIApplication.shared.isIdleTimerDisabled = true  // keep the camera running
        applySettings()
        Task {
            await AudioSession.configure()  // before speaking, so the silent switch can't mute us
            Task { await fastLoop.start() }
            if await connectAgent() {
                speech.say("SightSense ready. \(mode.spokenName).")
            } else {
                signalOffline()  // no voice without the AI; warnings still sound and buzz
            }
            if !settings.tutorialDone { playTutorial() }
        }
        explorer.start()
        Task { await runCamera() }
        Task { await runCalmMode() }
        Task { await runInstantDescribe() }
        Task { await keepAgentConnected() }
    }

    /// Re-reads settings that live outside the views (after the Settings sheet closes).
    func applySettings() {
        if agent.isReady, agent.voice != settings.aiVoice || agent.pace != settings.agentPace {
            agent.disconnect()  // the voice and pace are set when connecting
            Task { await connectAgent() }
        }
        calm.interval = Double(settings.calmIntervalSeconds)
        if settings.recordWalks { recorder.start() } else { recorder.stop() }
        viewer.setOn(settings.laptopViewer)
        people.isEnabled = settings.recognizePeople
        people.setStrictness(settings.faceStrictness.multiplier)
        dimScreen(settings.dimScreen)
    }

    func playTutorial() {
        speech.cancelNonUrgent()
        Tutorial.lines.forEach { speech.say($0) }
        settings.tutorialDone = true
    }

    // MARK: App lifecycle

    /// iOS stops the camera when the phone locks, so say so while we still can.
    func didEnterBackground() {
        wasInBackground = true
        inBackground = true
        dimScreen(false)
        let task = UIApplication.shared.beginBackgroundTask()
        speech.say("SightSense paused. Unlock your phone to continue.", priority: .urgent)
        Task {
            try? await Task.sleep(for: .seconds(3.5))  // let it finish saying so
            if inBackground { agent.disconnect() }
            UIApplication.shared.endBackgroundTask(task)
        }
    }

    func didBecomeActive() {
        inBackground = false
        guard wasInBackground else { return }
        wasInBackground = false
        UIApplication.shared.isIdleTimerDisabled = true
        dimScreen(settings.dimScreen)
        Task {
            await connectAgent()
            speech.say("SightSense resumed. \(mode.spokenName).")
        }
    }

    // MARK: The agent

    /// Connects the agent with the chosen voice and pace; restores Live mode's open microphone.
    @discardableResult
    private func connectAgent() async -> Bool {
        guard agent.isConfigured, !inBackground else { return false }
        let connected = await agent.connect(voice: settings.aiVoice, pace: settings.agentPace)
        agent.alwaysListening = mode == .live
        return connected
    }

    /// Tries again every 20 s while the AI can't be reached (no signal, server busy).
    private func keepAgentConnected() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(20))
            if agent.state == .unavailable, agent.isConfigured, !inBackground, await connectAgent() {
                speech.say("The AI is back.")
            }
        }
    }

    private func agentDropped() {
        if mode == .live { mode = .navigate }
        signalOffline()
    }

    /// The AI (and so the voice) is unavailable: two low notes and a buzz. Obstacle warnings keep
    /// sounding and buzzing; words come back with the connection ("The AI is back.").
    private func signalOffline() {
        fastLoop.audio.play(.offline)
        Haptics.tap()
    }

    /// Text the phone read, handed to the agent to read out (and translate if needed).
    private func readAloudByAgent(_ text: String) -> Bool {
        guard agent.isReady else { return false }
        let code = Locale.current.language.languageCode?.identifier ?? "en"
        let language = Locale(identifier: "en").localizedString(forLanguageCode: code) ?? "English"
        agent.request("""
            The phone read this text. Read it to them exactly as written. If it isn't in \(language), \
            say which language it is and read a \(language) translation instead:
            \(text)
            """)
        return true
    }

    // MARK: User actions

    /// Describe: instantly from the description kept ready in the background (Instant Describe),
    /// otherwise a fresh look with the fast model (or the smarter one for longer descriptions).
    func describe() {
        if agent.isReady {
            speech.cancelNonUrgent()
            let length = settings.describeDetailed ? "In four or five sentences" : "In one or two sentences"
            let task = SceneDescriber.task(for: settings.describeFocus, instruction: settings.describeInstruction)
            agent.request("They pressed Describe. \(length), \(task)")
            return
        }
        if let ready = freshLook(), describeTask == nil {
            speech.cancelNonUrgent()
            ready.forEach { speech.say($0) }
            lastDescription = ready.joined(separator: " ")
            readyLook = nil  // the next tap gets a newer one
            return
        }
        askAI(describeStyle(detailed: settings.describeDetailed), opening: "Looking.")
    }

    /// A spoken question for the AI, answered from what the camera sees, what the phone measured,
    /// and the places nearby. `deep` uses the strongest (slower) model.
    func answer(_ question: String, deep: Bool = false) {
        let style = SceneDescriber.Style.answer(
            question: question, measured: fastLoop.measurements(),
            places: explorer.placeSummaries(), units: settings.units, deep: deep)
        askAI(style, opening: deep ? "Looking carefully." : "Let me look.")
    }

    /// Find: the spatial model points at the thing; the phone works out direction and distance,
    /// and the beacon guides you toward it. If it isn't in view, the question goes to the AI,
    /// which also knows the nearby places.
    func find(_ target: String, question: String) {
        guard describeTask == nil else {
            speech.say("Still working on the last one.")
            return
        }
        guard let frame = latestFrame else {
            speech.say("The camera isn't ready yet.")
            return
        }
        speech.cancelNonUrgent()
        speech.say("Looking for \(target).")
        describeTask = Task {
            let found: [FoundThing]
            do {
                found = try await describer.find(target, in: frame)
            } catch {
                describeTask = nil
                speech.say(failureMessage(error))
                return
            }
            // Clear before any hand-off, so a follow-up request owns `describeTask` from here on.
            describeTask = nil
            guard !Task.isCancelled else { return }
            guard let first = found.first else {
                answer(question)  // maybe it's a place nearby, not something in view
                return
            }
            speech.say(locate(first, count: found.count, target: target, in: frame))
        }
    }

    /// On-device reading found nothing: let the AI read the frame.
    private func readWithAI(_ frame: Frame) {
        if agent.isReady {
            agent.request("The phone's text reader found no text. Read any text you can see in front of them; if there's none, say so in a few words.")
            return
        }
        guard describeTask == nil else { return }
        speech.say("I can't read it on the phone. Asking the AI.")
        describeTask = Task {
            await speakAI(.readText, about: frame)
            describeTask = nil
        }
    }

    private func describeStyle(detailed: Bool) -> SceneDescriber.Style {
        .describe(measured: fastLoop.measurements(), units: settings.units, focus: settings.describeFocus,
                  instruction: settings.describeInstruction, detailed: detailed)
    }

    private var lookFocus: String { "\(settings.describeFocus.rawValue)|\(settings.describeInstruction)" }

    /// How long a ready description stays fresh: shorter while walking, since the view changes.
    private var lookFreshness: Double { fastLoop.isStationary ? 20 : 8 }

    private func freshLook() -> [String]? {
        guard settings.instantDescribe, !settings.describeDetailed, let ready = readyLook,
              ready.focus == lookFocus, CACurrentMediaTime() - ready.time < lookFreshness + 2 else { return nil }
        return ready.sentences
    }

    private func askAI(_ style: SceneDescriber.Style, opening: String) {
        guard describeTask == nil else {
            speech.say("Still working on the last one.")
            return
        }
        guard let frame = latestFrame else {
            speech.say("The camera isn't ready yet.")
            return
        }
        speech.cancelNonUrgent()
        speech.say(opening)
        describeTask = Task {
            await speakAI(style, about: frame)
            describeTask = nil
        }
    }

    // MARK: Voice

    /// Ask: talk to the agent; it answers when you pause (tap again to finish sooner).
    /// In Live mode the mic is always open, so Ask mutes or unmutes it. Offline: on-phone commands.
    func ask() {
        guard agent.isReady else {
            assistant.toggle()
            return
        }
        if mode == .live {
            agent.isMuted.toggle()
            speech.say(agent.isMuted ? "Muted." : "Listening.")
        } else if agent.isListening {
            agent.stopListening()
            fastLoop.audio.play(.heard)
        } else {
            speech.cancelNonUrgent()
            agent.startListening()
            fastLoop.audio.play(.listening)
            Haptics.tap()
        }
    }

    /// Volume down / AirPods click: press and speak, or hold while talking (Live mode: mute toggle).
    func askButton(pressed: Bool) {
        guard agent.isReady else {
            assistant.button(pressed: pressed)
            return
        }
        let now = CACurrentMediaTime()
        if pressed {
            askPressedAt = now
            askPressOpenedMic = mode != .live && !agent.isListening
            ask()
        } else if askPressOpenedMic, agent.isListening, now - askPressedAt > 0.8 {
            agent.stopListening()  // held like a walkie-talkie: let go to finish
            fastLoop.audio.play(.heard)
        }
    }

    /// A typed or quick question, handled exactly as if it had been spoken: by the agent, which
    /// decides what to do (and which tools to use); offline, by the on-phone command parser.
    func submit(_ text: String) {
        guard agent.isReady else {
            handle(VoiceCommand.parse(text))
            return
        }
        speech.cancelNonUrgent()
        agent.ask(text)
    }

    func sayHelp() {
        speech.cancelNonUrgent()
        speech.say(VoiceCommand.helpText)
    }

    /// "Show me the way out", "take me to the door": keep finding it and steer there with sound.
    /// Returns a note for the agent when it asked for the guidance (then nothing is said here).
    @discardableResult
    func startGuidance(_ target: String, announce: Bool = true) -> String {
        let lower = target.lowercased()
        let wayOut = lower.contains("way out") || lower.contains("exit") || lower == "outside" || lower == "out"
        let query = wayOut ? "the way out of here: an exit door, an exit sign, a doorway, or an opening leading out" : target
        let name = wayOut ? "the way out" : target
        describeTask?.cancel()
        describeTask = nil
        if announce {
            speech.cancelNonUrgent()
            speech.say("Looking for \(name). Turn slowly; I'll guide you with sound.")
        }
        wayFinder.start(query: query, name: name)
        return "Guidance toward \(name) has started: the app searches with the camera, plays a sound from its direction, and announces direction, steps, and arrival itself. Tell them in a few words to turn slowly and follow the sound."
    }

    private func handle(_ command: VoiceCommand) {
        switch command {
        case .describe: describe()
        case .read: read()
        case .whereAmI: whereAmI()
        case .aroundMe: aroundMe()
        case .aheadOfMe: aheadOfMe()
        case .calmMode: setMode(.calm)
        case .navigationMode: setMode(.navigate)
        case .switchMode: switchMode()
        case .beepsOn: setBeeps(on: true)
        case .beepsOff: setBeeps(on: false)
        case .fewer: fewerAnnouncements()
        case .more: moreAnnouncements()
        case .stop: stopSpeaking()
        case .help: sayHelp()
        case .find(let target, let question): find(target, question: question)
        case .guide(let target): startGuidance(target)
        case .liveMode: setMode(.live)
        case .deepQuestion(let question): answer(question, deep: true)
        case .question(let question): answer(question)
        }
    }

    /// Tap Read to start guided reading; tap again to stop.
    func read() {
        if let readTask {
            readTask.cancel()
            self.readTask = nil
            speech.cancelNonUrgent()
            speech.say("Stopped reading.")
            return
        }
        speech.cancelNonUrgent()
        speech.say("Reading. Point the camera at the text.")
        readTask = Task {
            await reader.read(latestFrame: { [weak self] in self?.latestFrame })
            if !Task.isCancelled { readTask = nil }
        }
    }

    /// The Mode button: Navigation → Calm → Live (Live is skipped while the AI can't be reached).
    func switchMode() {
        setMode(mode.next == .live && !agent.isReady ? .navigate : mode.next)
    }

    func setMode(_ newMode: AppMode, announce: Bool = true) {
        if newMode == .live, !agent.isReady {
            if announce {
                speech.say(agent.isConfigured ? "Live mode needs the AI, which I can't reach right now." : "Live mode needs a Gemini key in the app.")
            }
            return
        }
        mode = newMode
        agent.isMuted = false
        agent.alwaysListening = newMode == .live
        if newMode == .calm { calm.reset() }
        guard announce else { return }
        speech.cancelNonUrgent()
        speech.say(newMode == .live ? "Live mode. I'm listening; just talk to me." : newMode.spokenName)
    }

    // MARK: Beeps

    func toggleBeeps() {
        setBeeps(on: settings.beepMode == .off)
    }

    func setBeeps(on: Bool) {
        settings.beepMode = on ? .path : .off
        speech.cancelNonUrgent()
        speech.say(on ? "Beeps on, while you walk." : "Beeps off.")
    }

    // MARK: Places (Soundscape-style)

    func whereAmI() { Task { await explorer.whereAmI() } }
    func aroundMe() { Task { await explorer.aroundMe() } }
    func aheadOfMe() { Task { await explorer.aheadOfMe() } }

    /// Swipe left = fewer announcements, swipe right = more. Says the new level.
    func adjustAnnouncements(by step: Int) {
        let words = shiftAnnouncements(by: step)
        speech.cancelNonUrgent()
        speech.say(words)
    }

    /// Changes the announcement level by `step` and describes the new one.
    func shiftAnnouncements(by step: Int) -> String {
        let levels = AnnouncementLevel.allCases
        let index = levels.firstIndex(of: settings.announcementLevel) ?? 0
        let next = levels[max(0, min(levels.count - 1, index + step))]
        settings.announcementLevel = next
        return next == levels[index] && step != 0
            ? (step < 0 ? "Already the fewest announcements. " : "Already announcing everything. ") + next.spoken
            : next.spoken
    }

    func fewerAnnouncements() { adjustAnnouncements(by: -1) }
    func moreAnnouncements() { adjustAnnouncements(by: 1) }

    func stopSpeaking() {
        wayFinder.stop()
        explorer.stopGuiding()
        readTask?.cancel()
        readTask = nil
        describeTask?.cancel()
        describeTask = nil
        agent.stopListening()
        speech.cancelNonUrgent()
        agent.interrupt(dropAnswer: true)  // and the answer it was about to give
    }

    // MARK: Loops

    private func runCamera() async {
        camera.start()
        for await frame in camera.frames {
            stats.frameArrived()
            latestFrame = frame
            // Fresh GPS speed only: a stale reading would say "walking" forever.
            fastLoop.gpsSpeed = explorer.compass.location.flatMap {
                $0.speed >= 0 && abs($0.timestamp.timeIntervalSinceNow) < 3 ? $0.speed : nil
            }
            fastLoop.process(frame)
            agent.send(frame)
            people.process(frame)
            if viewer.wantsSnapshot { viewer.publish(viewerSnapshot(for: frame), frame: frame) }
            explorer.update(magneticHeading: frame.motion?.heading)
            recorder.record(frame)
            #if DEBUG
            frameCount += 1
            if frameCount % 3 == 0 { preview = FrameImage.cgImage(frame) }
            #endif
        }
        speech.say("Camera unavailable. Check camera access in Settings.", priority: .urgent)
    }

    private func runCalmMode() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(1))
            guard mode == .calm else { continue }
            let location = explorer.compass.location?.coordinate
            let scene = SceneSnapshot(labels: Set(fastLoop.hazards.map(\.object.label)),
                                      latitude: location?.latitude, longitude: location?.longitude,
                                      heading: explorer.compass.heading)
            await calm.tick(
                frame: latestFrame,
                scene: scene,
                offlineLine: fastLoop.summary().map { "All calm. I notice \($0)." },
                canSpeak: { mode == .calm && fastLoop.isPathClear }
            )
        }
    }

    // MARK: AI answers

    /// Speaks Gemini's answer sentence by sentence as it streams in.
    private func speakAI(_ style: SceneDescriber.Style, about frame: Frame) async {
        var said: [String] = []
        do {
            let sentences = try await describer.describe(frame, style: style)
            for try await sentence in sentences {
                guard !Task.isCancelled else { return }
                speech.say(sentence)
                said.append(sentence)
            }
            if said.isEmpty {
                speech.say("I couldn't describe that. \(nearbySummary())")
            } else {
                lastDescription = said.joined(separator: " ")
            }
        } catch SceneDescriber.Failure.noKey {
            speech.say("Scene description needs a Gemini key. \(nearbySummary())")
        } catch SceneDescriber.Failure.badResponse {
            speech.say("The description service returned an error. \(nearbySummary())")
        } catch {
            if said.isEmpty { speech.say("I can't reach the description service. \(nearbySummary())") }
        }
    }

    private func failureMessage(_ error: Error) -> String {
        switch error as? SceneDescriber.Failure {
        case .noKey: "The AI needs a Gemini key. \(nearbySummary())"
        case .badResponse: "The AI service returned an error. \(nearbySummary())"
        default: "I can't reach the AI right now. \(nearbySummary())"
        }
    }

    /// Instant Describe (only while the agent isn't connected; the agent answers in under a second):
    /// every 8 s while walking (20 s standing), quietly prepare a quick description.
    private func runInstantDescribe() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(1))
            guard settings.instantDescribe, !settings.describeDetailed, describer.isConfigured, !agent.isReady,
                  describeTask == nil, !isPreparingLook, !assistant.isListening, let frame = latestFrame else { continue }
            if let ready = readyLook, ready.focus == lookFocus, CACurrentMediaTime() - ready.time < lookFreshness { continue }
            isPreparingLook = true
            let focus = lookFocus
            var sentences: [String] = []
            if let stream = try? await describer.describe(frame, style: describeStyle(detailed: false)) {
                do {
                    for try await sentence in stream { sentences.append(sentence) }
                } catch {
                    sentences = []
                }
            }
            if !sentences.isEmpty { readyLook = (sentences, frame.capturedAt, focus) }
            isPreparingLook = false
        }
    }

    /// Offline fallback built from on-device detections.
    private func nearbySummary() -> String {
        if let summary = fastLoop.summary() { return "Nearby: \(summary)." }
        return fastLoop.detectorSource == .loading ? "" : "I don't detect anything nearby."
    }

    // MARK: Screen

    /// Blind users don't need the display; dimming it saves a lot of battery.
    private func dimScreen(_ dim: Bool) {
        guard let screen = UIApplication.shared.connectedScenes.compactMap({ ($0 as? UIWindowScene)?.screen }).first else { return }
        if dim {
            if savedBrightness == nil { savedBrightness = screen.brightness }
            screen.brightness = 0.02
        } else if let saved = savedBrightness {
            screen.brightness = saved
            savedBrightness = nil
        }
    }

    private static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    #if DEBUG
    /// Starts a long low-priority line, then interrupts it with an urgent alert.
    func speechSelfTest() {
        speech.say("Here is a long, relaxed sentence about the trees, the sky, and the quiet street ahead, which should be cut off any moment now.", priority: .ambient)
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            speech.say("Stop. Obstacle ahead.", priority: .urgent)
        }
    }
    #endif
}
