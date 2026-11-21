import CoreGraphics
import Foundation

enum Closeness: Int, Comparable {
    case far, mid, near

    static func < (a: Closeness, b: Closeness) -> Bool { a.rawValue < b.rawValue }
}

/// Where an object is, relative to the user.
struct ObjectLocation {
    /// Distance along the ground, in meters.
    let meters: Double
    /// Direction: 0 = straight ahead, negative = left, positive = right.
    let bearingDegrees: Double
    /// Sideways gap between the object and the user's walking line, in meters (0 = in the way).
    let pathGap: Double
    let closeness: Closeness

    /// About shoulder width: the user would bump into it walking straight.
    var isInPath: Bool { pathGap < 0.4 }
}

/// Estimates distance two ways and combines them:
/// 1. **Size.** An object of known height that fills a fraction of the frame is a certain distance away.
/// 2. **Ground.** The camera is about 1.3 m up on the chest and the motion sensors give its tilt,
///    so the image row where an object meets the floor gives its distance, the way people judge
///    distance by where someone's feet touch the ground.
struct DistanceEstimator {
    var cameraHeight = 1.3  // meters: phone on an adult's chest
    var nearMeters = 1.5
    var midMeters = 3.5

    func locate(label: String, box: CGRect, camera: CameraGeometry) -> ObjectLocation {
        let info = ObjectCatalog.info(for: label)
        let tanHalfV = tan(camera.verticalFOV / 2)
        let tanHalfH = tan(camera.horizontalFOV / 2)

        let bySize = info.height / (max(Double(box.height), 0.01) * 2 * tanHalfV)
        var meters = bySize
        if info.standsOnGround, let pitch = camera.pitchDown {
            let minAngle = 3 * Double.pi / 180
            func belowHorizon(_ row: CGFloat) -> Double { pitch + atan((Double(row) - 0.5) * 2 * tanHalfV) }

            if box.maxY < 0.97 {
                // Base visible: where it meets the floor.
                let angle = belowHorizon(box.maxY)
                if angle > minAngle { meters = 0.6 * cameraHeight / tan(angle) + 0.4 * bySize }
            } else {
                // Base hidden below the frame, so it's closer than the floor at the frame's bottom edge.
                let bottom = belowHorizon(1)
                let limit = bottom > minAngle ? cameraHeight / tan(bottom) : .infinity
                // If its top is visible, the top's angle and its known height pin it down:
                // a 0.9 m chair top sits 0.4 m below a chest camera; a 1.7 m head 0.4 m above.
                let rise = info.height - cameraHeight
                let topAbove = -belowHorizon(box.minY)
                if box.minY > 0.03, abs(rise) > 0.25, rise * topAbove > 0, abs(topAbove) > minAngle {
                    meters = min(rise / tan(topAbove), limit)
                } else {
                    meters = min(bySize, limit)
                }
            }
        }
        meters = min(max(meters, 0.3), 30)

        func bearing(_ x: CGFloat) -> Double { atan((Double(x) - 0.5) * 2 * tanHalfH) }
        let leftEdge = meters * tan(bearing(box.minX))
        let rightEdge = meters * tan(bearing(box.maxX))
        let gap = (leftEdge <= 0 && rightEdge >= 0) ? 0 : min(abs(leftEdge), abs(rightEdge))

        return ObjectLocation(
            meters: meters,
            bearingDegrees: bearing(box.midX) * 180 / .pi,
            pathGap: gap,
            closeness: meters < nearMeters ? .near : meters < midMeters ? .mid : .far
        )
    }
}
