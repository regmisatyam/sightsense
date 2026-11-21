import SwiftUI

/// Settings, laid out for VoiceOver and for a sighted helper doing first-time setup.
struct SettingsView: View {
    @Bindable var settings: Settings
    /// The laptop viewer: started and stopped right away by its switch, so its address shows here.
    let viewer: ViewerFeed
    let people: PeopleWatcher
    let onPlayTutorial: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                bodySection
                announceSection
                describeSection
                peopleSection
                speechSection
                modelsSection
                deviceSection
                testingSection
                Section {
                    Button("Play tutorial") {
                        dismiss()
                        onPlayTutorial()
                    }
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var bodySection: some View {
        Section {
            Stepper(value: $settings.chestHeight, in: 0.9...1.7, step: 0.05) {
                Text("Camera height: \(settings.chestHeight, format: .number.precision(.fractionLength(2))) m")
            }
        } header: {
            Text("Your body")
        } footer: {
            Text("Measure from the floor to where the phone sits on your chest. Every distance depends on this.")
        }
    }

    // MARK: What to announce

    private var announceSection: some View {
        Section {
            Picker("Announce", selection: $settings.announcementLevel) {
                Text("Only what's in my way").tag(AnnouncementLevel.essential)
                Text("Also things beside me").tag(AnnouncementLevel.balanced)
                Text("Everything nearby").tag(AnnouncementLevel.everything)
            }
            ForEach(ObjectCategory.allCases, id: \.self) { category in
                Toggle(category.title, isOn: categoryBinding(category))
            }
            Toggle("Unnamed obstacles (poles, walls, bins)", isOn: $settings.announceUnnamed)
            Picker("Beeps", selection: $settings.beepMode) {
                Text("Off").tag(BeepMode.off)
                Text("For my path, while walking").tag(BeepMode.path)
                Text("Always").tag(BeepMode.always)
            }
            Toggle("Announce places as I walk past", isOn: $settings.placeCallouts)
        } header: {
            Text("What to announce")
        } footer: {
            Text("Each thing is said once, and only when it matters: standing still, your surroundings stay quiet. Drop-offs, things coming at you fast, and anything about to block you are always announced. Swipe left or right on the main screen for fewer or more announcements.")
        }
    }

    private func categoryBinding(_ category: ObjectCategory) -> Binding<Bool> {
        Binding(
            get: { settings.announcedCategories.contains(category) },
            set: { isOn in
                if isOn { settings.announcedCategories.insert(category) } else { settings.announcedCategories.remove(category) }
            }
        )
    }

    // MARK: What the AI says

    private var describeSection: some View {
        Section {
            Picker("Describe focuses on", selection: $settings.describeFocus) {
                Text("My path and obstacles").tag(DescribeFocus.path)
                Text("The place and landmarks").tag(DescribeFocus.place)
                Text("Signs and text").tag(DescribeFocus.text)
                Text("People").tag(DescribeFocus.people)
                Text("My own instruction").tag(DescribeFocus.custom)
            }
            if settings.describeFocus == .custom {
                TextField("For example: tell me shop names and where the doors are", text: $settings.describeInstruction, axis: .vertical)
                    .accessibilityLabel("Your instruction for descriptions")
            }
            Toggle("Longer descriptions", isOn: $settings.describeDetailed)
            Picker("Calm Mode speaks at most every", selection: $settings.calmIntervalSeconds) {
                Text("30 seconds").tag(30)
                Text("1 minute").tag(60)
                Text("2 minutes").tag(120)
                Text("5 minutes").tag(300)
            }
            Toggle("Instant Describe when offline", isOn: $settings.instantDescribe)
            Picker("Voice", selection: $settings.aiVoice) {
                ForEach(AIVoices.all, id: \.name) { voice in
                    Text("\(voice.name) (\(voice.description))").tag(voice.name)
                }
            }
        } header: {
            Text("What the AI says")
        } footer: {
            Text("Everything is said in one natural voice: the AI's own, which you pick here. It watches through the camera (one photo a second, faces blurred, sent to Google Gemini) and answers in under a second. If the AI can't be reached you'll hear two low notes; obstacle warnings keep sounding and buzzing, and words return with the connection. Calm Mode only speaks when something changed.")
        }
    }

    private var peopleSection: some View {
        Section {
            Toggle("Tell me when saved people are in view", isOn: $settings.recognizePeople)
                .onChange(of: settings.recognizePeople) { _, on in people.isEnabled = on }
            Picker("Recognition", selection: $settings.faceStrictness) {
                Text("Strict: fewer mix-ups").tag(FaceStrictness.strict)
                Text("Balanced").tag(FaceStrictness.balanced)
                Text("Relaxed: recognizes more often").tag(FaceStrictness.relaxed)
            }
            .onChange(of: settings.faceStrictness) { _, value in people.setStrictness(value.multiplier) }
            if people.savedNames.isEmpty {
                Text("No one saved yet. Tap Ask and say: save the person in front of me as Alex.")
                    .foregroundStyle(.secondary)
            }
            ForEach(people.savedNames, id: \.self) { name in
                LabeledContent(name) {
                    Button("Forget", role: .destructive) { Task { _ = await people.forget(name) } }
                        .accessibilityLabel("Forget \(name)")
                }
            }
        } header: {
            Text("People")
        } footer: {
            Text("Saved faces stay on this phone as numeric signatures, never photos, and are never sent to Gemini or anywhere else (not even backups). Recognition only knows people you saved; it never identifies strangers. Ask people before saving them. It's tuned for a few people in decent light and can mix up similar-looking people; Strict says names less often but more reliably.")
        }
    }

    private var modelsSection: some View {
        Section {
            ForEach(GeminiModels.Role.allCases, id: \.self) { role in
                LabeledContent(role.purpose, value: models.model(for: role))
                    .accessibilityElement(children: .combine)
            }
        } header: {
            Text("AI models")
        } footer: {
            Text("Each job uses the Gemini model that suits it, with a fallback if one is unavailable. Change them in Config/Secrets.xcconfig.")
        }
    }

    private var models: GeminiModels { GeminiModels(info: Bundle.main.infoDictionary ?? [:]) }

    // MARK: Speech, device, testing

    private var speechSection: some View {
        Section("Speech") {
            VStack(alignment: .leading) {
                Text("Speaking speed")
                Slider(value: $settings.speechRate, in: 0.4...0.65)
                    .accessibilityLabel("Speaking speed")
                    .accessibilityValue(settings.agentPace)
            }
            Picker("Alerts", selection: $settings.verbosity) {
                Text("Brief: Chair, left, 2 steps").tag(Verbosity.brief)
                Text("Full: Chair to your left, 2 steps away").tag(Verbosity.full)
            }
            Picker("Distances in", selection: $settings.units) {
                Text("Steps").tag(DistanceUnit.steps)
                Text("Meters").tag(DistanceUnit.meters)
            }
        }
    }

    private var deviceSection: some View {
        Section {
            Toggle("Wide view (0.5× lens)", isOn: $settings.wideCamera)
            Toggle("Dim screen to save battery", isOn: $settings.dimScreen)
            Toggle("Direct touch with VoiceOver", isOn: $settings.directTouch)
            Toggle("Volume buttons control SightSense", isOn: $settings.hardwareButtons)
        } header: {
            Text("Camera, screen, buttons, and touch")
        } footer: {
            Text("Wide view sees the floor about 1 meter ahead instead of 2; it applies the next time the app starts. Direct touch lets taps and swipes reach the main screen while VoiceOver is on. With volume buttons on, volume down (or an AirPods click) asks, and volume up describes; change volume in Control Center or on your headphones.")
        }
    }

    private var testingSection: some View {
        Section {
            Toggle("Record walks", isOn: $settings.recordWalks)
            Toggle("Laptop viewer", isOn: $settings.laptopViewer)
                .onChange(of: settings.laptopViewer) { _, on in viewer.setOn(on) }
            if settings.laptopViewer {
                LabeledContent("Status", value: viewerStatus)
                    .accessibilityElement(children: .combine)
                if viewer.addresses.isEmpty {
                    Text("No network yet: join Wi-Fi, or turn on Personal Hotspot.").foregroundStyle(.secondary)
                }
                ForEach(viewer.addresses, id: \.self) { address in
                    LabeledContent(address.label, value: address.url)
                        .textSelection(.enabled)
                        .accessibilityElement(children: .combine)
                }
            }
        } header: {
            Text("Testing")
        } footer: {
            Text("Record walks saves camera frames and alerts on this phone only (Files › On My iPhone › SightSense › Recordings), about 30 MB a minute. Laptop viewer shows the camera with distances and coordinates drawn on it, and what the AI hears, says, and does: type the address into a browser on a laptop on the same network. Faces are blurred; nothing leaves your network. Page won't load? Many office, school, and café Wi-Fi networks stop devices from reaching each other. Turn on Personal Hotspot on this iPhone, join it from the laptop (over Wi-Fi, or with the USB cable), and use the Personal Hotspot address.")
        }
        .onAppear { viewer.refresh() }
    }

    private var viewerStatus: String {
        switch viewer.status {
        case .starting: "Starting…"
        case .ready: viewer.watching == 0 ? "Ready, no laptop connected yet" : "\(viewer.watching) laptop\(viewer.watching == 1 ? "" : "s") watching"
        case .noLocalNetworkAccess: "Blocked: turn on Settings › Privacy & Security › Local Network › SightSense"
        case .failed(let reason): "Not working: \(reason)"
        }
    }
}
