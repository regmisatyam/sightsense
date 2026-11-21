import Foundation
import Observation
import QuartzCore

/// The on-device fast loop. Never touches the network.
/// - Object detection (every 2nd frame) → tracker → position → named hazards.
/// - Depth (every 4th frame) → path scanner → anything in the walking corridor, and drop-offs.
/// - Both feed the alert planner → sound and buzz first, then a short phrase.
/// Standing still or a hot phone halves both rates.
@Observable
final class FastLoop {
    enum DepthStatus { case loading, missing, uncertain, working }

    // Shown by the debug overlay.
    private(set) var hazards: [Hazard] = []
    private(set) var path = ConfirmedPath()
    private(set) var detectorSource = ObstacleDetector.Source.loading
    private(set) var depthStatus = DepthStatus.loading
    private(set) var detectMs = 0.0
    private(set) var depthMs = 0.0
    private(set) var latency = LatencyStats()
    private(set) var tiltDegrees: Double?
    private(set) var isStationary = false
    /// Candidate alerts held back as noise so far.
    private(set) var filteredCount = 0

    @ObservationIgnored private let speech: SpeechQueue
    @ObservationIgnored private let settings: Settings
    @ObservationIgnored private let presenter: AlertPresenter
    @ObservationIgnored private let recorder: WalkRecorder
    @ObservationIgnored private let detector = ObstacleDetector()
    @ObservationIgnored private let depthEstimator = DepthEstimator()
    @ObservationIgnored private var tracker = Tracker()
    @ObservationIgnored private var prioritizer = HazardPrioritizer()
    @ObservationIgnored private var scanner = PathScanner()
    @ObservationIgnored private var confirmer = PathConfirmer()
    @ObservationIgnored private var planner = AlertPlanner()
    @ObservationIgnored private var frameCount = 0
    @ObservationIgnored private var isDetecting = false
    @ObservationIgnored private var isScanning = false
    @ObservationIgnored private var lastHazardAt: CFTimeInterval = 0
    @ObservationIgnored private var walking = WalkingDetector()
    @ObservationIgnored private var lastDepth: (grid: DepthGrid, camera: CameraGeometry)?
    /// Latest GPS speed in m/s (from the Places compass), a second opinion on walking.
    @ObservationIgnored var gpsSpeed: Double?

    /// Sound engine for proximity beeps and warning cues, shared with the rest of the app.
    var audio: SpatialAudio { presenter.audio }

    init(speech: SpeechQueue, settings: Settings, recorder: WalkRecorder) {
        self.speech = speech
        self.settings = settings
        self.recorder = recorder
        presenter = AlertPresenter(speech: speech)
    }

    /// No hazard worth mentioning for the last few seconds.
    var isPathClear: Bool {
        CACurrentMediaTime() - lastHazardAt > 4
    }

    /// What the sensors measured right now, in everyday words (for Gemini and offline summaries).
    func measurements() -> [String] {
        var lines = hazards.prefix(5).map { $0.summary(units: settings.units) }
        if let obstacle = path.obstacle {
            let direction = SpokenPosition.direction(obstacle.bearingDegrees)
            lines.append("something unidentified in their path \(direction), \(words(obstacle.meters))")
        }
        if let drop = path.dropOff {
            lines.append("the ground drops away ahead, \(words(drop.meters))")
        }
        return lines
    }

    /// e.g. "a person slightly left, about 4 steps away; a chair to your right, 2 steps away".
    func summary() -> String? {
        let lines = measurements().prefix(3)
        return lines.isEmpty ? nil : lines.joined(separator: "; ")
    }

    /// How far away the thing at an image point is: from a tracked object whose box contains it,
    /// otherwise from the latest depth map. Nil if unknown.
    func distance(to point: CGPoint) -> Double? {
        if let hazard = hazards.first(where: { $0.object.box.contains(point) }) {
            return hazard.location.meters
        }
        guard let depth = lastDepth else { return nil }
        return scanner.distance(at: point, in: depth.grid, camera: depth.camera)
    }

    func start() async {
        detectorSource = await detector.load()
        depthStatus = await depthEstimator.load() ? .uncertain : .missing
        if detectorSource == .builtIn {
            speech.say("No detector model installed, so I'll only name people and pets.")
        }
    }

    func process(_ frame: Frame) {
        frameCount += 1
        trackMovement(frame)
        let thermal = ProcessInfo.processInfo.thermalState
        let slow = isStationary || thermal == .serious || thermal == .critical

        if detectorSource != .loading, !isDetecting, frameCount % (slow ? 4 : 2) == 0 {
            detect(frame)
        }
        if depthStatus != .loading, depthStatus != .missing, !isScanning, frameCount % (slow ? 8 : 4) == 1 {
            scanDepth(frame)
        }
    }

    // MARK: - Passes

