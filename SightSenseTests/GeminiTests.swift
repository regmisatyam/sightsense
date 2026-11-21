import CoreGraphics
import Foundation
import Testing
@testable import SightSense

@Suite("Choosing Gemini models per job")
struct GeminiModelsTests {
    let models = GeminiModels.defaults

    @Test func eachJobHasTheRightModelAndAFallback() {
        #expect(models.chain(for: .fast).map(\.model) == ["gemini-4-carbon", "gemini-flash-lite-latest"])
        #expect(models.chain(for: .smart).map(\.model) == ["gemini-4-hydrogen", "gemini-flash-latest"])
        #expect(models.chain(for: .deep).map(\.model) == ["gemini-4-neon", "gemini-pro-latest"])
        #expect(models.chain(for: .spatial).map(\.model) == ["gemini-robotics-er-2-preview", "gemini-4-carbon", "gemini-flash-latest"])
        for role in GeminiModels.Role.allCases {
            #expect(models.chain(for: role).count >= 2, "\(role) needs a fallback")
        }
    }

    @Test func thinkingSuitsEachModel() {
        #expect(models.chain(for: .fast).first?.thinking == "low")       // Gemini 4 Carbon rejects "minimal"
        #expect(models.chain(for: .fast).last?.thinking == "minimal")    // Flash-Lite fallback accepts it
        #expect(models.chain(for: .smart).allSatisfy { $0.thinking == "low" })
        #expect(models.chain(for: .live).allSatisfy { $0.thinking == nil })
    }

    @Test func settingsOverrideModelsAndBlanksKeepDefaults() {
        let custom = GeminiModels(info: ["GeminiModelSmart": "gemini-3.8-flash", "GeminiModelFast": " ",
                                         "GeminiModelDeep": "$(GEMINI_MODEL_DEEP)"])
        #expect(custom.smart == "gemini-3.8-flash")
        #expect(custom.fast == models.fast)
        #expect(custom.deep == models.deep)
    }

    @Test func fallbackListHasNoDuplicates() {
        let same = GeminiModels(fast: "gemini-flash-lite-latest", smart: "m", deep: "m", spatial: "m")
        #expect(same.chain(for: .fast).map(\.model) == ["gemini-flash-lite-latest"])
    }

    @Test func rolesMatchTheJob() {
        let measured: [String] = []
        #expect(SceneDescriber.Style.describe(measured: measured, units: .steps, focus: .path, instruction: "", detailed: false).role == .fast)
        #expect(SceneDescriber.Style.describe(measured: measured, units: .steps, focus: .path, instruction: "", detailed: true).role == .smart)
        #expect(SceneDescriber.Style.answer(question: "q", measured: measured, places: [], units: .steps, deep: false).role == .smart)
        #expect(SceneDescriber.Style.answer(question: "q", measured: measured, places: [], units: .steps, deep: true).role == .deep)
        #expect(SceneDescriber.Style.calm(previous: nil).role == .fast)
        #expect(SceneDescriber.Style.readText.role == .smart)
    }
}

@Suite("Reading the spatial model's pointing")
struct FindParsingTests {
    @Test func readsPointsInsideCodeFences() {
        let reply = "```json\n[{\"point\": [454, 461], \"label\": \"door\"}, {\"point\": [100, 900], \"label\": \"door\"}]\n```"
        let found = SceneDescriber.parsePoints(reply)
        #expect(found.count == 2)
        #expect(found.first == FoundThing(label: "door", x: 0.461, y: 0.454))
    }

    @Test func nothingFoundOrGarbage() {
        #expect(SceneDescriber.parsePoints("[]").isEmpty)
        #expect(SceneDescriber.parsePoints("I can't see a door.").isEmpty)
        #expect(SceneDescriber.parsePoints("[{\"point\": [1]}]").isEmpty)
    }

    @Test func distanceToAPointFromDepth() throws {
        let camera = TestScenes.camera(fovDegrees: 100, pitchDegrees: 8)
        var scanner = PathScanner()
        let wall = TestScenes.Block(forward: 2.5, width: 3, height: 2.2)
        let depth = TestScenes.depth(camera: camera, block: wall)
        _ = scanner.scan(depth, camera: camera, now: 0)  // calibrates against the floor
        let meters = try #require(scanner.distance(at: CGPoint(x: 0.5, y: 0.35), in: depth, camera: camera))
        #expect(abs(meters - 2.5) < 0.3, "\(meters) m")
    }
}

@Suite("Find and careful questions by voice")
struct VoiceFindTests {
    @Test(arguments: [
        ("Find the door", "door"),
        ("where is the exit?", "exit"),
        ("Look for an empty chair", "empty chair"),
        ("where's my bag", "bag"),
    ])
    func find(_ spoken: String, _ target: String) {
        #expect(VoiceCommand.parse(spoken) == .find(target: target, question: spoken))
    }

    @Test func whereAmIIsStillWhereAmI() {
        #expect(VoiceCommand.parse("where am I") == .whereAmI)
        #expect(VoiceCommand.parse("where are we") == .whereAmI)
    }

    @Test func lookCarefullyUsesTheDeepModel() {
        #expect(VoiceCommand.parse("Look carefully, is the traffic light green?") == .deepQuestion("is the traffic light green"))
        #expect(VoiceCommand.parse("take your time and read the menu prices") == .deepQuestion("and read the menu prices"))
    }
}
