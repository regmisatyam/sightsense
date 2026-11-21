import Foundation

/// Decides which saved person (if any) a face is. Pure, unit tested.
nonisolated enum FaceMatcher {
    /// How much closer the best match must be than the next person, so similar-looking people
    /// aren't mixed up.
    static let margin: Float = 0.06

    /// - distances[i]: how far the face is from saved person i (their closest saved view).
    /// - limits[i]: how close counts as them.
    /// Returns the matching index (nil if none), and the best distance and its limit (for tuning).
    static func decide(distances: [Float], limits: [Float]) -> (index: Int?, best: Float?, limit: Float?) {
        guard let best = distances.indices.min(by: { distances[$0] < distances[$1] }) else { return (nil, nil, nil) }
        let runnerUp = distances.indices.filter { $0 != best }.map { distances[$0] }.min() ?? .infinity
        let isMatch = distances[best] <= limits[best] && runnerUp - distances[best] >= margin
        return (isMatch ? best : nil, distances[best], limits[best])
    }

    /// How close counts as the same person, from how much their own saved views differ:
    /// 1.6 × the 90th percentile of the distances between them, kept between 0.32 and 0.5.
    /// (Measured scale: a slightly shifted crop of the same thing ≈ 0.22; different things ≈ 0.9–1.2.)
    static func limit(ownDistances: [Float]) -> Float {
        guard !ownDistances.isEmpty else { return 0.4 }
        let sorted = ownDistances.sorted()
        let p90 = sorted[min(sorted.count - 1, Int(Float(sorted.count - 1) * 0.9))]
        return min(0.5, max(0.32, p90 * 1.6))
    }
}

/// Turns per-scan face matches into "in view", and decides when to announce someone. Pure, unit tested.
/// - In view: matched in at least 2 of the last 3 scans (one stray match isn't enough).
/// - Gone: no match in the last 3 scans.
/// - Announced when they come into view, at most once every 2 minutes per person.
struct RecognitionTracker {
    static let repeatAfter: Double = 120

    private var recent: [String: [Bool]] = [:]
    private var lastAnnounced: [String: Double] = [:]
    private(set) var inView: Set<String> = []

    /// One scan's matches. Returns who just came into view and should be announced.
    mutating func update(matched: Set<String>, known: [String], now: Double) -> [String] {
        var arrivals: [String] = []
        for name in known {
            var scans = recent[name, default: []]
            scans.append(matched.contains(name))
            if scans.count > 3 { scans.removeFirst(scans.count - 3) }
            recent[name] = scans
            let hits = scans.filter { $0 }.count
            if hits >= 2, !inView.contains(name) {
                inView.insert(name)
                if lastAnnounced[name].map({ now - $0 >= Self.repeatAfter }) ?? true {
                    lastAnnounced[name] = now
                    arrivals.append(name)
                }
            } else if hits == 0 {
                inView.remove(name)
            }
        }
        recent = recent.filter { known.contains($0.key) }  // forgotten people
        inView.formIntersection(known)
        return arrivals
    }
}
