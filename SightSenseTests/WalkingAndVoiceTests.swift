import Foundation
import Testing
@testable import SightSense

@Suite("Walking or standing, from footsteps")
struct WalkingDetectorTests {
    let rate = 15.0  // motion samples arrive with camera frames

    /// Feeds `seconds` of a signal; returns whether it ended up "walking" and when it first did.
    func run(_ detector: inout WalkingDetector, from start: Double = 0, seconds: Double, gps: Double? = nil,
             signal: (Double) -> Double) -> (walking: Bool, firstWalkingAt: Double?) {
        var first: Double?
        var t = start
        while t < start + seconds {
            if detector.add(upward: signal(t), at: t, gpsSpeed: gps), first == nil { first = t }
            t += 1 / rate
        }
        return (detector.isWalking, first)
    }

    @Test func walkingIsRecognizedWithinTwoSeconds() throws {
        var detector = WalkingDetector()
        var noise = SeededRandom(seed: 1)
        let result = run(&detector, seconds: 5) { t in 0.25 * sin(2 * .pi * 1.8 * t) + Double.random(in: -0.02...0.02, using: &noise) }
        #expect(result.walking)
        #expect(try #require(result.firstWalkingAt) < 2)
    }

    @Test func slowCarefulWalkingCounts() {
        var detector = WalkingDetector()
        #expect(run(&detector, seconds: 6) { t in 0.12 * sin(2 * .pi * 1.2 * t) }.walking)
    }

    @Test(arguments: [0.0, 0.02, 0.05])
    func standingOrHandlingThePhoneIsNotWalking(jitter: Double) {
        var detector = WalkingDetector()
        var noise = SeededRandom(seed: 2)
        #expect(run(&detector, seconds: 20) { _ in Double.random(in: -jitter...jitter, using: &noise) }.firstWalkingAt == nil)
    }

    @Test func swayingAndBreathingAreNotWalking() {
        var detector = WalkingDetector()
        #expect(run(&detector, seconds: 20) { t in 0.04 * sin(2 * .pi * 0.3 * t) }.firstWalkingAt == nil)
    }

    @Test func stoppingIsNoticedWithinThreeSeconds() {
        var detector = WalkingDetector()
        _ = run(&detector, seconds: 5) { t in 0.25 * sin(2 * .pi * 1.8 * t) }
        #expect(detector.isWalking)
        var stoppedAt: Double?
        var t = 5.0
        while t < 10, stoppedAt == nil {
            if !detector.add(upward: 0, at: t) { stoppedAt = t }
            t += 1 / rate
        }
        #expect((stoppedAt ?? 99) < 8)
    }

    @Test func gpsSpeedAloneCounts() {
        var detector = WalkingDetector()
        #expect(run(&detector, seconds: 1, gps: 1.2) { _ in 0 }.walking)
        #expect(!run(&detector, from: 1, seconds: 1, gps: 0.1) { _ in 0 }.walking)
    }
}

@Suite("Spoken commands and questions")
struct VoiceCommandTests {
    @Test(arguments: [
        ("Where am I?", VoiceCommand.whereAmI),
        ("Hey SightSense, read this please", .read),
        ("What's around me", .aroundMe),
        ("what’s ahead", .aheadOfMe),
        ("Describe", .describe),
        ("What's in front of me?", .describe),
        ("Calm mode.", .calmMode),
        ("navigation mode", .navigationMode),
        ("switch mode", .switchMode),
        ("Beeps off", .beepsOff),
        ("Turn beeps on", .beepsOn),
        ("Stop", .stop),
        ("quieter", .fewer),
        ("more", .more),
        ("what can I say", .help),
    ])
    func commands(_ spoken: String, _ expected: VoiceCommand) {
        #expect(VoiceCommand.parse(spoken) == expected)
    }

    @Test(arguments: [
        "Is there an empty seat near me?",
        "What color is the door?",
        "Can you read the menu on the wall for me",
        "Is the traffic light green",
    ])
    func everythingElseIsAQuestion(_ spoken: String) {
        #expect(VoiceCommand.parse(spoken) == .question(spoken))
    }
}
