import Foundation
import Testing
@testable import SightSense

@Suite("Recognizing saved people")
struct FaceMatcherTests {
    @Test func matchesOnlyWithinTheLimitAndClearlyBest() {
        // Alex 0.30 (limit 0.40), Sam 0.70: Alex.
        #expect(FaceMatcher.decide(distances: [0.30, 0.70], limits: [0.40, 0.40]).index == 0)
        // Too far from everyone: nobody.
        #expect(FaceMatcher.decide(distances: [0.55, 0.80], limits: [0.40, 0.40]).index == nil)
        // Two saved people about equally close: don't guess.
        #expect(FaceMatcher.decide(distances: [0.30, 0.33], limits: [0.40, 0.40]).index == nil)
        // Only one person saved: the limit alone decides.
        #expect(FaceMatcher.decide(distances: [0.35], limits: [0.40]).index == 0)
        #expect(FaceMatcher.decide(distances: [], limits: []).index == nil)
    }

    @Test func limitFollowsHowMuchTheirOwnViewsVary() {
        #expect(FaceMatcher.limit(ownDistances: [0.05, 0.06, 0.07]) == 0.32)   // very similar views: the floor
        #expect(abs(FaceMatcher.limit(ownDistances: [0.25, 0.25, 0.25]) - 0.4) < 0.01)            // 1.6 × 0.25
        #expect(FaceMatcher.limit(ownDistances: [0.40, 0.45]) == 0.5)          // varied views: the ceiling
    }
}

@Suite("Announcing saved people")
struct RecognitionTrackerTests {
    @Test func oneStrayMatchIsNotEnough() {
        var tracker = RecognitionTracker()
        #expect(tracker.update(matched: ["Alex"], known: ["Alex"], now: 0).isEmpty)
        #expect(tracker.update(matched: [], known: ["Alex"], now: 0.5).isEmpty)
        #expect(tracker.update(matched: [], known: ["Alex"], now: 1).isEmpty)
        #expect(tracker.inView.isEmpty)
    }

    @Test func announcedOnceWhenTheyArriveAndNotAgainForTwoMinutes() {
        var tracker = RecognitionTracker()
        _ = tracker.update(matched: ["Alex"], known: ["Alex"], now: 0)
        #expect(tracker.update(matched: ["Alex"], known: ["Alex"], now: 0.5) == ["Alex"])  // 2 of 3
        #expect(tracker.update(matched: ["Alex"], known: ["Alex"], now: 1).isEmpty)        // still here: quiet
        for t in [1.5, 2, 2.5] { _ = tracker.update(matched: [], known: ["Alex"], now: t) }  // walks away
        #expect(tracker.inView.isEmpty)
        _ = tracker.update(matched: ["Alex"], known: ["Alex"], now: 60)
        #expect(tracker.update(matched: ["Alex"], known: ["Alex"], now: 60.5).isEmpty)     // back within 2 min
        #expect(tracker.inView == ["Alex"])
        for t in [61.0, 61.5, 62] { _ = tracker.update(matched: [], known: ["Alex"], now: t) }
        _ = tracker.update(matched: ["Alex"], known: ["Alex"], now: 200)
        #expect(tracker.update(matched: ["Alex"], known: ["Alex"], now: 200.5) == ["Alex"])  // a while later
    }

    @Test func forgottenPeopleDisappear() {
        var tracker = RecognitionTracker()
        _ = tracker.update(matched: ["Alex"], known: ["Alex"], now: 0)
        _ = tracker.update(matched: ["Alex"], known: ["Alex"], now: 0.5)
        _ = tracker.update(matched: [], known: [], now: 1)
        #expect(tracker.inView.isEmpty)
    }

    @Test func namesAreTidied() {
        #expect(PeopleWatcher.clean("  alex. ") == "Alex")
        #expect(PeopleWatcher.clean("Mary Jane") == "Mary Jane")
        #expect(PeopleWatcher.clean("?!") == "")
    }
}
