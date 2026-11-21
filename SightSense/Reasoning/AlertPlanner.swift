import Foundation

/// One thing to tell the user now.
struct Alert {
    enum Kind { case object, obstacle, dropOff, approaching, crowd }

    let kind: Kind
    let urgent: Bool
    let text: String
    /// Stereo position: -1 left … 1 right.
    let pan: Float
    /// When the underlying thing was first seen, for end-to-end latency.
    let firstSeenAt: Double
}

/// What the user asked to hear (Settings › What to announce).
struct AlertPolicy {
    var level = AnnouncementLevel.essential
    var categories: Set<ObjectCategory> = Set(ObjectCategory.allCases)
    var unnamedObstacles = true
    var verbosity = Verbosity.brief
    var units = DistanceUnit.steps
}

/// What's happening right now.
struct AlertContext {
    var now: Double
    var isWalking: Bool
    /// Direction the wearer faces (degrees), so things already mentioned stay recognized when they turn.
    var heading: Double?
}

/// Decides what is worth saying right now, and filters out the rest as noise.
///
/// Always said, whatever the settings: drop-offs, things approaching fast, and anything close
/// in your path. Beyond that it depends on context and the chosen level:
/// - essential: while walking, things in your path that you'll reach in the next few seconds;
/// - balanced: also things just beside your path, and crowds;
/// - everything: anything nearby, including signs and traffic lights.
/// Standing still, the surroundings aren't news: only safety alerts are spoken.
///
/// Noise filtering:
/// - each thing is said once. It's remembered by what it is and where it is in the world (using
///   the compass), so the detector losing and re-finding it, or you turning, doesn't make it new;
/// - it's repeated only when it becomes urgent, or, while walking, keeps getting closer while urgent;
/// - non-urgent alerts are at least 5 s apart;
/// - one alert per pass, most important first.
struct AlertPlanner {
    var policy = AlertPolicy()
    /// How many candidate alerts were held back as noise (debug overlay).
    private(set) var filtered = 0

    private struct Mention {
        let label: String
        let trackID: Int?
        let meters: Double
        let bearing: Double
        let heading: Double?
        let time: Double
        let urgent: Bool
        /// Last time it was still in view; it's forgotten 20 s after it's gone.
        var lastSeen: Double
    }

    private struct Candidate {
        let label: String
        let trackID: Int?
        let meters: Double
        let bearing: Double
        let alert: Alert
    }

    private var mentions: [Mention] = []
    private var lastNonUrgentAt = -Double.infinity

    mutating func plan(hazards: [Hazard], path: ConfirmedPath, context: AlertContext) -> Alert? {
        refreshMentions(hazards: hazards, path: path, context: context)
        mentions.removeAll { context.now - $0.lastSeen > 20 }
        for candidate in candidates(hazards: hazards, path: path, context: context) {
            if isNoise(candidate, context) {
                filtered += 1
                continue
            }
            mentions.append(Mention(label: candidate.label, trackID: candidate.trackID, meters: candidate.meters,
                                    bearing: candidate.bearing, heading: context.heading, time: context.now,
                                    urgent: candidate.alert.urgent, lastSeen: context.now))
            if !candidate.alert.urgent { lastNonUrgentAt = context.now }
            return candidate.alert
        }
        return nil
    }

    // MARK: - What's relevant now, most important first

