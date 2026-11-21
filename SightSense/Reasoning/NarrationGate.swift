import Foundation

/// What Calm Mode compares to decide whether anything changed.
struct SceneSnapshot {
    var labels: Set<String> = []
    var latitude: Double?
    var longitude: Double?
    var heading: Double?

    /// Walked on at least 15 m, turned at least 45°, or the things around are mostly different.
    func differs(from other: SceneSnapshot) -> Bool {
        if let lat = latitude, let lon = longitude, let lat0 = other.latitude, let lon0 = other.longitude {
            let north = (lat - lat0) * 110_540
            let east = (lon - lon0) * 111_320 * cos(lat * .pi / 180)
            if (north * north + east * east).squareRoot() >= 15 { return true }
        }
        if let heading, let previous = other.heading, abs(HeadingMath.relative(heading, to: previous)) >= 45 {
            return true
        }
        let union = labels.union(other.labels)
        guard union.count >= 2 else { return false }
        return Double(labels.intersection(other.labels).count) / Double(union.count) <= 0.5
    }
}

/// Keeps Calm Mode from repeating itself: it speaks no more often than the chosen interval, and
/// only when the scene changed, with one gentle update if nothing changes for five minutes.
struct NarrationGate {
    var minInterval: Double = 60
    var quietLimit: Double = 300
    private var last: (time: Double, scene: SceneSnapshot)?

    func shouldNarrate(_ scene: SceneSnapshot, now: Double) -> Bool {
        guard let last else { return true }
        let elapsed = now - last.time
        guard elapsed >= minInterval else { return false }
        return scene.differs(from: last.scene) || elapsed >= quietLimit
    }

    mutating func didNarrate(_ scene: SceneSnapshot, now: Double) {
        last = (now, scene)
    }
}
