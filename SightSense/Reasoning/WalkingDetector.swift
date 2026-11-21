import Foundation

/// Tells walking from standing by footsteps: the regular up-and-down bounce of each step,
/// not just "the phone moved". Breathing, swaying, turning on the spot, or handling the
/// phone don't count. GPS speed is a second opinion (e.g. on a smooth floor with a soft gait).
///
/// Walking = at least 2 steps in the last 2.5 s, or GPS says faster than a slow walk.
/// So it switches to "standing" about 2.5 s after the last step.
struct WalkingDetector {
    private(set) var isWalking = false

    /// A step's upward bounce at chest height is roughly 0.15–0.4 g; hand jitter stays well below.
    var stepThreshold = 0.07
    private var steps: [Double] = []
    private var lastStepAt = -Double.infinity
    private var samples: (older: Double, previous: Double, previousTime: Double)?

    /// Feeds one motion sample. Returns whether the wearer is walking.
    @discardableResult
    mutating func add(upward: Double, at time: Double, gpsSpeed: Double? = nil) -> Bool {
        if let samples {
            // The previous sample was a peak: higher than both neighbours and above the threshold.
            let isPeak = samples.previous > stepThreshold && samples.previous > samples.older && samples.previous >= upward
            // Steps come at most ~3 per second.
            if isPeak, samples.previousTime - lastStepAt >= 0.3 {
                steps.append(samples.previousTime)
                lastStepAt = samples.previousTime
            }
            self.samples = (samples.previous, upward, time)
        } else {
            samples = (upward, upward, time)
        }
        steps.removeAll { time - $0 > 2.5 }
        let stepping = steps.count >= 2
        let moving = (gpsSpeed ?? 0) > 0.5
        isWalking = stepping || moving
        return isWalking
    }
}
