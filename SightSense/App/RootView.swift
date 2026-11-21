import SwiftUI
import Translation

/// Laid out to be used by feel, without seeing the screen. Three full-width bands, top to bottom:
/// Describe, Ask, Read. Along the bottom edge, three buttons: Mode (left corner), Beeps (middle),
/// More (right corner). With the phone on the chest: volume down (or an AirPods click) asks,
/// volume up describes. Press and hold anywhere stops speech.
struct RootView: View {
    @Bindable var model: AppModel

    private var assistant: VoiceAssistant { model.assistant }
    private var agent: Agent { model.agent }
    private var inLive: Bool { model.mode == .live }

    var body: some View {
        VStack(spacing: 3) {
            zone(title: "Describe", systemImage: "eye",
                 hint: "Describes what is in front of you. Volume up does the same.",
                 background: Color(red: 0, green: 0.2, blue: 0.5), foreground: .white, action: model.describe)
            zone(title: askTitle, systemImage: askIcon, hint: askHint, value: askValue,
                 background: askBackground, foreground: .white, action: model.ask,
                 longPress: { model.showingQuickQuestions = true })
            zone(title: "Read", systemImage: "text.viewfinder",
                 hint: "Reads text in front of you, guiding you to aim, and translates it if needed.",
                 background: Color(red: 1, green: 0.84, blue: 0.04), foreground: .black, action: model.read)
            bottomBar
        }
        .background(.black)
        .overlay(alignment: .top) {
            #if DEBUG
            DebugOverlay(model: model)
            #endif
        }
        .sheet(isPresented: $model.showingSettings, onDismiss: model.applySettings) {
            SettingsView(settings: model.settings, viewer: model.viewer, people: model.people, onPlayTutorial: model.playTutorial)
        }
        .sheet(isPresented: $model.showingPlaces) {
            PlacesView(explorer: model.explorer, onWhereAmI: model.whereAmI,
                       onAroundMe: model.aroundMe, onAheadOfMe: model.aheadOfMe)
        }
        .confirmationDialog("Quick questions", isPresented: $model.showingQuickQuestions, titleVisibility: .visible) {
            ForEach(AppModel.quickQuestions, id: \.self) { question in
                Button(question) { model.submit(question) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Asked as if you had said it.")
        }
        .confirmationDialog("More", isPresented: $model.showingMenu, titleVisibility: .visible) {
            Button("Places: where am I, beacons") { model.showingPlaces = true }
            Button("Settings") { model.showingSettings = true }
            Button("What can I say?") { model.sayHelp() }
            Button("Play tutorial") { model.playTutorial() }
            Button("Cancel", role: .cancel) {}
        }
        .translationTask(model.reader.translationConfig) { session in
            await model.reader.translatePending(using: session)
        }
        .modifier(HardwareButtons(enabled: model.settings.hardwareButtons,
                                  onAsk: model.askButton(pressed:), onDescribe: model.describe))
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
    }

    private func zone(title: String, systemImage: String, hint: String, value: String = "",
                      background: Color, foreground: Color, action: @escaping () -> Void,
                      longPress: (() -> Void)? = nil) -> some View {
        TapZone(
            title: title, systemImage: systemImage, hint: hint, value: value,
            background: background, foreground: foreground,
            directTouch: model.settings.directTouch,
            onTap: action,
            onLongPress: longPress ?? model.stopSpeaking,
            swipes: Swipes(up: model.aheadOfMe, down: model.aroundMe,
                           left: model.fewerAnnouncements, right: model.moreAnnouncements),
            voiceActions: voiceActions,
            onMagicTap: model.ask
        )
    }

    // MARK: Ask band: what the agent is doing (in Live mode, tap mutes)

    private var listening: Bool { agent.isReady ? agent.isListening : assistant.isListening }

    private var askTitle: String {
        if inLive, agent.isReady { return agent.isMuted ? "Muted" : "Live" }
        if listening { return "Listening…" }
        return agent.isWorking ? "Working…" : "Ask"
    }

    private var askIcon: String {
        if inLive, agent.isReady { return agent.isMuted ? "mic.slash.fill" : "waveform.circle.fill" }
        return listening ? "waveform" : "mic.fill"
    }

    private var askHint: String {
        inLive
            ? "Live mode: just talk. Tap to mute or unmute. Press and hold for quick questions."
            : "Talk to the AI: ask a question, or say what you need, like: show me the way out. Press and hold for quick questions. Volume down does the same."
    }

    private var askValue: String {
        if listening { return "Listening" }
        switch agent.state {
        case .connecting: return "Connecting to the AI"
        case .unavailable where agent.isConfigured: return "AI offline; commands work on the phone"
        case .ready: return agent.said.isEmpty ? "" : "Last said: \(agent.said)"
        default: return assistant.lastHeard.isEmpty ? "" : "Last heard: \(assistant.lastHeard)"
        }
    }

    private var askBackground: Color {
        if inLive, agent.isReady { return agent.isMuted ? Color(white: 0.3) : Color(red: 0.36, green: 0.1, blue: 0.55) }
        return listening ? Color(red: 0.72, green: 0.06, blue: 0.06) : Color(red: 0, green: 0.36, blue: 0.16)
    }

    private var bottomBar: some View {
        let beepsOn = model.settings.beepMode != .off
        let icon = switch model.mode {
        case .navigate: "figure.walk"
        case .calm: "leaf.fill"
        case .live: "waveform.circle.fill"
        }
        return HStack(spacing: 3) {
            BarButton(title: model.mode.shortName, caption: "Mode",
                      systemImage: icon,
                      spoken: "Mode: \(model.mode.spokenName)",
                      hint: "Switches to \(model.mode.next.spokenName).",
                      action: model.switchMode)
            BarButton(title: beepsOn ? "On" : "Off", caption: "Beeps",
                      systemImage: beepsOn ? "speaker.wave.2.fill" : "speaker.slash.fill",
                      spoken: beepsOn ? "Beeps on, while walking" : "Beeps off",
                      hint: beepsOn ? "Turns proximity beeps off." : "Turns proximity beeps on, only while you walk.",
                      action: model.toggleBeeps)
            BarButton(title: "More", caption: "Places, settings",
                      systemImage: "ellipsis.circle.fill",
                      spoken: "More",
                      hint: "Places, settings, help, and the tutorial.",
                      action: { model.showingMenu = true })
        }
        .frame(height: 108)
    }

    private var voiceActions: [VoiceAction] {
        [
            VoiceAction(name: "Ask", action: model.ask),
            VoiceAction(name: "Quick questions", action: { model.showingQuickQuestions = true }),
            VoiceAction(name: "Show me the way out", action: { model.submit("Show me the way out") }),
            VoiceAction(name: "Where am I", action: model.whereAmI),
            VoiceAction(name: "What's around me", action: model.aroundMe),
            VoiceAction(name: "What's ahead of me", action: model.aheadOfMe),
            VoiceAction(name: "Fewer announcements", action: model.fewerAnnouncements),
            VoiceAction(name: "More announcements", action: model.moreAnnouncements),
            VoiceAction(name: "Switch mode", action: model.switchMode),
            VoiceAction(name: "Beeps on or off", action: model.toggleBeeps),
            VoiceAction(name: "Stop speaking", action: model.stopSpeaking),
        ]
    }
}
