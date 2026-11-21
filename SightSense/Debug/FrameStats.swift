import Observation
import QuartzCore

/// Counts incoming frames and publishes frames per second, refreshed once a second.
@Observable
final class FrameStats {
    private(set) var fps: Double = 0

    @ObservationIgnored private var count = 0
    @ObservationIgnored private var windowStart = CACurrentMediaTime()

    func frameArrived() {
        count += 1
        let now = CACurrentMediaTime()
        let elapsed = now - windowStart
        guard elapsed >= 1 else { return }
        fps = Double(count) / elapsed
        count = 0
        windowStart = now
    }
}
