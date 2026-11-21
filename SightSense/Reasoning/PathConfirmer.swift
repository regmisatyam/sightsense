import Foundation

/// A depth finding that has held up over several scans.
struct PathFinding {
    let meters: Double
    let bearingDegrees: Double
    /// When it was first seen, for end-to-end latency.
    let firstSeenAt: Double
}

struct ConfirmedPath {
    var obstacle: PathFinding?
    var dropOff: PathFinding?
}

/// Monocular depth is noisy, so a finding is trusted only when it appears in 3 of the last
/// 4 scans at a consistent distance. Its distance is the median of those scans.
struct PathConfirmer {
    private var obstacles = History()
    private var drops = History()
    private var lastScanAt: Double?

    mutating func update(_ scan: PathScan, at time: Double) -> ConfirmedPath {
        if let last = lastScanAt, time - last > 1.5 {  // stale: start over
            obstacles = History()
            drops = History()
        }
        lastScanAt = time
        guard scan.reliable else { return current }
        obstacles.add(scan.obstacle, at: time)
        drops.add(scan.dropOff, at: time)
        return current
    }

    var current: ConfirmedPath {
        ConfirmedPath(obstacle: obstacles.confirmed, dropOff: drops.confirmed)
    }

    private struct History {
        private var entries: [(finding: PathScan.Finding?, time: Double)] = []

        mutating func add(_ finding: PathScan.Finding?, at time: Double) {
            entries.append((finding, time))
            if entries.count > 4 { entries.removeFirst() }
        }

        var confirmed: PathFinding? {
            let hits = entries.compactMap { entry in entry.finding.map { (finding: $0, time: entry.time) } }
            guard hits.count >= 3 else { return nil }
            let distances = hits.suffix(3).map(\.finding.meters).sorted()
            let median = distances[1]
            guard distances[2] - distances[0] < 0.3 + 0.2 * median else { return nil }
            return PathFinding(meters: median, bearingDegrees: hits.last!.finding.bearingDegrees,
                               firstSeenAt: hits.first!.time)
        }
    }
}
