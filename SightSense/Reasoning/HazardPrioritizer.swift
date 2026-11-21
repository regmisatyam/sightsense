import Foundation

/// A tracked object with its position and how much it matters.
struct Hazard {
    let object: TrackedObject
    let location: ObjectLocation
    let score: Double

    var name: String { ObjectCatalog.spokenName(for: object.label) }

    /// Stereo position for beeps: -1 left … 1 right.
    var pan: Float { Float(max(-1, min(1, location.bearingDegrees / 25))) }

    /// Close, and in or right next to the walking path.
    var isUrgent: Bool { location.closeness == .near && location.pathGap < 0.7 }

    /// Closing speed in m/s, from how fast its image grows. Includes the wearer's own walking.
    var closingSpeed: Double? { object.growthRate.map { location.meters * $0 } }

    /// Seconds until it reaches the wearer at the current closing speed.
    var secondsToContact: Double? {
        guard let growth = object.growthRate, growth > 0.05 else { return nil }
        return 1 / growth
    }

    /// "a person slightly left, about 4 steps away"
    func summary(units: DistanceUnit) -> String {
        let article = "aeiou".contains(name.prefix(1)) ? "an" : "a"
        let direction = SpokenPosition.direction(location.bearingDegrees)
        return "\(article) \(name) \(direction), \(SpokenPosition.distance(location.meters, units: units))"
    }
}

/// Scores each tracked object: class weight × closeness × how much it is in the walking path.
struct HazardPrioritizer {
    static let beepThreshold = 0.15

    var estimator = DistanceEstimator()

    /// All objects as hazards, most important first.
    func rank(_ objects: [TrackedObject], camera: CameraGeometry) -> [Hazard] {
        objects.map { object in
            let location = estimator.locate(label: object.label, box: object.box, camera: camera)
            let closeness = min(1, max(0.2, 1.25 - 0.2 * location.meters))  // 1 at ≤1 m … 0.25 at 5 m
            let inPath = location.isInPath ? 1 : max(0.25, 1 - (location.pathGap - 0.4) / 1.5)
            let score = ObjectCatalog.info(for: object.label).danger * closeness * inPath
            return Hazard(object: object, location: location, score: score)
        }
        .sorted { $0.score > $1.score }
    }
}
