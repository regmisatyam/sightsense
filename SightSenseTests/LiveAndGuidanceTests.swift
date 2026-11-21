import AVFoundation
import Foundation
import Testing
@testable import SightSense

@Suite("Taking someone to the way out")
struct GuidanceTests {
    @Test(arguments: ["Show me the way out", "how do I get out of here", "take me outside", "Get me out",
                      "show me way to go out", "Take me to the exit"])
    func wayOutPhrases(_ spoken: String) {
        #expect(VoiceCommand.parse(spoken) == .guide(target: "the way out"))
    }

    @Test func guideToAnything() {
        #expect(VoiceCommand.parse("Take me to the door") == .guide(target: "door"))
        #expect(VoiceCommand.parse("guide me to the elevator") == .guide(target: "elevator"))
        #expect(VoiceCommand.parse("show me the way to the counter") == .guide(target: "counter"))
        #expect(VoiceCommand.parse("where is the door") == .find(target: "door", question: "where is the door"))
        #expect(VoiceCommand.parse("live mode") == .liveMode)
    }

    @Test func coachSpeaksUpWhenItMattersThenArrives() {
        var coach = GuidanceCoach(name: "the way out")
        #expect(coach.next(bearing: -20, meters: 5.6, label: "exit door", now: 0) == .update("Exit door, left, 8 steps."))
        #expect(coach.next(bearing: -18, meters: 5.2, label: "exit door", now: 1.5) == .quiet)        // nothing new
        #expect(coach.next(bearing: -2, meters: 5.0, label: "exit door", now: 3) == .update("Exit door, ahead, 7 steps."))  // turned toward it
        #expect(coach.next(bearing: 0, meters: 3.4, label: "exit door", now: 5) == .update("Exit door, ahead, 5 steps."))   // 2 steps closer
        #expect(coach.next(bearing: 1, meters: 0.8, label: "exit door", now: 9) == .arrived("You're at the exit door. It should be within arm's reach."))
    }

    @Test func coachHandlesLosingSight() {
        var coach = GuidanceCoach(name: "the way out")
        _ = coach.next(bearing: 10, meters: 4, label: "door", now: 0)
        #expect(coach.next(bearing: nil, meters: nil, label: nil, now: 1) == .quiet)
        #expect(coach.next(bearing: nil, meters: nil, label: nil, now: 5) == .lost("I've lost sight of it. Turn slowly toward the sound."))
        #expect(coach.next(bearing: nil, meters: nil, label: nil, now: 8) == .quiet)  // said once
        #expect(coach.next(bearing: nil, meters: nil, label: nil, now: 32)
                == .giveUp("I can't find the way out from here. Try turning around, or ask someone nearby."))
    }

    @Test func modeButtonCyclesThroughLive() {
        #expect(AppMode.navigate.next == .calm)
        #expect(AppMode.calm.next == .live)
        #expect(AppMode.live.next == .navigate)
    }
}

@Suite("The agent's Gemini Live messages (shapes captured from the live service)")
struct AgentProtocolTests {
    func parse(_ json: String) -> [AgentIncoming] { AgentProtocol.parse(Data(json.utf8)) }

    @Test func setupAndHousekeeping() {
        #expect(parse(#"{"setupComplete": {}}"#) == [.setupComplete])
        #expect(parse("{}").isEmpty)  // sent while the model thinks; must be ignored, not treated as the end
        #expect(parse(#"{"sessionResumptionUpdate": {"newHandle": "d50ee446", "resumable": true}}"#) == [.resumeHandle("d50ee446")])
        #expect(parse(#"{"goAway": {"timeLeft": "10s"}}"#) == [.goAway])
    }

    @Test func toolCallsWithTextAndBooleanArguments() {
        let guide = #"{"toolCall": {"functionCalls": [{"name": "guide_to", "args": {"target": "the way out"}, "id": "call_147"}]}}"#
        #expect(parse(guide) == [.toolCall(id: "call_147", name: "guide_to", args: ["target": "the way out"])])
        let beeps = #"{"toolCall": {"functionCalls": [{"name": "set_beeps", "args": {"on": false}, "id": "c2"}]}}"#
        #expect(parse(beeps) == [.toolCall(id: "c2", name: "set_beeps", args: ["on": "false"])])
        let measure = #"{"toolCall": {"functionCalls": [{"name": "get_obstacles", "id": "c3"}]}}"#
        #expect(parse(measure) == [.toolCall(id: "c3", name: "get_obstacles", args: [:])])
    }

