import Foundation

/// Something the spatial model pointed at, normalized 0–1 with the origin at the top left.
nonisolated struct FoundThing: Sendable, Equatable {
    let label: String
    let x: Double
    let y: Double
}

/// The cloud side of SightSense, built on several Gemini models (see `GeminiModels`):
/// quick looks and Calm Mode on Flash-Lite, questions and reading on Flash, "look carefully"
/// on Pro, Find on Robotics-ER, and Calm Mode's voice on a TTS model.
///
/// - Vision + AI together: the phone's own measurements go with the photo, so answers use the
///   same directions and distances as the alerts.
/// - Privacy: faces are pixelated on the phone before upload.
/// - Speed: answers stream and are handed over sentence by sentence.
/// - Safety: sentences claiming the way is clear or safe are dropped.
actor SceneDescriber {
    nonisolated enum Style: Sendable {
        /// - measured: e.g. ["a person slightly left, about 4 steps away"]
        /// - focus / instruction: what the user asked the AI to concentrate on (Settings).
        case describe(measured: [String], units: DistanceUnit, focus: DescribeFocus, instruction: String, detailed: Bool)
        case calm(previous: String?)
        /// A spoken question, answered from the photo, the phone's measurements, and nearby places.
        /// `deep` ("look carefully…") uses the strongest model.
        case answer(question: String, measured: [String], places: [String], units: DistanceUnit, deep: Bool)
        /// Read text the on-device reader couldn't.
        case readText

        var role: GeminiModels.Role {
            switch self {
            case .describe(_, _, _, _, let detailed): detailed ? .smart : .fast
            case .calm: .fast
            case .answer(_, _, _, _, let deep): deep ? .deep : .smart
            case .readText: .smart
            }
        }
    }

    typealias Failure = GeminiClient.Failure

    nonisolated let isConfigured: Bool
    nonisolated let models: GeminiModels
    private let client: GeminiClient

    init(client: GeminiClient) {
        self.client = client
        isConfigured = client.isConfigured
        models = GeminiModels(info: Bundle.main.infoDictionary ?? [:])
    }

    /// The answer, sentence by sentence as it streams in.
    func describe(_ frame: Frame, style: Style) async throws -> AsyncThrowingStream<String, Error> {
        let bytes = try await client.stream(style.role, parts: [["text": Self.prompt(for: style)], try photo(frame)])
        return Self.sentences(from: bytes)
    }

    /// Where `target` is in the frame (up to 3 matches, nearest first), from the spatial model.
    func find(_ target: String, in frame: Frame) async throws -> [FoundThing] {
        let prompt = """
        Find "\(target)" in this photo from a blind person's chest-worn camera. Answer only with JSON, no other text: \
        a list of up to 3 matches, nearest first, like [{"point": [y, x], "label": "door"}], with y and x \
        normalized to 0-1000. If there is none, answer [].
        """
        let data = try await client.generate(.spatial, parts: [["text": prompt], try photo(frame)])
        let reply = try JSONDecoder().decode(GeminiReply.self, from: data)
        return Self.parsePoints(reply.text)
    }

    private func photo(_ frame: Frame) throws -> [String: Any] {
        guard let jpeg = FrameImage.jpeg(frame, maxSide: 640, quality: 0.7, blurFaces: true) else { throw Failure.badResponse }
        return ["inline_data": ["mime_type": "image/jpeg", "data": jpeg.base64EncodedString()]]
    }

    /// Reads `[{"point": [y, x], "label": "…"}]` (0–1000), tolerating code fences and stray text.
    static func parsePoints(_ text: String) -> [FoundThing] {
        guard let start = text.firstIndex(of: "["), let end = text.lastIndex(of: "]"), start < end else { return [] }
        nonisolated struct Point: Decodable {
            let point: [Double]
            let label: String?
        }
        guard let points = try? JSONDecoder().decode([Point].self, from: Data(text[start...end].utf8)) else { return [] }
        return points.compactMap { item in
            guard item.point.count == 2 else { return nil }
            return FoundThing(label: item.label ?? "", x: min(max(item.point[1] / 1000, 0), 1), y: min(max(item.point[0] / 1000, 0), 1))
        }
    }

    /// Server-sent events → text chunks → whole sentences that pass the safety filter.
    private nonisolated static func sentences(from bytes: URLSession.AsyncBytes) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                var splitter = SentenceSplitter()
                do {
                    for try await line in bytes.lines where line.hasPrefix("data:") {
                        guard let reply = try? JSONDecoder().decode(GeminiReply.self, from: Data(line.dropFirst(5).utf8)) else { continue }
                        for sentence in splitter.add(reply.text) where SafetyFilter.allows(sentence) {
                            continuation.yield(sentence)
                        }
                    }
                    if let rest = splitter.finish(), SafetyFilter.allows(rest) {
                        continuation.yield(rest)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: Failure.offline)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Prompts

    /// What the user asked the AI to concentrate on.
    static func task(for focus: DescribeFocus, instruction: String) -> String {
        switch focus {
        case .path:
            return "tell them what is in or near their path: obstacles, steps, stairs, curbs, holes, doors, moving vehicles, then one useful landmark."
        case .place:
            return "describe the place: what kind of place it is, its layout, and notable landmarks; mention obstacles only if they're in the way."
        case .text:
            return "read the signs, labels, and other text you can see, saying where each is. If there is none, say so briefly."
        case .people:
            return "describe the people: how many, where they are, and what they're doing. Never identify anyone or guess their identity, age, or ethnicity."
        case .custom:
            let request = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
            return request.isEmpty
                ? "tell them what is in front of them, most important first."
                : "do what they asked about this photo: \"\(request)\"."
        }
    }

    private static func prompt(for style: Style) -> String {
        let rules = """
        Reply in English, as plain speech: no lists, no preamble, never mention the photo, camera, or sensors. \
        Never say the way is clear or safe, and never say it is safe to walk or cross: only the person can judge that.
        """
        switch style {
        case .describe(let measured, let units, let focus, let instruction, let detailed):
            let sensorNote = measured.isEmpty ? "" : """
             The phone's sensors measured these; use exactly these directions and distances \
            for them and don't contradict them: \(measured.joined(separator: "; ")).
            """
            let length = detailed ? "In up to five sentences" : "In at most two short sentences"
            return """
            You are the eyes of a blind person. This photo is from a phone worn on their chest, facing the way \
            they are walking. \(length), \(task(for: focus, instruction: instruction)) \
            Only say what matters to them right now; skip anything obvious or unimportant. \
            \(SpokenPosition.vocabularyRule(units: units))\(sensorNote) \(rules)
            """
        case .answer(let question, let measured, let places, let units, let deep):
            let sensorNote = measured.isEmpty ? "" : " The phone's sensors measured: \(measured.joined(separator: "; "))."
            let placeNote = places.isEmpty ? "" : " Nearby places from the map: \(places.joined(separator: "; "))."
            let care = deep ? " Look carefully at every detail before answering." : ""
            return """
            You are the eyes of a blind person. This photo is from a phone worn on their chest, facing the way \
            they are facing. They asked: "\(question)".\(care) Answer that directly first, in at most three short \
            sentences, using the photo, the measurements, and the nearby places. If you can't tell from these, say \
            so briefly and suggest what they could do, like turning a little left or right. \
            \(SpokenPosition.vocabularyRule(units: units))\(sensorNote)\(placeNote) \(rules)
            """
        case .readText:
            return """
            Read out all the text in this photo, in reading order, exactly as written, for a blind person. \
            If it's a menu, sign, or label, say what kind first in a few words. If there's no readable text, \
            say: I can't see any text. \(rules)
            """
        case .calm(let previous):
            let avoid = previous.map { " Your last remark was: \"\($0)\". Say something different." } ?? ""
            return """
            You are a calm, warm walking companion for a blind person. This photo is from a phone on their chest. \
            In one or two short sentences, under 35 words, gently describe the surroundings: the atmosphere, \
            the light, what people are doing, anything pleasant. Light, kind humor is welcome when it fits. \
            Do not give directions or safety warnings.\(avoid) \(rules)
            """
        }
    }
}
