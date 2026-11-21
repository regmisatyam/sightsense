import CoreGraphics
import Foundation

/// A depth image aligned with the camera frame: row-major, top-left origin.
nonisolated struct DepthGrid: Sendable {
    nonisolated enum Kind: Sendable {
        /// Meters along the camera's viewing axis (e.g. LiDAR).
        case metric
        /// Monocular model output: larger = closer, with an unknown scale and offset.
        case relativeInverse
    }

    let width: Int
    let height: Int
    let values: [Float]
    let kind: Kind
}

/// Result of one depth pass.
struct PathScan {
    struct Finding {
        let meters: Double
        let bearingDegrees: Double
    }

    /// Nearest thing rising out of the floor inside the walking corridor.
    let obstacle: Finding?
    /// Where the floor ahead falls away (stairs down, curb, hole).
    let dropOff: Finding?
    /// False when depth couldn't be turned into meters (no floor in view and no recent calibration).
    let reliable: Bool

    static let unreliable = PathScan(obstacle: nil, dropOff: nil, reliable: false)
}

/// Finds hazards from depth without needing to know what they are: anything that rises out of
/// the floor inside the walking corridor (poles, walls, bins, people, branches up to head height),
/// and places where the floor drops away. Covers everything the object detector can't name.
///
/// Monocular depth has an unknown scale and offset, so each pass calibrates it against the floor:
/// with the camera's height and tilt known, every floor pixel's true distance is known. A robust
/// fit (RANSAC) ignores pixels that are obstacles rather than floor.
struct PathScanner {
    var cameraHeight = 1.3
    var corridorHalfWidth = 0.45  // shoulders plus a margin, each side of the walking line
    var obstacleRange = 5.0
    /// Past an edge, the lower floor first appears well beyond the edge itself, so look further.
    var dropRange = 8.0

    private(set) var lastFit: (scale: Double, offset: Double, time: Double)?
    private var random = SeededRandom(seed: 7)

    mutating func scan(_ depth: DepthGrid, camera: CameraGeometry, now: Double) -> PathScan {
        guard let pitch = camera.pitchDown, depth.width > 1, depth.height > 1 else { return .unreliable }
        let rays = Rays(depth: depth, camera: camera, pitch: pitch)

        let meters: (Float) -> Double?
        switch depth.kind {
        case .metric:
            meters = { $0 > 0 ? Double($0) : nil }
        case .relativeInverse:
            if let fit = fitToFloor(depth, rays: rays) {
                lastFit = (fit.scale, fit.offset, now)
            } else if let last = lastFit, now - last.time > 2 {
                lastFit = nil
            }
            guard let fit = lastFit else { return .unreliable }
            meters = { value in
                let denominator = Double(value) - fit.offset
                return denominator > 1e-6 ? fit.scale / denominator : nil
            }
        }

        var obstacles: [(forward: Double, lateral: Double)] = []
        var below: [Double] = []
        var floor: [Double] = []
        for row in 0..<depth.height {
            for column in 0..<depth.width {
                guard let z = meters(depth.values[row * depth.width + column]) else { continue }
                let point = rays.point(column: column, row: row, depth: z)
                guard abs(point.lateral) < corridorHalfWidth, point.forward > 0.3, point.forward < dropRange else { continue }
                let rise = cameraHeight - point.down
                // Depth noise grows with distance, so the "not floor" margin does too.
                if rise > max(0.2, 0.08 * point.forward) && rise < 2.1 {
                    if point.forward < obstacleRange { obstacles.append((point.forward, point.lateral)) }
                } else if rise < -max(0.25, 0.1 * point.forward) {
                    below.append(point.forward)
                } else {
                    floor.append(point.forward)
                }
            }
        }

        let minPoints = max(6, (obstacles.count + below.count + floor.count) / 100)
        return PathScan(obstacle: nearestObstacle(obstacles, minPoints: minPoints),
                        dropOff: dropEdge(below: below, floor: floor, minPoints: minPoints),
                        reliable: true)
    }

    /// Distance along the ground to whatever is at a point of the image (normalized, top-left
    /// origin), e.g. something the AI pointed at. Uses the median depth around the point and the
    /// latest floor calibration. Nil if depth can't be turned into meters there.
    func distance(at point: CGPoint, in depth: DepthGrid, camera: CameraGeometry) -> Double? {
        guard let pitch = camera.pitchDown else { return nil }
        let column = min(max(Int(point.x * Double(depth.width)), 0), depth.width - 1)
        let row = min(max(Int(point.y * Double(depth.height)), 0), depth.height - 1)
        var values: [Double] = []
        for r in max(0, row - 1)...min(depth.height - 1, row + 1) {
            for c in max(0, column - 1)...min(depth.width - 1, column + 1) {
                values.append(Double(depth.values[r * depth.width + c]))
            }
        }
        let value = values.sorted()[values.count / 2]
        let z: Double
        switch depth.kind {
        case .metric:
            z = value
        case .relativeInverse:
            guard let fit = lastFit, value - fit.offset > 1e-6 else { return nil }
            z = fit.scale / (value - fit.offset)
        }
        guard z > 0, z < 50 else { return nil }
        return Rays(depth: depth, camera: camera, pitch: pitch).point(column: column, row: row, depth: z).forward
    }

    /// Nearest obstacle distance, ignoring a few stray points.
    private func nearestObstacle(_ points: [(forward: Double, lateral: Double)], minPoints: Int) -> PathScan.Finding? {
        guard points.count >= minPoints else { return nil }
        let sorted = points.sorted { $0.forward < $1.forward }
        let meters = sorted[min(sorted.count - 1, max(2, sorted.count / 20))].forward
        let front = sorted.prefix { $0.forward <= meters + 0.3 }
        let lateral = front.map(\.lateral).reduce(0, +) / Double(front.count)
        return PathScan.Finding(meters: meters, bearingDegrees: atan2(lateral, meters) * 180 / .pi)
    }

