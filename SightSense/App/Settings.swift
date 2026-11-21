import AVFoundation
import Observation

nonisolated enum Verbosity: String, CaseIterable, Sendable {
    case brief  // "Chair, left, 2 steps."
    case full   // "Chair to your left, 2 steps away."
}

nonisolated enum DistanceUnit: String, CaseIterable, Sendable {
    case steps, meters
}

/// How much of the surroundings to announce. Safety alerts are spoken at every level.
nonisolated enum AnnouncementLevel: String, CaseIterable, Sendable {
    /// While walking: only things in your path you'll reach in the next few seconds.
    case essential
    /// Also things just beside your path, and crowds.
    case balanced
    /// Anything nearby, once each, including signs and traffic lights.
    case everything

    var spoken: String {
        switch self {
        case .essential: "Announcing only what's in your way."
        case .balanced: "Announcing your path and things beside you."
        case .everything: "Announcing everything nearby."
        }
    }
}

nonisolated enum BeepMode: String, CaseIterable, Sendable {
    case off
    /// Only for something in your path, and only while walking.
    case path
    case always
}

/// Gemini voices to choose from (name, description).
nonisolated enum AIVoices {
    static let all: [(name: String, description: String)] = [
        ("Sulafat", "Warm"), ("Achird", "Friendly"), ("Aoede", "Breezy"),
        ("Charon", "Calm, deeper"), ("Puck", "Upbeat"), ("Kore", "Firm, clear"),
    ]
}

/// What Describe (the AI) should focus on.
/// How sure face recognition must be before it says someone is in view.
nonisolated enum FaceStrictness: String, CaseIterable, Sendable {
    case strict, balanced, relaxed

    /// Scales each saved person's match limit.
    var multiplier: Float {
        switch self {
        case .strict: 0.85
        case .balanced: 1
        case .relaxed: 1.2
        }
    }
}

nonisolated enum DescribeFocus: String, CaseIterable, Sendable {
    case path, place, text, people, custom
}

/// User preferences, saved on the device. Changes apply immediately unless noted.
@Observable
final class Settings {
    /// Height of the phone's camera above the floor, in meters. Drives every distance estimate.
    var chestHeight: Double { didSet { defaults.set(chestHeight, forKey: "chestHeight") } }
    var speechRate: Float { didSet { defaults.set(speechRate, forKey: "speechRate") } }
    var verbosity: Verbosity { didSet { defaults.set(verbosity.rawValue, forKey: "verbosity") } }
    var units: DistanceUnit { didSet { defaults.set(units.rawValue, forKey: "units") } }

    // What to announce
    var announcementLevel: AnnouncementLevel { didSet { defaults.set(announcementLevel.rawValue, forKey: "announcementLevel") } }
    var announcedCategories: Set<ObjectCategory> {
        didSet { defaults.set(announcedCategories.map(\.rawValue), forKey: "announcedCategories") }
    }
    /// Things in your path that the detector can't name (found by depth).
    var announceUnnamed: Bool { didSet { defaults.set(announceUnnamed, forKey: "announceUnnamed") } }
    var beepMode: BeepMode { didSet { defaults.set(beepMode.rawValue, forKey: "beepMode") } }
    /// Mention named places as you walk past them (Soundscape-style callouts).
    var placeCallouts: Bool { didSet { defaults.set(placeCallouts, forKey: "placeCallouts") } }

    // What the AI says
    var describeFocus: DescribeFocus { didSet { defaults.set(describeFocus.rawValue, forKey: "describeFocus") } }
    /// The user's own instruction when `describeFocus` is `.custom`, e.g. "Tell me shop names and doors."
    var describeInstruction: String { didSet { defaults.set(describeInstruction, forKey: "describeInstruction") } }
    var describeDetailed: Bool { didSet { defaults.set(describeDetailed, forKey: "describeDetailed") } }
    /// Calm Mode speaks at most this often, and only when the scene changed.
    var calmIntervalSeconds: Int { didSet { defaults.set(calmIntervalSeconds, forKey: "calmIntervalSeconds") } }
    /// Keep a fresh description ready in the background, so Describe answers instantly.
    var instantDescribe: Bool { didSet { defaults.set(instantDescribe, forKey: "instantDescribe") } }
    /// The agent's voice: the app's one voice for everything it says (a Gemini Live voice).
    var aiVoice: String { didSet { defaults.set(aiVoice, forKey: "aiVoice") } }