    @Test func speechAndTranscripts() {
        let pcm = Data([0x10, 0x00, 0xF0, 0xFF])
        let message = """
        {"serverContent": {"modelTurn": {"parts": [{"inlineData": {"mimeType": "audio/pcm;rate=24000", "data": "\(pcm.base64EncodedString())"}}]},
         "outputTranscription": {"text": "A door is"}, "inputTranscription": {"text": "Where's the door"}}}
        """
        #expect(parse(message) == [.audio(pcm), .aiText("A door is"), .userText("Where's the door")])
        #expect(parse(#"{"serverContent": {"interrupted": true}}"#) == [.interrupted])
        #expect(parse(#"{"serverContent": {"turnComplete": true}}"#) == [.turnComplete])
    }

    @Test func setupAsksForWhatTheAppNeeds() throws {
        let setup = try #require(AgentProtocol.setup(model: "gemini-3.8-live", voice: "Sulafat", pace: "brisk",
                                                     resumeHandle: "h1")["setup"] as? [String: Any])
        #expect(setup["model"] as? String == "models/gemini-3.8-live")
        #expect(setup["contextWindowCompression"] != nil)  // long video sessions
        #expect((setup["sessionResumption"] as? [String: Any])?["handle"] as? String == "h1")
        let config = try #require(setup["generationConfig"] as? [String: Any])
        #expect(config["responseModalities"] as? [String] == ["AUDIO"])
        let instruction = try #require(((setup["systemInstruction"] as? [String: Any])?["parts"] as? [[String: Any]])?.first?["text"] as? String)
        #expect(instruction.contains("brisk pace"))
        #expect(instruction.contains("[APP] SAY"))
        let detection = (setup["realtimeInputConfig"] as? [String: Any])?["automaticActivityDetection"] as? [String: Any]
        #expect(detection?["silenceDurationMs"] as? Int == 400)  // answers ~0.7 s after you stop talking
    }

    @Test func everyToolIsDeclaredAndSlowOnesAreKnown() throws {
        let declarations = try #require(AgentProtocol.tools.first?["functionDeclarations"] as? [[String: Any]])
        let names = Set(declarations.compactMap { $0["name"] as? String })
        #expect(names == ["get_obstacles", "find", "guide_to", "stop_guidance", "read_text", "look_closely",
                          "where_am_i", "nearby_places", "remember_person", "forget_person", "who_is_here",
                          "set_mode", "set_beeps", "set_announcements"])
        #expect(AgentProtocol.slowTools.isSubset(of: names))
        #expect(!AgentProtocol.slowTools.contains("get_obstacles"))  // instant, answered directly
    }

    @Test func appMessages() throws {
        // Exact words: realtime text, so it starts in ~0.5 s and cuts off anything playing.
        let say = try #require(AgentProtocol.say("Stop. Chair, ahead, 2 steps.")["realtimeInput"] as? [String: Any])
        #expect(say["text"] as? String == "[APP] SAY: Stop. Chair, ahead, 2 steps.")
        // Context: an unfinished turn, so the agent stays silent (measured).
        let context = try #require(AgentProtocol.context("They started walking.")["clientContent"] as? [String: Any])
        #expect(context["turnComplete"] as? Bool == false)
        // A slow tool's result arrives later as its own message.
        let result = try #require(AgentProtocol.result(of: "look_closely", "The sign says EXIT.")["realtimeInput"] as? [String: Any])
        #expect(result["text"] as? String == "[APP] RESULT of look_closely: The sign says EXIT.")
        #expect(AgentProtocol.audioStreamEnd["realtimeInput"] != nil)
    }

    @Test func agentModelsHaveFallbacks() {
        #expect(GeminiModels.defaults.chain(for: .live).map(\.model)
                == ["gemini-3.8-live", "gemini-3.1-flash-live-preview", "gemini-2.5-flash-native-audio-latest"])
    }
}

@Suite("Audio from the agent")
struct PCMTests {
    @Test func littleEndianSamplesBecomeFloats() throws {
        // 0x4000 = 16384 → 0.5; 0xC000 = -16384 → -0.5 (little-endian byte order).
        let buffer = try #require(PCM.floatBuffer(from: Data([0x00, 0x40, 0x00, 0xC0])))
        #expect(buffer.frameLength == 2)
        let samples = try #require(buffer.floatChannelData?[0])
        #expect(samples[0] == 0.5)
        #expect(samples[1] == -0.5)
        #expect(buffer.format.sampleRate == 24_000)
    }
}