    /// Where the floor ends. Points below floor level are seen *past* the edge, so the edge is
    /// the farthest floor point in front of them.
    private func dropEdge(below: [Double], floor: [Double], minPoints: Int) -> PathScan.Finding? {
        guard below.count >= minPoints else { return nil }
        let sorted = below.sorted()
        let firstBelow = sorted[min(sorted.count - 1, max(2, sorted.count / 20))]
        let edge = floor.filter { $0 < firstBelow }.max() ?? firstBelow
        return PathScan.Finding(meters: edge, bearingDegrees: 0)
    }

    /// Fits `value = scale / z + offset` to pixels whose rays would hit the floor at a known depth.
    private mutating func fitToFloor(_ depth: DepthGrid, rays: Rays) -> (scale: Double, offset: Double)? {
        var samples: [(inverseZ: Double, value: Double)] = []
        for row in stride(from: 0, to: depth.height, by: 2) {
            for column in stride(from: 0, to: depth.width, by: 2) {
                // Nearby floor is the most likely to really be floor (and not past a drop).
                guard let z = rays.floorDepth(column: column, row: row, cameraHeight: cameraHeight),
                      z > 0.6, z < 4.5 else { continue }
                samples.append((1 / z, Double(depth.values[row * depth.width + column])))
            }
        }
        guard samples.count >= 40 else { return nil }

        // Depth errors grow with distance, so judge fit errors as a percentage of the observed
        // value. (A fixed tolerance can't tell the floor from a lower floor past a drop, because the
        // two lines converge in the distance; a tolerance based on the candidate's own prediction
        // lets an inflated scale with a negative offset swallow both.)
        func fits(_ sample: (inverseZ: Double, value: Double), _ scale: Double, _ offset: Double) -> Bool {
            abs(sample.value - (scale * sample.inverseZ + offset)) < 0.06 * abs(sample.value)
        }

        var best: (scale: Double, offset: Double, inliers: Int)?
        // Anchor on the floor nearest the feet. Past a drop, the lower floor can fill most of the
        // view, and monocular depth alone can't tell "floor 1.3 m below" from "floor 1.9 m below";
        // the nearest floor is the one the user is standing on. So a fit must explain most of the
        // nearest quarter of samples, and nearer samples count for more.
        let nearest = Array(samples.sorted { $0.inverseZ > $1.inverseZ }.prefix(max(10, samples.count / 4)))
        var bestScore = 0.0
        for _ in 0..<80 {
            let a = nearest[Int.random(in: 0..<nearest.count, using: &random)]
            let b = samples[Int.random(in: 0..<samples.count, using: &random)]
            guard abs(a.inverseZ - b.inverseZ) > 1e-3 else { continue }
            let scale = (a.value - b.value) / (a.inverseZ - b.inverseZ)
            guard scale > 0 else { continue }
            let offset = a.value - scale * a.inverseZ
            guard nearest.filter({ fits($0, scale, offset) }).count * 2 >= nearest.count else { continue }
            let inliers = samples.filter { fits($0, scale, offset) }
            let score = inliers.map(\.inverseZ).reduce(0, +)
            if score > bestScore {
                bestScore = score
                best = (scale, offset, inliers.count)
            }
        }
        guard let best, best.inliers >= max(25, samples.count / 5) else { return nil }

        // Refine with least squares over the inliers.
        let inliers = samples.filter { fits($0, best.scale, best.offset) }
        let n = Double(inliers.count)
        let meanX = inliers.map(\.inverseZ).reduce(0, +) / n
        let meanY = inliers.map(\.value).reduce(0, +) / n
        let covariance = inliers.map { ($0.inverseZ - meanX) * ($0.value - meanY) }.reduce(0, +)
        let variance = inliers.map { ($0.inverseZ - meanX) * ($0.inverseZ - meanX) }.reduce(0, +)
        guard variance > 0 else { return nil }
        let scale = covariance / variance
        guard scale > 0 else { return nil }
        return (scale, meanY - scale * meanX)
    }
}

/// Precomputed ray directions for each pixel of a depth grid.
private struct Rays {
    let xs: [Double]  // horizontal ray slope per column
    let ys: [Double]  // vertical ray slope per row (down is positive)
    let sinPitch: Double
    let cosPitch: Double

    init(depth: DepthGrid, camera: CameraGeometry, pitch: Double) {
        let tanH = tan(camera.horizontalFOV / 2)
        let tanV = tan(camera.verticalFOV / 2)
        xs = (0..<depth.width).map { ((Double($0) + 0.5) / Double(depth.width) * 2 - 1) * tanH }
        ys = (0..<depth.height).map { ((Double($0) + 0.5) / Double(depth.height) * 2 - 1) * tanV }
        sinPitch = sin(pitch)
        cosPitch = cos(pitch)
    }

    /// World position of a pixel at depth `z` (meters along the viewing axis).
    func point(column: Int, row: Int, depth z: Double) -> (forward: Double, lateral: Double, down: Double) {
        let y = ys[row]
        return (z * (cosPitch - y * sinPitch), z * xs[column], z * (sinPitch + y * cosPitch))
    }

    /// Depth at which this pixel's ray meets a flat floor, or nil if it points at or above the horizon.
    func floorDepth(column: Int, row: Int, cameraHeight: Double) -> Double? {
        let downward = sinPitch + ys[row] * cosPitch
        return downward > 0.02 ? cameraHeight / downward : nil
    }
}

/// Small deterministic random generator (SplitMix64), so depth fitting is repeatable in tests.
nonisolated struct SeededRandom: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
