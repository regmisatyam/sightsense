import CoreGraphics
import Foundation
import Observation
import QuartzCore

/// Decides what to say while guiding someone to a target. Pure logic, unit tested.
struct GuidanceCoach {
    enum Step: Equatable {
        case arrived(String)
        case update(String)
        case lost(String)
        case giveUp(String)
        case quiet
    }

    let name: String
    var units = DistanceUnit.steps
    private var last: (time: Double, direction: String, steps: Int?)?
    private var lostSince: Double?
    private var toldLost = false

    init(name: String, units: DistanceUnit = .steps) {
        self.name = name
        self.units = units
    }

    /// - bearing: degrees from straight ahead if the target was seen this time, else nil.
    /// - meters: its distance, if known.
    mutating func next(bearing: Double?, meters: Double?, label: String?, now: Double) -> Step {
        guard let bearing else {
            let since = lostSince ?? now
            lostSince = since
            if now - since >= 30 { return .giveUp("I can't find \(name) from here. Try turning around, or ask someone nearby.") }
            if now - since >= 4, !toldLost {
                toldLost = true
                return .lost("I've lost sight of it. Turn slowly toward the sound.")
            }
            return .quiet
        }
        lostSince = nil
        toldLost = false
        let thing = label.flatMap { $0.isEmpty ? nil : $0 } ?? name
        if let meters, meters < 1.0 {
            return .arrived("You're at the \(thing.replacingOccurrences(of: "the ", with: "")). It should be within arm's reach.")
        }

        let direction = SpokenPosition.direction(bearing, brief: true)
        let steps = meters.map { max(1, Int(($0 / SpokenPosition.stepLength).rounded())) }
        if let last {
            let turned = last.direction != direction && now - last.time >= 2
            let closer = steps.flatMap { now in last.steps.map { $0 - now >= 2 } } ?? false
            guard turned || closer || now - last.time >= 7 else { return .quiet }
        }
        last = (now, direction, steps)
        let distance = meters.map { SpokenPosition.distance($0, units: units, brief: true) }
        let capitalized = thing.prefix(1).uppercased() + thing.dropFirst()
        return .update(([capitalized, direction] + [distance].compactMap { $0 }).joined(separator: ", ") + ".")
    }
}

/// Something the spatial model pointed at: where in the image, and where in the world.
struct Sighting {
    let label: String
    /// Image point, normalized, top-left origin.
    let x: Double
    let y: Double
    let meters: Double?
    let bearing: Double
    let time: CFTimeInterval
}

/// Walks someone to something they can't see, like the way out. The spatial model keeps
/// re-finding it in the camera as they move, the 3D beacon sound points to it, and short updates
/// say which way and how far, until they arrive (or after 3 minutes). Obstacle warnings carry on
/// throughout, and take priority.
@Observable
final class WayFinder {
    private(set) var target: String?

    @ObservationIgnored private let speech: SpeechQueue
    @ObservationIgnored private let describer: SceneDescriber
    @ObservationIgnored private let fastLoop: FastLoop
    @ObservationIgnored private let explorer: Explorer
    @ObservationIgnored private let settings: Settings
    /// Where to get the newest camera frame.
    @ObservationIgnored var latestFrame: () -> Frame? = { nil }
    /// Each time it re-finds the target (for the laptop viewer).
    @ObservationIgnored var onSighting: ((Sighting) -> Void)?
    @ObservationIgnored private var task: Task<Void, Never>?

    init(speech: SpeechQueue, describer: SceneDescriber, fastLoop: FastLoop, explorer: Explorer, settings: Settings) {
        self.speech = speech
        self.describer = describer
        self.fastLoop = fastLoop
        self.explorer = explorer
        self.settings = settings
    }

    /// - query: what the spatial model should look for, e.g. "the way out: an exit door, …".
    /// - name: how to say it, e.g. "the way out".
    func start(query: String, name: String) {
        stop()
        target = name
        var coach = GuidanceCoach(name: name, units: settings.units)
        task = Task {
            let deadline = CACurrentMediaTime() + 180
            while !Task.isCancelled, CACurrentMediaTime() < deadline {
                guard let frame = latestFrame() else {
                    try? await Task.sleep(for: .milliseconds(500))
                    continue
                }
                let found = (try? await describer.find(query, in: frame))?.first
                guard !Task.isCancelled else { return }

                var bearing: Double?
                var meters: Double?
                if let found {
                    let angle = atan((found.x - 0.5) * 2 * tan(frame.camera.horizontalFOV / 2)) * 180 / .pi
                    bearing = angle
                    meters = fastLoop.distance(to: CGPoint(x: found.x, y: found.y))
                    explorer.guide(toward: found.label.isEmpty ? name : found.label, relativeBearing: angle)
                    onSighting?(Sighting(label: found.label.isEmpty ? name : found.label, x: found.x, y: found.y,
                                         meters: meters, bearing: angle, time: CACurrentMediaTime()))
                }
                switch coach.next(bearing: bearing, meters: meters, label: found?.label, now: CACurrentMediaTime()) {
                case .arrived(let text), .giveUp(let text):
                    finish(text)
                    return
                case .update(let text), .lost(let text):
                    speech.say(text)
                case .quiet:
                    break
                }
                try? await Task.sleep(for: .milliseconds(600))
            }
            if !Task.isCancelled { finish("Stopping guidance.") }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        target = nil
        explorer.stopGuiding()
    }

    private func finish(_ text: String) {
        speech.say(text)
        explorer.stopGuiding()
        target = nil
        task = nil
    }
}
