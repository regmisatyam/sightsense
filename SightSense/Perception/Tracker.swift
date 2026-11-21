import CoreGraphics

/// An object that has been seen in several consecutive detection passes.
struct TrackedObject {
    let id: Int
    let label: String
    /// Smoothed box, normalized, top-left origin.
    let box: CGRect
    /// Capture time of the frame where it was first detected, for end-to-end latency.
    let firstSeenAt: Double
    /// How fast the box grows, as a fraction of its height per second (positive = getting closer).
    /// Nil until there's enough history, or while the box is cut off by the frame edge.
    let growthRate: Double?
}

/// Follows objects across frames. Each track's position and size are smoothed with an
/// alpha-beta filter (a lightweight Kalman filter), and matching uses the *predicted* box,
/// so moving objects and crowds keep their identities.
/// An object is reported after 3 consecutive sightings, or 2 if it is big (close).
struct Tracker {
    private struct Track {
        let id: Int
        let label: String
        var box: CGRect
        var velocity: CGVector        // center movement per second
        var heightRate: Double        // box height change per second
        var hits: Int
        var misses: Int
        let firstSeenAt: Double
        var lastSeenAt: Double

        func predicted(at time: Double) -> CGRect {
            let dt = time - lastSeenAt
            return box.offsetBy(dx: velocity.dx * dt, dy: velocity.dy * dt)
        }
    }

    private var tracks: [Track] = []
    private var nextID = 1
    private let alpha = 0.6, beta = 0.25   // filter gains: how much to trust each new measurement
    private let minOverlap: CGFloat = 0.25
    private static let forgetAfterMisses = 2

    /// Feeds one detection pass captured at `time` (seconds). Returns confirmed objects seen in it.
    mutating func update(_ detections: [Detection], at time: Double) -> [TrackedObject] {
        var unmatched = Set(tracks.indices)
        var seen: [Int] = []

        for detection in detections.sorted(by: { $0.confidence > $1.confidence }) {
            let best = unmatched
                .filter { tracks[$0].label == detection.label }
                .map { (index: $0, score: matchScore(tracks[$0].predicted(at: time), detection.box)) }
                .max { $0.score < $1.score }

            if let best, best.score >= minOverlap {
                unmatched.remove(best.index)
                var track = tracks[best.index]
                correct(&track, with: detection, at: time)
                tracks[best.index] = track
                seen.append(best.index)
            } else {
                tracks.append(Track(id: nextID, label: detection.label, box: detection.box, velocity: .zero,
                                    heightRate: 0, hits: 1, misses: 0, firstSeenAt: time, lastSeenAt: time))
                seen.append(tracks.count - 1)
                nextID += 1
            }
        }

        for index in unmatched {
            tracks[index].misses += 1
        }

        let confirmed = seen
            .filter { Self.isConfirmed(tracks[$0]) }
            .map { report(tracks[$0], at: time) }

        // Unconfirmed tracks must be consecutive: one miss and they're gone.
        tracks.removeAll { $0.misses > (Self.isConfirmed($0) ? Self.forgetAfterMisses : 0) }
        return confirmed
    }

    private static func isConfirmed(_ track: Track) -> Bool {
        track.hits >= 3 || (track.hits >= 2 && track.box.height >= 0.45)
    }

    private func correct(_ track: inout Track, with detection: Detection, at time: Double) {
        let dt = max(time - track.lastSeenAt, 0.001)
        let predicted = track.predicted(at: time)
        let measured = detection.box
        let residual = CGVector(dx: measured.midX - predicted.midX, dy: measured.midY - predicted.midY)
        let center = CGPoint(x: predicted.midX + alpha * residual.dx, y: predicted.midY + alpha * residual.dy)
        track.velocity = CGVector(dx: track.velocity.dx + beta * residual.dx / dt,
                                  dy: track.velocity.dy + beta * residual.dy / dt)

        let predictedHeight = track.box.height + track.heightRate * dt
        let heightResidual = measured.height - predictedHeight
        let height = predictedHeight + alpha * heightResidual
        track.heightRate += beta * heightResidual / dt
        let width = track.box.width + alpha * (measured.width - track.box.width)

        track.box = CGRect(x: center.x - width / 2, y: center.y - height / 2, width: width, height: height)
        track.hits += 1
        track.misses = 0
        track.lastSeenAt = time
    }

    private func report(_ track: Track, at time: Double) -> TrackedObject {
        let cutOff = track.box.minY < 0.02 || track.box.maxY > 0.98
        let hasHistory = time - track.firstSeenAt >= 0.4 && track.hits >= 3
        let growth = (cutOff || !hasHistory || track.box.height < 0.01) ? nil : track.heightRate / track.box.height
        return TrackedObject(id: track.id, label: track.label, box: track.box,
                             firstSeenAt: track.firstSeenAt, growthRate: growth)
    }

    /// Box overlap (IoU), with partial credit for small fast boxes whose centers are close.
    private func matchScore(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let overlap = a.intersection(b)
        let iou: CGFloat = overlap.isNull ? 0
            : overlap.width * overlap.height / (a.width * a.height + b.width * b.height - overlap.width * overlap.height)
        let gap = hypot(a.midX - b.midX, a.midY - b.midY)
        let nearCenters = gap < 0.5 * max(a.width, a.height) ? minOverlap : 0
        return max(iou, nearCenters)
    }
}