    // Device
    /// 0.5× ultra-wide lens: sees the floor much closer to your feet. Applies next launch.
    var wideCamera: Bool { didSet { defaults.set(wideCamera, forKey: "wideCamera") } }
    var dimScreen: Bool { didSet { defaults.set(dimScreen, forKey: "dimScreen") } }
    /// With VoiceOver on, taps go straight to the Describe / Read zones.
    var directTouch: Bool { didSet { defaults.set(directTouch, forKey: "directTouch") } }
    /// Volume down (or an AirPods click) = Ask, volume up = Describe, while SightSense is open.
    var hardwareButtons: Bool { didSet { defaults.set(hardwareButtons, forKey: "hardwareButtons") } }
    /// Save camera frames and alerts for later review (Files app → SightSense → Recordings).
    var recordWalks: Bool { didSet { defaults.set(recordWalks, forKey: "recordWalks") } }
    /// Say when people the user saved come into view (recognized on the phone).
    var recognizePeople: Bool { didSet { defaults.set(recognizePeople, forKey: "recognizePeople") } }
    var faceStrictness: FaceStrictness { didSet { defaults.set(faceStrictness.rawValue, forKey: "faceStrictness") } }
    /// Watch the camera, coordinates, and AI on a laptop browser (same Wi-Fi). Off by default.
    var laptopViewer: Bool { didSet { defaults.set(laptopViewer, forKey: "laptopViewer") } }
    var tutorialDone: Bool { didSet { defaults.set(tutorialDone, forKey: "tutorialDone") } }

    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        chestHeight = defaults.object(forKey: "chestHeight") as? Double ?? 1.3
        speechRate = defaults.object(forKey: "speechRate") as? Float ?? 0.5  // the middle: "natural" pace
        verbosity = Verbosity(rawValue: defaults.string(forKey: "verbosity") ?? "") ?? .brief
        units = DistanceUnit(rawValue: defaults.string(forKey: "units") ?? "") ?? .steps

        announcementLevel = AnnouncementLevel(rawValue: defaults.string(forKey: "announcementLevel") ?? "") ?? .essential
        announcedCategories = (defaults.stringArray(forKey: "announcedCategories"))
            .map { Set($0.compactMap(ObjectCategory.init(rawValue:))) } ?? Set(ObjectCategory.allCases)
        announceUnnamed = defaults.object(forKey: "announceUnnamed") as? Bool ?? true
        beepMode = BeepMode(rawValue: defaults.string(forKey: "beepMode") ?? "") ?? .path
        placeCallouts = defaults.object(forKey: "placeCallouts") as? Bool ?? false

        describeFocus = DescribeFocus(rawValue: defaults.string(forKey: "describeFocus") ?? "") ?? .path
        describeInstruction = defaults.string(forKey: "describeInstruction") ?? ""
        describeDetailed = defaults.bool(forKey: "describeDetailed")
        calmIntervalSeconds = defaults.object(forKey: "calmIntervalSeconds") as? Int ?? 60
        instantDescribe = defaults.object(forKey: "instantDescribe") as? Bool ?? true
        aiVoice = defaults.string(forKey: "aiVoice") ?? "Sulafat"

        wideCamera = defaults.object(forKey: "wideCamera") as? Bool ?? true
        dimScreen = defaults.object(forKey: "dimScreen") as? Bool ?? true
        directTouch = defaults.object(forKey: "directTouch") as? Bool ?? true
        hardwareButtons = defaults.object(forKey: "hardwareButtons") as? Bool ?? true
        recordWalks = defaults.bool(forKey: "recordWalks")
        laptopViewer = defaults.bool(forKey: "laptopViewer")
        recognizePeople = defaults.object(forKey: "recognizePeople") as? Bool ?? true
        faceStrictness = FaceStrictness(rawValue: defaults.string(forKey: "faceStrictness") ?? "") ?? .balanced
        tutorialDone = defaults.bool(forKey: "tutorialDone")
    }

    /// How fast the agent speaks, from the speaking speed slider.
    var agentPace: String {
        speechRate < 0.47 ? "relaxed" : speechRate > 0.56 ? "brisk" : "natural"
    }

    var alertPolicy: AlertPolicy {
        AlertPolicy(level: announcementLevel, categories: announcedCategories,
                    unnamedObstacles: announceUnnamed, verbosity: verbosity, units: units)
    }
}
