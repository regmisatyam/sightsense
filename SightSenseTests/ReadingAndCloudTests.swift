import CoreGraphics
import Testing
@testable import SightSense

@Suite("Aiming the camera at text without sight")
struct AimingCoachTests {
    @Test func hints() {
        let centered = CGRect(x: 0.2, y: 0.4, width: 0.6, height: 0.05)
        #expect(AimingCoach.hint(for: [], steady: true) == .noText)
        #expect(AimingCoach.hint(for: [centered], steady: true) == .ready)
        #expect(AimingCoach.hint(for: [centered], steady: false) == .holdSteady)
        #expect(AimingCoach.hint(for: [CGRect(x: 0.2, y: 0, width: 0.5, height: 0.05)], steady: true) == .cutOff(.top))
        #expect(AimingCoach.hint(for: [CGRect(x: 0.5, y: 0.5, width: 0.5, height: 0.05)], steady: true) == .cutOff(.right))
        #expect(AimingCoach.hint(for: [CGRect(x: 0, y: 0.4, width: 1, height: 0.05)], steady: true) == .moveBack)
        #expect(AimingCoach.hint(for: [CGRect(x: 0.4, y: 0.5, width: 0.1, height: 0.008)], steady: true) == .moveCloser)
    }

    @Test func everyHintButReadyIsSpoken() {
        #expect(AimingHint.cutOff(.top).phrase == "Text continues above. Tilt up a little.")
        #expect(AimingHint.ready.phrase == nil)
    }
}

@Suite("Streaming and safety of cloud descriptions")
struct CloudTextTests {
    @Test func splitsSentencesAcrossChunks() {
        var splitter = SentenceSplitter()
        #expect(splitter.add("A bench is to your le").isEmpty)
        #expect(splitter.add("ft, 3.5 meters away. A door") == ["A bench is to your left, 3.5 meters away."])
        #expect(splitter.add(" is ahead! Then") == ["A door is ahead!"])
        #expect(splitter.finish() == "Then")
        #expect(splitter.finish() == nil)
    }

    @Test(arguments: [
        "The path ahead is clear.",
        "The sidewalk looks safe.",
        "It's safe to cross now.",
        "There are no obstacles in front of you.",
        "Nothing is blocking your way.",
    ])
    func dropsSafetyClaims(_ sentence: String) {
        #expect(!SafetyFilter.allows(sentence))
    }

    @Test(arguments: [
        "A bench is to your left, 3 steps away.",
        "The street is busy with traffic.",
        "There is a crossing ahead with a signal.",
        "A clear glass door is straight ahead.",
    ])
    func keepsUsefulDescriptions(_ sentence: String) {
        #expect(SafetyFilter.allows(sentence))
    }
}
