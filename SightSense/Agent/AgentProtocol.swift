import Foundation

/// What the Gemini Live server can tell us, decoded from one WebSocket message.
nonisolated enum AgentIncoming: Equatable, Sendable {
    case setupComplete
    /// AI speech: 16-bit little-endian PCM at 24 kHz.
    case audio(Data)
    /// What the AI is saying, as text (arrives in pieces).
    case aiText(String)
    /// What the person said, as text (arrives in pieces).
    case userText(String)
    /// New input arrived while the AI was answering; that answer stopped.
    case interrupted
    case turnComplete
    case toolCall(id: String, name: String, args: [String: String])
    /// A handle for picking the conversation up again after a reconnect.
    case resumeHandle(String)
    /// The server will close this connection soon.
    case goAway
}

/// The agent's instructions, tools, and Gemini Live API messages
/// (each behaviour verified against the live service, Nov 2026).
nonisolated enum AgentProtocol {
    /// How the agent behaves. `pace` is from Settings › Speaking pace ("relaxed", "natural", "brisk").
    static func systemInstruction(pace: String) -> String {
        """
        You are SightSense, the voice, eyes, and helper of a blind person, speaking through an app on a phone worn \
        on their chest. You see the camera continuously; it faces the way they face. Speak warmly and briefly, at a \
        \(pace) pace: one or two short sentences unless they ask for more. Mention anything in their path first. Use \
        directions like straight ahead, slightly left, slightly right, to your left, to your right, and distances in \
        walking steps (one step is about 70 centimeters). Never say the way is clear or safe; they rely on their \
        cane or guide dog for that. Never identify anyone from their appearance yourself, or guess their age or \
        ethnicity. Only the app recognizes people, and only people the person saved themselves (on the phone, \
        never sent anywhere). Light, kind humor is welcome.

        Messages that begin with [APP] come from the app, not the person:
        - "[APP] SAY: words" means: immediately say exactly those words, word for word, and nothing else.
        - "[APP] CONTEXT: facts" is information for you; don't reply to it.
        - "[APP] RESULT of <tool>: …" is what a tool you called found; tell them now, in a sentence or two.
        - Any other [APP] message is a request; do what it asks, speaking to the person.

        Use your tools to act for them; don't just talk about doing it:
        - get_obstacles whenever you mention how far something is: it has the phone's measured distances.
        - guide_to when they want to be guided, taken, or shown the way to something (the way out, a door, stairs, a seat).
        - find to locate one thing precisely and play a sound from its direction.
        - read_text to read signs, labels, menus, or documents exactly.
        - look_closely for fine details: small print, colors, counting, expressions.
        - where_am_i and nearby_places for their location and what's around.
        - remember_person whenever they ask you to save or remember someone, with a name (like "save this \
          person as Alex"). Always call it, even if you can't see anyone clearly (faces are blurred for you): \
          the phone looks for the face itself and says what went wrong. No name given? Ask for one first.
        - who_is_here whenever they ask who someone is, who's around, or whether someone they know is here; \
          never guess who anyone is. forget_person to delete someone. The app itself says when a saved \
          person comes into view.
        - set_mode, set_beeps, set_announcements, stop_guidance when they ask to change how the app behaves.
        Some tools take a few seconds and answer "Started": then say only a few words, like "Let me look closely.", \
        and tell them the result when it arrives. After any other tool, tell them the result in a sentence or two.
        """
    }

    /// The tools the agent can call. Each is handled by `AppModel.runTool`.
    static var tools: [[String: Any]] { [["functionDeclarations": [
        tool("get_obstacles", "Measured direction and distance of things in front of the person, from the phone's depth and object sensors."),
        tool("find", "Locate one specific thing in view precisely (direction and distance) and play a sound from its direction.",
             ["target": string("What to find, e.g. door, empty chair, my bag")]),
        tool("guide_to", """
             Guide the person step by step with sound to something they want to walk to, such as the way out, a door, \
             stairs, or a seat, even if it isn't in view yet: the app keeps searching with the camera while they turn.
             """, ["target": string("What to guide them to, e.g. the way out, a door, the counter")]),
        tool("stop_guidance", "Stop step-by-step guidance and its sound."),
        tool("read_text", "Read the text in front of the person exactly, using the phone's text reader; it helps them aim. Returns the text."),
        tool("look_closely", "Ask a slower, more careful vision model about fine details: small print, colors, counting, expressions.",
             ["question": string("What to look closely at")]),
        tool("where_am_i", "Street address, area, which way they face, and the nearest named place."),
        tool("nearby_places", "Named places around the person, or only ahead of them, with directions and distances.",
             ["direction": string("around or ahead", options: ["around", "ahead"])]),
        tool("remember_person", """
             Save the face of the person in front of the camera under a name, on the phone only, so the app can \
             say when that person is in view later. Takes about 3 seconds; they should face the camera.
             """, ["name": string("The person's name, e.g. Alex")]),
        tool("forget_person", "Delete a saved person's face from the phone.", ["name": string("Their name")]),
        tool("who_is_here", "Saved people in view now, with where they are, and how many other faces."),
        tool("set_mode", "Switch mode: navigation (quiet unless something's in the way), calm (gentle narration), or live (always listening).",
             ["mode": string("The mode", options: ["navigation", "calm", "live"])]),
        tool("set_beeps", "Turn proximity beeps on (only while walking) or off.", ["on": ["type": "BOOLEAN"]]),
        tool("set_announcements", "Announce fewer or more things about the surroundings.",
             ["amount": string("fewer or more", options: ["fewer", "more"])]),
    ]]] }

    /// Tools that take seconds (network or a slower model). They answer "Started" at once and send
    /// the result later as "[APP] RESULT …", because Gemini Live holds back everything else, even an
    /// urgent alert, while a tool call is unanswered (measured: a 5 s tool delayed an alert by 5 s).
    static let slowTools: Set<String> = ["find", "read_text", "look_closely", "where_am_i", "nearby_places", "remember_person"]

    private static func tool(_ name: String, _ description: String, _ properties: [String: Any] = [:]) -> [String: Any] {
        var declaration: [String: Any] = ["name": name, "description": description]
        if !properties.isEmpty {
            declaration["parameters"] = ["type": "OBJECT", "properties": properties, "required": Array(properties.keys)]
        }
        return declaration
    }

    private static func string(_ description: String, options: [String]? = nil) -> [String: Any] {
        var schema: [String: Any] = ["type": "STRING", "description": description]
        if let options { schema["enum"] = options }
        return schema
    }

    static func setup(model: String, voice: String, pace: String, resumeHandle: String?) -> [String: Any] {
        var session: [String: Any] = [:]
        if let resumeHandle { session["handle"] = resumeHandle }
        return ["setup": [
            "model": "models/\(model)",
            "generationConfig": [
                "responseModalities": ["AUDIO"],
                "speechConfig": ["voiceConfig": ["prebuiltVoiceConfig": ["voiceName": voice]]],
            ],
            "systemInstruction": ["parts": [["text": systemInstruction(pace: pace)]]],
            "inputAudioTranscription": [String: Any](),
            "outputAudioTranscription": [String: Any](),
            // Answer ~0.7 s after the person stops talking (measured), instead of ~2 s by default.
            "realtimeInputConfig": ["automaticActivityDetection": [
                "endOfSpeechSensitivity": "END_SENSITIVITY_HIGH", "silenceDurationMs": 400,
            ]],
            // Long sessions with video need the context to slide, or they end after a couple of minutes.
            "contextWindowCompression": ["slidingWindow": [String: Any]()],
            "sessionResumption": session,
            "tools": tools,
        ]]
    }

    static func audio(_ pcm: Data) -> [String: Any] {
        ["realtimeInput": ["audio": ["data": pcm.base64EncodedString(), "mimeType": "audio/pcm;rate=16000"]]]
    }

    /// The person stopped talking (mic closed).
    static var audioStreamEnd: [String: Any] { ["realtimeInput": ["audioStreamEnd": true]] }

    static func video(_ jpeg: Data) -> [String: Any] {
        ["realtimeInput": ["video": ["data": jpeg.base64EncodedString(), "mimeType": "image/jpeg"]]]
    }

    /// Something to respond to now (a question, or an [APP] request). Interrupts any answer in progress.
    static func text(_ text: String) -> [String: Any] {
        ["realtimeInput": ["text": text]]
    }

    /// Exact words for the agent to say, in its own voice (~0.5 s to first sound, measured).
    static func say(_ words: String) -> [String: Any] {
        text("[APP] SAY: \(words)")
    }

    /// Information for the agent that needs no reply (sent as an unfinished turn).
    static func context(_ facts: String) -> [String: Any] {
        ["clientContent": ["turns": [["role": "user", "parts": [["text": "[APP] CONTEXT: \(facts)"]]]], "turnComplete": false]]
    }

    /// A slow tool's result, arriving after its "Started" response.
    static func result(of tool: String, _ text: String) -> [String: Any] {
        self.text("[APP] RESULT of \(tool): \(text)")
    }

    static func toolResponse(id: String, name: String, result: String) -> [String: Any] {
        ["toolResponse": ["functionResponses": [["id": id, "name": name, "response": ["result": result]]]]]
    }

    static func parse(_ data: Data) -> [AgentIncoming] {
        guard let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        var events: [AgentIncoming] = []
        if message["setupComplete"] != nil { events.append(.setupComplete) }
        if message["goAway"] != nil { events.append(.goAway) }
        if let update = message["sessionResumptionUpdate"] as? [String: Any],
           update["resumable"] as? Bool == true, let handle = update["newHandle"] as? String {
            events.append(.resumeHandle(handle))
        }
        if let call = message["toolCall"] as? [String: Any], let calls = call["functionCalls"] as? [[String: Any]] {
            for item in calls {
                let raw = item["args"] as? [String: Any] ?? [:]
                let args = raw.mapValues { value in (value as? String) ?? (value as? Bool).map { $0 ? "true" : "false" } ?? "\(value)" }
                events.append(.toolCall(id: item["id"] as? String ?? "", name: item["name"] as? String ?? "", args: args))
            }
        }
        if let content = message["serverContent"] as? [String: Any] {
            if content["interrupted"] as? Bool == true { events.append(.interrupted) }
            if let turn = content["modelTurn"] as? [String: Any], let parts = turn["parts"] as? [[String: Any]] {
                for part in parts {
                    if let inline = part["inlineData"] as? [String: Any], let base64 = inline["data"] as? String,
                       let pcm = Data(base64Encoded: base64) {
                        events.append(.audio(pcm))
                    }
                }
            }
            if let said = (content["outputTranscription"] as? [String: Any])?["text"] as? String { events.append(.aiText(said)) }
            if let heard = (content["inputTranscription"] as? [String: Any])?["text"] as? String { events.append(.userText(heard)) }
            if content["turnComplete"] as? Bool == true { events.append(.turnComplete) }
        }
        return events
    }
}