    private func candidates(hazards: [Hazard], path: ConfirmedPath, context: AlertContext) -> [Candidate] {
        var list: [Candidate] = []

        // Safety: always, whatever the settings.
        if let drop = path.dropOff, drop.meters < 4 {
            let text = brief ? "Drop ahead, \(words(drop.meters))." : "Careful, the ground drops ahead, \(words(drop.meters))."
            list.append(Candidate(label: "drop", trackID: nil, meters: drop.meters, bearing: 0, alert: Alert(
                kind: .dropOff, urgent: drop.meters < 2, text: stop(drop.meters, inPath: true, context) + text,
                pan: 0, firstSeenAt: drop.firstSeenAt)))
        }
        for hazard in hazards where isApproachingFast(hazard) {
            let name = capitalized(hazard.name)
            let direction = self.direction(hazard.location.bearingDegrees)
            let text = brief ? "\(name) approaching, \(direction)." : "\(name) approaching fast, \(direction)."
            list.append(Candidate(label: "approach:\(hazard.object.label)", trackID: hazard.object.id,
                                  meters: hazard.location.meters, bearing: hazard.location.bearingDegrees, alert: Alert(
                kind: .approaching, urgent: true, text: text, pan: hazard.pan, firstSeenAt: hazard.object.firstSeenAt)))
        }
        for hazard in hazards where hazard.isUrgent {
            list.append(objectCandidate(hazard, urgent: true, context))
        }
        if let obstacle = path.obstacle, obstacle.meters < 1.5, !isNamed(obstacle, in: hazards) {
            list.append(obstacleCandidate(obstacle, urgent: true, context))
        }

        // Your path: things you'll reach in the next few seconds. Standing still, they aren't news.
        guard context.isWalking else { return list }
        for hazard in hazards where !hazard.isUrgent && hazard.location.isInPath && hazard.location.meters < 4.5 && wanted(hazard) {
            list.append(objectCandidate(hazard, urgent: false, context))
        }
        if policy.unnamedObstacles, let obstacle = path.obstacle, obstacle.meters >= 1.5, obstacle.meters < 3.5,
           !isNamed(obstacle, in: hazards) {
            list.append(obstacleCandidate(obstacle, urgent: false, context))
        }
        guard policy.level != .essential else { return list }

        // Balanced: just beside your path, and crowds.
        let people = policy.categories.contains(.people)
            ? hazards.filter { $0.object.label == "person" && $0.location.meters < 6 } : []
        let isCrowd = people.count >= 3
        if isCrowd, let nearest = people.min(by: { $0.location.meters < $1.location.meters }) {
            let bearing = people.map(\.location.bearingDegrees).reduce(0, +) / Double(people.count)
            let group = people.count >= 5 ? "Crowd" : "\(people.count) people"
            let text = brief ? "\(group) \(direction(bearing))." : "\(group) \(direction(bearing)), nearest \(words(nearest.location.meters))."
            list.append(Candidate(label: "crowd", trackID: nil, meters: nearest.location.meters, bearing: bearing, alert: Alert(
                kind: .crowd, urgent: false, text: text, pan: 0, firstSeenAt: nearest.object.firstSeenAt)))
        }
        for hazard in hazards where !hazard.isUrgent && !hazard.location.isInPath && hazard.location.pathGap < 1.2
            && hazard.location.meters < 4 && wanted(hazard) && !(isCrowd && hazard.object.label == "person") {
            list.append(objectCandidate(hazard, urgent: false, context))
        }
        guard policy.level == .everything else { return list }

        // Everything: anything else nearby worth naming.
        for hazard in hazards where !hazard.isUrgent && hazard.location.pathGap >= 1.2 && hazard.location.meters < 8
            && wanted(hazard) && !(isCrowd && hazard.object.label == "person") {
            list.append(objectCandidate(hazard, urgent: false, context))
        }
        return list
    }

    private func isApproachingFast(_ hazard: Hazard) -> Bool {
        guard let speed = hazard.closingSpeed, let seconds = hazard.secondsToContact else { return false }
        return speed > 2.2 && seconds < 3 && hazard.location.pathGap < 1.5
    }

    private func wanted(_ hazard: Hazard) -> Bool {
        policy.categories.contains(ObjectCatalog.info(for: hazard.object.label).category)
    }

    /// The depth scanner's obstacle is probably something the detector already named.
    private func isNamed(_ obstacle: PathFinding, in hazards: [Hazard]) -> Bool {
        hazards.contains { $0.location.isInPath && abs($0.location.meters - obstacle.meters) < 0.8 }
    }

    // MARK: - Noise filtering

    /// Things already mentioned that are still in view stay remembered, however long you stand there.
    private mutating func refreshMentions(hazards: [Hazard], path: ConfirmedPath, context: AlertContext) {
        var seen = hazards.map { (label: $0.object.label, trackID: Optional($0.object.id),
                                  meters: $0.location.meters, bearing: $0.location.bearingDegrees) }
        if let obstacle = path.obstacle { seen.append(("obstacle", nil, obstacle.meters, obstacle.bearingDegrees)) }
        if let drop = path.dropOff { seen.append(("drop", nil, drop.meters, 0)) }
        for index in mentions.indices {
            let mention = mentions[index]
            let stillThere = seen.contains { thing in
                isSameThing(mention, Candidate(label: thing.label, trackID: thing.trackID, meters: thing.meters,
                                               bearing: thing.bearing, alert: Self.placeholder), context)
                    || (mention.label.hasPrefix("approach:") && mention.trackID == thing.trackID)
                    || (mention.label == "crowd" && thing.label == "person")
            }
            if stillThere { mentions[index].lastSeen = context.now }
        }
    }

