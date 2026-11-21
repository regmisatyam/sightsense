import Foundation

/// How a frame relates to the real world: the lens angles and which way the camera points.
/// Each `FrameSource` fills this in for its own hardware, so distance math works for any camera.
nonisolated struct CameraGeometry: Sendable, Codable {
    /// Field of view across the frame's width and height, in radians.
    let horizontalFOV: Double
    let verticalFOV: Double
    /// How far the lens points below the horizon, in radians (from the motion sensors). Nil if unknown.
    let pitchDown: Double?

    /// - longSideFOVDegrees: field of view across the image's long side
    ///   (for iPhone: `AVCaptureDevice.Format.videoFieldOfView`).
    /// - aspect: frame width ÷ height (portrait frames are < 1).
    init(longSideFOVDegrees: Double, aspect: Double, pitchDown: Double?) {
        let long = longSideFOVDegrees * .pi / 180
        let short = 2 * atan(tan(long / 2) * min(aspect, 1 / aspect))
        horizontalFOV = aspect < 1 ? short : long
        verticalFOV = aspect < 1 ? long : short
        self.pitchDown = pitchDown
    }

    init(horizontalFOV: Double, verticalFOV: Double, pitchDown: Double?) {
        self.horizontalFOV = horizontalFOV
        self.verticalFOV = verticalFOV
        self.pitchDown = pitchDown
    }
}
