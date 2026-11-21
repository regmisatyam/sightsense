import AVFoundation
import CoreMotion

/// Back camera, 640x480 portrait frames at about 15 fps, each tagged with the lens's real
/// field of view, the phone's tilt, and the wearer's movement from the motion sensors.
///
/// Prefers the 0.5× ultra-wide lens: from chest height it sees the floor about 1 m ahead
/// instead of about 1.9 m, and covers more to each side. Falls back to the main lens.
nonisolated final class PhoneCameraSource: NSObject, FrameSource, @unchecked Sendable {
    let frames: AsyncStream<Frame>

    private let continuation: AsyncStream<Frame>.Continuation
    private let preferUltraWide: Bool
    private let session = AVCaptureSession()
    private let motion = CMMotionManager()
    private let queue = DispatchQueue(label: "sightsense.camera")
    // Only touched on `queue`:
    private var device: AVCaptureDevice?
    private var longSideFOVDegrees = 65.0  // replaced by the real value once the camera is set up

    init(preferUltraWide: Bool = true) {
        self.preferUltraWide = preferUltraWide
        (frames, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
        super.init()
    }

    func start() {
        Task {
            guard await AVCaptureDevice.requestAccess(for: .video) else {
                continuation.finish()
                return
            }
            queue.async { [self] in
                if device == nil {
                    guard configure() else { continuation.finish(); return }
                }
                if let fov = device?.activeFormat.videoFieldOfView, fov > 0 {
                    longSideFOVDegrees = Double(fov)
                }
                if motion.isDeviceMotionAvailable {
                    motion.deviceMotionUpdateInterval = 1.0 / 30
                    // Magnetic reference frame: also gives a calibrated magnetic field, for the facing direction.
                    if CMMotionManager.availableAttitudeReferenceFrames().contains(.xMagneticNorthZVertical) {
                        motion.startDeviceMotionUpdates(using: .xMagneticNorthZVertical)
                    } else {
                        motion.startDeviceMotionUpdates()
                    }
                }
                session.startRunning()
            }
        }
    }

    func stop() {
        queue.async { [self] in
            session.stopRunning()
            motion.stopDeviceMotionUpdates()
        }
    }

    /// Runs on `queue`. Returns false if no camera can be set up.
    private func configure() -> Bool {
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        let lenses: [AVCaptureDevice.DeviceType] = preferUltraWide
            ? [.builtInUltraWideCamera, .builtInWideAngleCamera]
            : [.builtInWideAngleCamera]
        // A plain loop on purpose: `attach` adds an input to the session, so it must run exactly
        // once per lens. (`lazy.compactMap(...).first` calls its closure twice for the match.)
        var attached: AVCaptureDevice?
        for lens in lenses {
            attached = attach(lens)
            if attached != nil { break }
        }
        guard let device = attached else { return false }

        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(output) else { return false }
        session.addOutput(output)

        // Phone is upright on the chest: deliver portrait frames.
        if let connection = output.connection(with: .video), connection.isVideoRotationAngleSupported(90) {
            connection.videoRotationAngle = 90
        }

        if (try? device.lockForConfiguration()) != nil {
            // Straight lines stay straight, so the distance math (a pinhole camera) holds.
            if device.isGeometricDistortionCorrectionSupported {
                device.isGeometricDistortionCorrectionEnabled = true
            }
            // Cap at 15 fps to save battery and heat. Must be set after the input is added.
            let frameDuration = CMTime(value: 1, timescale: 15)
            device.activeVideoMinFrameDuration = frameDuration
            device.activeVideoMaxFrameDuration = frameDuration
            device.unlockForConfiguration()
        }
        self.device = device
        return true
    }

    /// Adds this lens as the session input if it exists and supports 640x480. Runs on `queue`.
    private func attach(_ type: AVCaptureDevice.DeviceType) -> AVCaptureDevice? {
        guard let device = AVCaptureDevice.default(type, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else { return nil }
        session.addInput(input)
        guard session.canSetSessionPreset(.vga640x480) else {
            session.removeInput(input)
            return nil
        }
        session.sessionPreset = .vga640x480
        return device
    }
}

// `nonisolated` is required: the project defaults to MainActor, and without it this callback
// (which AVFoundation calls on the camera queue) would be main-actor and crash at runtime.
nonisolated extension PhoneCameraSource: AVCaptureVideoDataOutputSampleBufferDelegate {
    nonisolated func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let aspect = Double(CVPixelBufferGetWidth(pixelBuffer)) / Double(CVPixelBufferGetHeight(pixelBuffer))
        let deviceMotion = motion.deviceMotion
        // Back camera looks along the device's -z axis, so its tilt below the horizon is asin(-gravity.z).
        let pitchDown = deviceMotion.map { asin(max(-1, min(1, -$0.gravity.z))) }
        let sample = deviceMotion.map { m in
            MotionSample(
                acceleration: (m.userAcceleration.x * m.userAcceleration.x + m.userAcceleration.y * m.userAcceleration.y
                    + m.userAcceleration.z * m.userAcceleration.z).squareRoot(),
                rotation: (m.rotationRate.x * m.rotationRate.x + m.rotationRate.y * m.rotationRate.y
                    + m.rotationRate.z * m.rotationRate.z).squareRoot(),
                heading: m.magneticField.accuracy == .uncalibrated ? nil : HeadingMath.cameraHeading(
                    gravity: SIMD3(m.gravity.x, m.gravity.y, m.gravity.z),
                    magneticField: SIMD3(m.magneticField.field.x, m.magneticField.field.y, m.magneticField.field.z)),
                // Gravity points down, so "up" is against it.
                upward: -(m.userAcceleration.x * m.gravity.x + m.userAcceleration.y * m.gravity.y
                    + m.userAcceleration.z * m.gravity.z)
            )
        }
        let camera = CameraGeometry(longSideFOVDegrees: longSideFOVDegrees, aspect: aspect, pitchDown: pitchDown)
        continuation.yield(Frame(pixelBuffer: pixelBuffer, capturedAt: CACurrentMediaTime(), camera: camera, motion: sample))
    }
}