    private func detect(_ frame: Frame) {
        isDetecting = true
        Task {
            let started = CACurrentMediaTime()
            let pass = await detector.detect(frame)
            detectMs = (CACurrentMediaTime() - started) * 1000
            isDetecting = false
            if detectorSource == .model && pass.source == .builtIn {
                speech.say("The detector model isn't supported, so I'll only name people and pets.")
            }
            detectorSource = pass.source

            prioritizer.estimator.cameraHeight = settings.chestHeight
            let objects = tracker.update(pass.detections, at: frame.capturedAt)
            hazards = prioritizer.rank(objects, camera: frame.camera)
            tiltDegrees = frame.camera.pitchDown.map { $0 * 180 / .pi }
            decide(after: frame)
        }
    }

    private func scanDepth(_ frame: Frame) {
        isScanning = true
        Task {
            let started = CACurrentMediaTime()
            let grid = await depthEstimator.estimate(frame)
            depthMs = (CACurrentMediaTime() - started) * 1000
            isScanning = false
            guard let grid else { return }

            scanner.cameraHeight = settings.chestHeight
            lastDepth = (grid, frame.camera)
            let scan = scanner.scan(grid, camera: frame.camera, now: frame.capturedAt)
            depthStatus = scan.reliable ? .working : .uncertain
            path = confirmer.update(scan, at: frame.capturedAt)
            decide(after: frame)
        }
    }

    // MARK: - Deciding

    private func decide(after frame: Frame) {
        let now = CACurrentMediaTime()
        updateBeeps()

        let obstacleNear = (path.obstacle?.meters ?? .infinity) < 3.5
        if obstacleNear || path.dropOff != nil || hazards.contains(where: { $0.isUrgent || ($0.location.isInPath && $0.location.meters < 4) }) {
            lastHazardAt = now
        }

        planner.policy = settings.alertPolicy
        let context = AlertContext(now: now, isWalking: !isStationary, heading: frame.motion?.heading)
        let alert = planner.plan(hazards: hazards, path: path, context: context)
        if planner.filtered != filteredCount { filteredCount = planner.filtered }
        guard let alert else { return }
        let capturedAt = frame.capturedAt
        presenter.present(alert) { [weak self] startedAt in
            let pipeline = (startedAt - capturedAt) * 1000
            let endToEnd = (startedAt - alert.firstSeenAt) * 1000
            self?.latency.record(pipelineMs: pipeline, endToEndMs: endToEnd)
            self?.recorder.log(alert, pipelineMs: pipeline, endToEndMs: endToEnd)
        }
    }

    /// Beep toward whichever is nearest: a named hazard or an unnamed obstacle in the path.
    /// Default (path mode): only for something in your path, only while walking or if it's
    /// approaching, so standing at a counter doesn't beep forever.
    private func updateBeeps() {
        let mode = settings.beepMode
        let approaching = hazards.contains { ($0.closingSpeed ?? 0) > 2.2 && ($0.secondsToContact ?? .infinity) < 3 }
        var nearest: (meters: Double, bearing: Double)?
        if mode == .always || (mode == .path && (!isStationary || approaching)) {
            let candidates = hazards.filter {
                mode == .always ? $0.score >= HazardPrioritizer.beepThreshold : $0.location.isInPath && $0.location.meters < 4
            }
            if let top = candidates.min(by: { $0.location.meters < $1.location.meters }) {
                nearest = (top.location.meters, top.location.bearingDegrees)
            }
            if let obstacle = path.obstacle, obstacle.meters < 3.5, obstacle.meters < (nearest?.meters ?? .infinity) {
                nearest = (obstacle.meters, obstacle.bearingDegrees)
            }
        }
        guard let nearest else {
            presenter.audio.silence()
            return
        }
        let closeness: Closeness = nearest.meters < 1.5 ? .near : nearest.meters < 3.5 ? .mid : .far
        presenter.audio.beep(pan: Float(max(-1, min(1, nearest.bearing / 25))), closeness: closeness)
    }

    /// Walking or standing, from footsteps (and GPS speed). Standing → slower scanning, no beeps,
    /// and the surroundings stay quiet.
    private func trackMovement(_ frame: Frame) {
        guard let motion = frame.motion else { return }
        let stationary = !walking.add(upward: motion.upward, at: frame.capturedAt, gpsSpeed: gpsSpeed)
        if stationary != isStationary { isStationary = stationary }
    }

    private func words(_ meters: Double) -> String {
        SpokenPosition.distance(meters, units: settings.units)
    }
}

/// Alert latency, measured honestly:
/// - pipeline: the frame that triggered the alert → its sound starting;
/// - end-to-end: the thing was *first* seen → its sound starting (includes confirmation time).
struct LatencyStats {
    private(set) var lastPipelineMs: Double?
    private var endToEnd: [Double] = []

    mutating func record(pipelineMs: Double, endToEndMs: Double) {
        lastPipelineMs = pipelineMs
        endToEnd.append(endToEndMs)
        if endToEnd.count > 50 { endToEnd.removeFirst() }
    }

    /// Median and 95th-percentile end-to-end latency over the last 50 alerts.
    var endToEndPercentiles: (p50: Double, p95: Double)? {
        guard !endToEnd.isEmpty else { return nil }
        let sorted = endToEnd.sorted()
        return (sorted[sorted.count / 2], sorted[min(sorted.count - 1, sorted.count * 95 / 100)])
    }
}
