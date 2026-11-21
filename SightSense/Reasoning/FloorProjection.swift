import CoreGraphics
import Foundation

/// Where a point in the world appears in the camera image: the exact inverse of the ray math the
/// path scanner and distance estimator use, so anything drawn with it (distance rings, the walking
/// lane, obstacles) lines up with what the app measured.
///
/// World coordinates, in meters, from the point on the floor below the camera:
/// x = to the right, z = ahead, height = above the floor.
nonisolated struct FloorProjection: Sendable {
    let camera: CameraGeometry
    /// How far the lens points below the horizon, in radians.
    let pitch: Double
    /// Camera height above the floor (Settings › chest height).
    let cameraHeight: Double

    /// Nil until the motion sensors know the camera's tilt.
    init?(camera: CameraGeometry, cameraHeight: Double) {
        guard let pitch = camera.pitchDown else { return nil }
        self.camera = camera
        self.pitch = pitch
        self.cameraHeight = cameraHeight
    }

    /// Normalized image point (0…1, top-left origin), or nil if the point is behind the camera.
    /// Points outside the frame come back outside 0…1, so lines can run off the edge.
    func imagePoint(x: Double, z: Double, height: Double = 0) -> CGPoint? {
        let down = cameraHeight - height
        let along = z * cos(pitch) + down * sin(pitch)  // distance along the viewing axis
        guard along > 0.05 else { return nil }
        let slopeX = x / along
        let slopeY = (down * cos(pitch) - z * sin(pitch)) / along  // down is positive
        return CGPoint(x: 0.5 + slopeX / (2 * tan(camera.horizontalFOV / 2)),
                       y: 0.5 + slopeY / (2 * tan(camera.verticalFOV / 2)))
    }

    /// Image row of the horizon (0 = top); above it, nothing is on the floor.
    var horizonY: Double {
        0.5 - tan(pitch) / (2 * tan(camera.verticalFOV / 2))
    }

    /// Floor position of something `meters` away in direction `bearingDegrees` (0 = ahead, + = right).
    static func floorPoint(meters: Double, bearingDegrees: Double) -> (x: Double, z: Double) {
        let angle = bearingDegrees * .pi / 180
        return (meters * sin(angle), meters * cos(angle))
    }
}
