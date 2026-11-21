import Foundation
import Observation
import QuartzCore

/// Tells the person when someone they saved comes into view, saves and forgets people, and knows
/// who's around. Recognition runs on the phone (`FaceMemory`), twice a second, and only while
/// someone is saved; `RecognitionTracker` decides who's in view and when to announce them.
@Observable
final class PeopleWatcher {
    private(set) var savedNames: [String] = []
    /// Off in Settings › People: nothing is scanned.
    var isEnabled = true
    /// Someone saved just came into view: (name, their face in the latest scan).
    @ObservationIgnored var onArrival: ((_ name: String, _ face: FaceMemory.Face) -> Void)?
    /// The latest scan's faces, and when it ran (for "who's here" and the laptop viewer).
    @ObservationIgnored private(set) var faces: [FaceMemory.Face] = []
    @ObservationIgnored private(set) var facesAt: CFTimeInterval = 0

    @ObservationIgnored private let memory = FaceMemory()
    @ObservationIgnored private var tracker = RecognitionTracker()
    @ObservationIgnored private var scanning = false
    @ObservationIgnored private var saving = false
    @ObservationIgnored private var lastScanAt: CFTimeInterval = 0

    init() {
        Task { savedNames = await memory.names }
    }

    /// Who's in view right now (matched in 2 of the last 3 scans).
    var inView: Set<String> { tracker.inView }

    /// The latest scan, if it's fresh.
    var currentFaces: [FaceMemory.Face] {
        CACurrentMediaTime() - facesAt < 1.5 ? faces : []
    }

    func setStrictness(_ value: Float) {
        Task { await memory.setStrictness(value) }
    }

    /// Called for every camera frame; scans about twice a second while someone is saved.
    func process(_ frame: Frame) {
        let now = CACurrentMediaTime()
        guard isEnabled, !savedNames.isEmpty, !scanning, !saving, now - lastScanAt >= 0.5,
              ProcessInfo.processInfo.thermalState != .critical else { return }
        lastScanAt = now
        scanning = true
        Task {
            let found = await memory.scan(frame)
            scanning = false
            faces = found
            facesAt = CACurrentMediaTime()
            let matched = Set(found.compactMap(\.name))
            for name in tracker.update(matched: matched, known: savedNames, now: facesAt) {
                if let face = found.first(where: { $0.name == name }) { onArrival?(name, face) }
            }
        }
    }

    /// Saves the face in front of the camera under `name`, from views collected over about 3 seconds.
    /// Returns what happened, for the agent to tell the person.
    func remember(_ rawName: String, latestFrame: () -> Frame?) async -> String {
        let name = Self.clean(rawName)
        guard !name.isEmpty else { return "I need a name to save them under. Ask what to call them." }
        saving = true
        defer { saving = false }
        await memory.beginSaving()
        var last = FaceMemory.Sample.noFace
        let deadline = CACurrentMediaTime() + 3.5
        while CACurrentMediaTime() < deadline {
            if let frame = latestFrame() {
                last = await memory.addSample(from: frame)
                if case .added(let count) = last, count >= 8 { break }
            }
            try? await Task.sleep(for: .milliseconds(200))
        }
        let result = await memory.finishSaving(as: name)
        savedNames = await memory.names
        switch result {
        case .new(let views):
            return "Saved \(name) from \(views) views of their face, on this phone only. The app will say when \(name) is in view. Remind them, briefly, to make sure \(name) is happy to be remembered; they can say forget \(name) at any time."
        case .updated(let views):
            return "Added \(views) more views of \(name)'s face, so the app recognizes them better."
        case .tooFew:
            return switch last {
            case .severalFaces: "Not saved: more than one face is in view. Ask \(name) to stand in front, closest to them, and try again."
            case .tooFar: "Not saved: the face is too far away. Ask \(name) to come within about 2 meters, facing the camera, and try again."
            case .turnedAway: "Not saved: the face is turned away or blurry. Ask \(name) to face the camera and keep still for 3 seconds, then try again."
            case .noFace, .added: "Not saved: I couldn't see a face clearly. Ask \(name) to face the camera, within about 2 meters, in good light, and try again."
            }
        }
    }

    func forget(_ name: String) async -> String {
        guard let removed = await memory.forget(Self.clean(name)) else {
            let saved = savedNames.isEmpty ? "No one is saved." : "Saved: \(savedNames.joined(separator: ", "))."
            return "No one called \(name) is saved. \(saved)"
        }
        savedNames = await memory.names
        return "Forgot \(removed). Their face is deleted from this phone."
    }

    /// "alex" → "Alex"; a name only, without punctuation, at most 30 characters.
    static func clean(_ name: String) -> String {
        let letters = name.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        let trimmed = String(letters.prefix(30))
        return trimmed.prefix(1).uppercased() + trimmed.dropFirst()
    }
}
