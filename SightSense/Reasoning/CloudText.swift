import Foundation

/// Cuts streamed text into whole sentences, so each can be spoken as soon as it's complete.
nonisolated struct SentenceSplitter {
    private var buffer = ""

    /// Adds a chunk of text and returns any sentences it completed.
    mutating func add(_ text: String) -> [String] {
        buffer += text
        var sentences: [String] = []
        while let end = Self.endOfSentence(in: buffer) {
            let sentence = buffer[..<end].trimmingCharacters(in: .whitespacesAndNewlines)
            buffer = String(buffer[end...])
            if !sentence.isEmpty { sentences.append(sentence) }
        }
        return sentences
    }

    /// Whatever is left when the stream ends.
    mutating func finish() -> String? {
        let rest = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        buffer = ""
        return rest.isEmpty ? nil : rest
    }

    /// Just past the first ".", "!" or "?" that is followed by whitespace (so "3.5" doesn't split).
    private static func endOfSentence(in text: String) -> String.Index? {
        var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(after: index)
            if ".!?".contains(text[index]), next < text.endIndex, text[next].isWhitespace {
                return next
            }
            index = next
        }
        return nil
    }
}

/// Drops sentences that vouch for safety ("the path is clear", "it's safe to cross").
/// A cloud description of one photo can't know that; only the user's cane, dog, and judgment can.
nonisolated enum SafetyFilter {
    private static let patterns = [
        #"\b(path|way|route|walkway|sidewalk|pavement|road|street|crossing|coast)\b[^.]{0,25}\b(is|looks|seems|appears)\b[^.]{0,12}\b(clear|safe|free|open|unobstructed|empty)\b"#,
        #"\bno (obstacles|hazards|obstructions|barriers)\b"#,
        #"\b(it'?s|it is) (safe|clear)\b"#,
        #"\b(safe|clear) to (walk|cross|proceed|continue|go|move)\b"#,
        #"\bnothing (is )?(in|blocking) (your|the) (way|path)\b"#,
    ]

    static func allows(_ sentence: String) -> Bool {
        let lower = sentence.lowercased()
        return !patterns.contains { lower.range(of: $0, options: .regularExpression) != nil }
    }
}
