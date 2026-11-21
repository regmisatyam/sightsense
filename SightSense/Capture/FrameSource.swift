import CoreVideo
import QuartzCore

/// Anything that produces camera frames: the phone camera, a recorded walk, smart glasses later.
///
/// `frames` has a single consumer and keeps only the newest frame, so a slow
/// consumer always sees the most recent image instead of a growing backlog.
/// If the source can't run (no permission, device gone, recording ended), it finishes `frames`.
nonisolated protocol FrameSource: AnyObject {
    var frames: AsyncStream<Frame> { get }
    func start()
    func stop()
}

/// One upright camera image, when it arrived (for latency), the camera's lens angles and
/// tilt (for distance and direction), and how much the wearer is moving.
/// `@unchecked Sendable`: a source never touches a buffer after handing it off.
nonisolated struct Frame: @unchecked Sendable {
    let pixelBuffer: CVPixelBuffer
    let capturedAt: CFTimeInterval  // CACurrentMediaTime()
    let camera: CameraGeometry
    let motion: MotionSample?
}

nonisolated struct MotionSample: Sendable {
    /// Acceleration from the wearer's own movement (gravity removed), in g.
    let acceleration: Double
    /// How fast the phone is turning, in radians per second.
    let rotation: Double
    /// Direction the camera faces, degrees clockwise from magnetic north (nil until the compass is calibrated).
    var heading: Double? = nil
    /// Acceleration straight up (gravity removed), in g: footsteps show up as a regular bounce.
    var upward: Double = 0

    /// Not walking or turning: fine for reading text or saving power.
    var isSteady: Bool { acceleration < 0.04 && rotation < 0.35 }
}
