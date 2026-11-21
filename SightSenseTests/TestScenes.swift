import CoreGraphics
import Foundation
@testable import SightSense

/// Synthetic camera views of simple worlds, so geometry can be tested against known truth.
enum TestScenes {
    static let cameraHeight = 1.3

    static func camera(fovDegrees: Double = 69, pitchDegrees: Double? = 5) -> CameraGeometry {
        CameraGeometry(longSideFOVDegrees: fovDegrees, aspect: 0.75, pitchDown: pitchDegrees.map { $0 * .pi / 180 })
    }

    /// Where an object (real height × width, standing `distance` ahead and `sideways` to the right)
    /// appears in a portrait frame, clipped to the frame like a detector box would be.
    static func box(height: Double, width: Double, distance: Double, sideways: Double = 0, camera: CameraGeometry) -> CGRect {
        let pitch = camera.pitchDown ?? 0
        let tanV = tan(camera.verticalFOV / 2), tanH = tan(camera.horizontalFOV / 2)
        func row(_ heightAboveGround: Double) -> Double {
            0.5 - tan(atan((heightAboveGround - cameraHeight) / distance) + pitch) / (2 * tanV)
        }
        func column(_ x: Double) -> Double { 0.5 + (x / distance) / (2 * tanH) }
        let top = max(0, row(height)), bottom = min(1, row(0))
        let left = max(0, column(sideways - width / 2)), right = min(1, column(sideways + width / 2))
        return CGRect(x: left, y: top, width: right - left, height: bottom - top)
    }

    struct Block {
        var forward: Double
        var sideways = 0.0
        var width = 0.5
        var height = 1.0
    }

    /// Depth for a flat floor (falling by `dropDepth` beyond `dropAt`) plus an optional block,
    /// as a monocular model would report it: `scale / z + offset`, with a little noise.
    static func depth(camera: CameraGeometry, block: Block? = nil, dropAt: Double? = nil, dropDepth: Double = 0.6,
                      width: Int = 130, height: Int = 98, kind: DepthGrid.Kind = .relativeInverse) -> DepthGrid {
        let pitch = camera.pitchDown ?? 0
        let tanV = tan(camera.verticalFOV / 2), tanH = tan(camera.horizontalFOV / 2)
        var noise = SeededRandom(seed: 3)
        var values: [Float] = []
        for r in 0..<height {
            for c in 0..<width {
                let x = ((Double(c) + 0.5) / Double(width) * 2 - 1) * tanH
                let y = ((Double(r) + 0.5) / Double(height) * 2 - 1) * tanV
                let forward = cos(pitch) - y * sin(pitch)   // per meter of depth
                let down = sin(pitch) + y * cos(pitch)
                var z = 50.0  // sky or far wall
                if down > 0 {
                    z = cameraHeight / down
                    if let dropAt, z * forward > dropAt { z = (cameraHeight + dropDepth) / down }
                }
                if let block, forward > 0 {
                    let zBlock = block.forward / forward
                    let lateral = zBlock * x
                    let rise = cameraHeight - zBlock * down
                    if abs(lateral - block.sideways) < block.width / 2, rise >= 0, rise <= block.height, zBlock < z {
                        z = zBlock
                    }
                }
                let jitter = 1 + Double.random(in: -0.01...0.01, using: &noise)
                values.append(Float(kind == .metric ? z * jitter : (3.0 / z + 0.2) * jitter))
            }
        }
        return DepthGrid(width: width, height: height, values: values, kind: kind)
    }

    static func hazard(id: Int, label: String = "chair", meters: Double, bearing: Double = 0, gap: Double = 0,
                       score: Double = 0.6, growth: Double? = nil, firstSeen: Double = 0) -> Hazard {
        Hazard(
            object: TrackedObject(id: id, label: label, box: CGRect(x: 0.4, y: 0.3, width: 0.2, height: 0.4),
                                  firstSeenAt: firstSeen, growthRate: growth),
            location: ObjectLocation(meters: meters, bearingDegrees: bearing, pathGap: gap,
                                     closeness: meters < 1.5 ? .near : meters < 3.5 ? .mid : .far),
            score: score)
    }
}