    private static let placeholder = Alert(kind: .object, urgent: false, text: "", pan: 0, firstSeenAt: 0)

    private func isNoise(_ candidate: Candidate, _ context: AlertContext) -> Bool {
        if !candidate.alert.urgent && context.now - lastNonUrgentAt < 5 { return true }
        guard let previous = mentions.last(where: { isSameThing($0, candidate, context) }) else { return false }
        if candidate.alert.urgent {
            if !previous.urgent { return false }  // it just became urgent
            let stillClosing = context.isWalking && context.now - previous.time >= 4 && candidate.meters < previous.meters - 0.3
            return !stillClosing
        }
        // Non-urgent: once is enough, unless a moving thing has swung to a clearly different side.
        let swung = abs(HeadingMath.relative(candidate.bearing, to: expectedBearing(of: previous, context))) >= 30
        return !(swung && candidate.trackID != nil && candidate.trackID == previous.trackID && context.now - previous.time >= 5)
    }

    /// Same kind of thing, in about the same place in the world (allowing for walking and turning).
    private func isSameThing(_ mention: Mention, _ candidate: Candidate, _ context: AlertContext) -> Bool {
        guard mention.label == candidate.label else { return false }
        if let id = candidate.trackID, id == mention.trackID { return true }
        guard abs(HeadingMath.relative(candidate.bearing, to: expectedBearing(of: mention, context))) < 25 else { return false }
        let walked = context.isWalking ? (context.now - mention.time) * 1.6 : 0.5
        return candidate.meters <= mention.meters + 1 && candidate.meters >= mention.meters - walked - 1
    }

    /// Where a mentioned thing should appear now, given how far the wearer has turned since.
    private func expectedBearing(of mention: Mention, _ context: AlertContext) -> Double {
        guard let now = context.heading, let then = mention.heading else { return mention.bearing }
        return mention.bearing - HeadingMath.relative(now, to: then)
    }

    // MARK: - Wording

    private func objectCandidate(_ hazard: Hazard, urgent: Bool, _ context: AlertContext) -> Candidate {
        let direction = self.direction(hazard.location.bearingDegrees)
        let distance = words(hazard.location.meters)
        let name = capitalized(hazard.name)
        let text = brief ? "\(name), \(direction), \(distance)." : "\(name) \(direction), \(distance)."
        return Candidate(label: hazard.object.label, trackID: hazard.object.id, meters: hazard.location.meters,
                         bearing: hazard.location.bearingDegrees, alert: Alert(
            kind: .object, urgent: urgent, text: stop(hazard.location.meters, inPath: hazard.location.isInPath, context) + text,
            pan: hazard.pan, firstSeenAt: hazard.object.firstSeenAt))
    }

    private func obstacleCandidate(_ obstacle: PathFinding, urgent: Bool, _ context: AlertContext) -> Candidate {
        let direction = self.direction(obstacle.bearingDegrees)
        let distance = words(obstacle.meters)
        let text = brief ? "Obstacle \(direction), \(distance)." : "Something in your path, \(direction), \(distance)."
        return Candidate(label: "obstacle", trackID: nil, meters: obstacle.meters, bearing: obstacle.bearingDegrees, alert: Alert(
            kind: .obstacle, urgent: urgent, text: stop(obstacle.meters, inPath: true, context) + text,
            pan: Float(max(-1, min(1, obstacle.bearingDegrees / 25))), firstSeenAt: obstacle.firstSeenAt))
    }

    private var brief: Bool { policy.verbosity == .brief }

    private func direction(_ degrees: Double) -> String {
        SpokenPosition.direction(degrees, brief: brief)
    }

    private func words(_ meters: Double) -> String {
        SpokenPosition.distance(meters, units: policy.units, brief: brief)
    }

    /// "Stop." only makes sense while walking into something close.
    private func stop(_ meters: Double, inPath: Bool, _ context: AlertContext) -> String {
        context.isWalking && meters < 1.5 && inPath ? "Stop. " : ""
    }

    private func capitalized(_ name: String) -> String {
        name.prefix(1).uppercased() + name.dropFirst()
    }
}
