import CoreGraphics
import Testing
@testable import SightSense

@Suite("Tracker")
struct TrackerTests {
    func chair(_ box: CGRect) -> Detection { Detection(label: "chair", confidence: 0.9, box: box) }

    @Test func confirmsAfterThreeSightings() {
        var tracker = Tracker()
        let box = CGRect(x: 0.4, y: 0.4, width: 0.1, height: 0.2)
        #expect(tracker.update([chair(box)], at: 0).isEmpty)
        #expect(tracker.update([chair(box)], at: 0.13).isEmpty)
        #expect(tracker.update([chair(box)], at: 0.26).count == 1)
    }

    @Test func bigCloseObjectsConfirmAfterTwo() {
        var tracker = Tracker()
        let box = CGRect(x: 0.2, y: 0.3, width: 0.5, height: 0.6)
        #expect(tracker.update([chair(box)], at: 0).isEmpty)
        #expect(tracker.update([chair(box)], at: 0.13).count == 1)
    }

    @Test func aMissBeforeConfirmationStartsOver() {
        var tracker = Tracker()
        let box = CGRect(x: 0.4, y: 0.4, width: 0.1, height: 0.2)
        _ = tracker.update([chair(box)], at: 0)
        _ = tracker.update([chair(box)], at: 0.13)
        _ = tracker.update([], at: 0.26)
        #expect(tracker.update([chair(box)], at: 0.39).isEmpty)
    }

    @Test func keepsIdentityWhileMovingAndRemembersFirstSighting() {
        var tracker = Tracker()
        var ids: Set<Int> = []
        var firstSeen: Set<Double> = []
        for step in 0..<10 {
            let box = CGRect(x: 0.1 + Double(step) * 0.06, y: 0.4, width: 0.1, height: 0.2)  // fast sideways
            for object in tracker.update([chair(box)], at: Double(step) * 0.13) {
                ids.insert(object.id)
                firstSeen.insert(object.firstSeenAt)
            }
        }
        #expect(ids.count == 1)
        #expect(firstSeen == [0])
    }

    @Test func growingBoxMeansApproaching() {
        var tracker = Tracker()
        var growth: Double?
        for step in 0..<10 {
            let height = 0.2 * (1 + 0.3 * Double(step) * 0.13)  // grows 30% of its size per second
            let box = CGRect(x: 0.45, y: 0.5 - height / 2, width: 0.1, height: height)
            growth = tracker.update([chair(box)], at: Double(step) * 0.13).first?.growthRate ?? growth
        }
        let rate = try! #require(growth)
        #expect(rate > 0.15 && rate < 0.4, "growth \(rate)/s")
    }
}
