import Foundation

/// Everyday words for where something is, so a listener can picture it without numbers or degrees.
/// The same vocabulary is used for alerts, offline summaries, and Gemini's descriptions.
nonisolated enum SpokenPosition {
    /// Meters per ordinary walking step.
    static let stepLength = 0.7

    /// Full: "straight ahead", "slightly left", "to your right". Brief: "ahead", "slight left", "right".
    static func direction(_ degrees: Double, brief: Bool = false) -> String {
        let side = degrees < 0 ? "left" : "right"
        switch abs(degrees) {
        case ..<6: return brief ? "ahead" : "straight ahead"
        case ..<15: return brief ? "slight \(side)" : "slightly \(side)"
        case ..<28: return brief ? side : "to your \(side)"
        default: return "far \(side)"
        }
    }

    /// Full: "within arm's reach", "2 steps away", "about 4 steps away", "far away".
    /// Brief: "arm's reach", "2 steps", "4 steps". Meters: "1.5 meters", "about 4 meters away".
    static func distance(_ meters: Double, units: DistanceUnit = .steps, brief: Bool = false) -> String {
        if meters < 0.75 { return brief ? "arm's reach" : "within arm's reach" }
        switch units {
        case .meters:
            if meters > 15 { return "far away" }
            let value = meters < 3 ? String(format: "%.1f", meters) : "\(Int(meters.rounded()))"
            return brief ? "\(value) meters" : "about \(value) meters away"
        case .steps:
            let steps = max(1, Int((meters / stepLength).rounded()))
            if steps > 12 { return "far away" }
            let unit = steps == 1 ? "step" : "steps"
            if brief { return "\(steps) \(unit)" }
            return steps <= 2 ? "\(steps) \(unit) away" : "about \(steps) steps away"
        }
    }

    /// Direction to a place, which can be anywhere around you: "ahead", "ahead to your left",
    /// "to your right", "behind you". `relative`: 0 ahead, negative left, positive right.
    static func placeDirection(_ relative: Double) -> String {
        let side = relative < 0 ? "left" : "right"
        switch abs(relative) {
        case ..<15: return "ahead"
        case ..<45: return "ahead to your \(side)"
        case ..<135: return "to your \(side)"
        default: return "behind you"
        }
    }

    /// Distance to a place: steps up close, then rounded meters, then kilometers.
    static func placeDistance(_ meters: Double, units: DistanceUnit = .steps) -> String {
        if meters < 9 { return distance(meters, units: units) }
        if meters < 100 { return "about \(Int((meters / 5).rounded()) * 5) meters" }
        if meters < 1000 { return "about \(Int((meters / 10).rounded()) * 10) meters" }
        return String(format: "about %.1f kilometers", meters / 1000)
    }

    /// How to tell Gemini to use the same words as the alerts.
    static func vocabularyRule(units: DistanceUnit) -> String {
        let distance = units == .steps
            ? "in walking steps (one step is about 70 centimeters)"
            : "in meters"
        return """
        Say directions only as "straight ahead", "slightly left", "slightly right", "to your left", or "to your right". \
        Say distances only \(distance), or "within arm's reach".
        """
    }
}
