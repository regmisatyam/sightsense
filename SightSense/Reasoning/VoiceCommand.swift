import Foundation

/// What a spoken request means. Short, familiar phrases are commands handled on the phone
/// (so they work offline and instantly); anything else is a question for the AI.
nonisolated enum VoiceCommand: Equatable, Sendable {
    case describe, read, whereAmI, aroundMe, aheadOfMe
    case calmMode, navigationMode, switchMode
    case beepsOn, beepsOff
    case fewer, more, stop, help
    /// "Find the door", "where is the exit": point at it, say where it is, and guide with the beacon.
    case find(target: String, question: String)
    /// "Show me the way out", "take me to the door": keep finding it and steer them there until they arrive.
    case guide(target: String)
    case liveMode
    /// "Look carefully, is the light green?": the strongest model, more slowly.
    case deepQuestion(String)
    case question(String)

    static let helpText = """
    You can say: describe, read this, where am I, what's around me, what's ahead, \
    find the door, show me the way out, calm mode, live mode, navigation mode, beeps off, beeps on, \
    fewer, more, or stop. \
    Or ask any question about what's in front of you, like: is there an empty seat? \
    Start with "look carefully" for a slower, more careful answer.
    """

    static func parse(_ text: String) -> VoiceCommand {
        let words = text.lowercased()
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: "’", with: "")
            .components(separatedBy: CharacterSet.letters.inverted)
            .filter { !$0.isEmpty }
        var phrase = words
        while let first = phrase.first, ["please", "hey", "ok", "okay", "sightsense", "now"].contains(first) { phrase.removeFirst() }
        while let last = phrase.last, ["please", "now", "thanks"].contains(last) { phrase.removeLast() }
        guard !phrase.isEmpty else { return .question(text) }

        for prefix in deepPrefixes where phrase.starts(with: prefix) && phrase.count > prefix.count {
            return .deepQuestion(phrase.dropFirst(prefix.count).joined(separator: " "))
        }
        // Long utterances are questions, even if they contain a command word.
        guard phrase.count <= 7 else { return .question(text) }
        let spoken = phrase.joined(separator: " ")
        if let command = commands.first(where: { $0.phrases.contains(spoken) })?.command {
            return command
        }
        if wayOut.contains(spoken) { return .guide(target: "the way out") }
        for prefix in guidePrefixes where phrase.starts(with: prefix) && phrase.count > prefix.count {
            var target = Array(phrase.dropFirst(prefix.count))
            while let first = target.first, ["the", "a", "an", "my"].contains(first) { target.removeFirst() }
            if !target.isEmpty { return .guide(target: target.joined(separator: " ")) }
        }
        for prefix in findPrefixes where phrase.starts(with: prefix) && phrase.count > prefix.count {
            var target = Array(phrase.dropFirst(prefix.count))
            while let first = target.first, ["the", "a", "an", "my", "some"].contains(first) { target.removeFirst() }
            if !target.isEmpty { return .find(target: target.joined(separator: " "), question: text) }
        }
        return .question(text)
    }

    private static let deepPrefixes: [[String]] = [
        ["look", "carefully"], ["think", "carefully"], ["take", "your", "time"], ["think", "hard"], ["carefully"],
    ]

    private static let findPrefixes: [[String]] = [
        ["find", "me"], ["find"], ["look", "for"], ["where", "is"], ["wheres"], ["where", "are"], ["locate"],
    ]

    private static let wayOut: Set<String> = [
        "show me the way out", "the way out", "way out", "how do i get out", "how do i get out of here",
        "get me out", "get me out of here", "take me out", "take me outside", "show me the exit",
        "take me to the exit", "guide me out", "lead me out", "i want to go out", "i want to leave",
        "show me way to go out", "show me the way to go out",
    ]

    private static let guidePrefixes: [[String]] = [
        ["show", "me", "the", "way", "to"], ["take", "me", "to"], ["guide", "me", "to"], ["lead", "me", "to"],
        ["walk", "me", "to"], ["bring", "me", "to"], ["help", "me", "get", "to"],
    ]

    private static let commands: [(command: VoiceCommand, phrases: Set<String>)] = [
        (.stop, ["stop", "stop talking", "be quiet", "quiet", "cancel", "shush", "shut up"]),
        (.help, ["help", "what can i say", "commands", "what can you do"]),
        (.whereAmI, ["where am i", "where are we", "my location", "wheres this"]),
        (.aroundMe, ["whats around me", "whats around", "around me", "whats nearby", "nearby", "nearby places"]),
        (.aheadOfMe, ["whats ahead", "whats ahead of me", "ahead of me", "ahead"]),
        (.read, ["read", "read this", "read it", "read the text", "read text", "read the sign", "read that"]),
        (.describe, ["describe", "describe this", "describe the scene", "what do you see", "whats in front of me",
                     "what is in front of me", "look", "whats here", "describe it"]),
        (.calmMode, ["calm mode", "calm", "switch to calm mode", "calm mode on"]),
        (.navigationMode, ["navigation mode", "navigation", "navigate", "switch to navigation mode", "navigation mode on"]),
        (.switchMode, ["switch mode", "change mode", "toggle mode", "other mode", "switch modes"]),
        (.liveMode, ["live mode", "live", "go live", "start live", "talk to me", "live conversation"]),
        (.beepsOff, ["beeps off", "beep off", "turn off beeps", "turn beeps off", "stop beeping", "no beeps", "mute beeps"]),
        (.beepsOn, ["beeps on", "beep on", "turn on beeps", "turn beeps on", "unmute beeps"]),
        (.fewer, ["fewer", "fewer announcements", "less", "quieter", "less talking", "talk less"]),
        (.more, ["more", "more announcements", "tell me more", "talk more", "more detail"]),
    ]
}
