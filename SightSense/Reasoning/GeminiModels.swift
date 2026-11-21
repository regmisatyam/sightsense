import Foundation

/// Which Gemini model does which job. Each job has a fallback, so if a model is unavailable
/// the next one answers. Override any of them in Config/Secrets.xcconfig (GEMINI_MODEL_FAST, …).
///
/// Chosen by benchmark (Nov 2026) on a corridor scene with a chair in the path and an exit door
/// on the left, two rounds, streaming like the app (time to first words):
/// - Gemini 4 Carbon: always found chair and exit, 3.3–4.5 s → quick looks.
///   (Flash-Lite was faster, 1.2–1.8 s, but missed the exit door 4 times out of 4.)
/// - Gemini 4 Hydrogen: always right, steady ~3.9 s, most practical advice → questions.
/// - Gemini 4 Neon: always right, thinks hardest, 7–21 s → "look carefully".
/// - Robotics-ER 2: fastest accurate pointing, ~2.3 s → Find. (Gemini 4 models point well too.)
/// - Gemini 4 Argon: also accurate, but no better than Carbon here, so unused.
/// The Gemini 4 models are undocumented codenames, so every job falls back to a proven 3.x model.
/// Gemini 4 doesn't support Live (bidirectional streaming with speech), so the agent stays on 3.x.
/// The agent (Live) is also the app's only voice: no separate text-to-speech model.
nonisolated struct GeminiModels: Sendable {
    nonisolated enum Role: String, CaseIterable, Sendable {
        /// Quick looks: Describe, Instant Describe, Calm Mode text. Fastest vision model.
        case fast
        /// Questions, longer descriptions, reading hard text. Better reasoning.
        case smart
        /// "Look carefully…" questions. Strongest reasoning, slowest.
        case deep
        /// Find: points at a named thing in the photo (embodied / spatial reasoning model).
        case spatial
        /// The agent: a continuous spoken conversation that watches through the camera, uses the
        /// app's tools, and speaks everything the app says, in one natural voice.
        case live

        var purpose: String {
            switch self {
            case .fast: "Describe and Calm Mode"
            case .smart: "Questions and reading"
            case .deep: "\"Look carefully\" questions"
            case .spatial: "Find things"
            case .live: "The agent and its voice"
            }
        }
    }

    /// A model to try, and the thinking level to ask it for (nil = model default / not applicable).
    nonisolated struct Choice: Sendable, Equatable {
        let model: String
        let thinking: String?
    }

    let fast: String
    let smart: String
    let deep: String
    let spatial: String
    let live: String

    static let defaults = GeminiModels(
        fast: "gemini-4-carbon",
        smart: "gemini-4-hydrogen",
        deep: "gemini-4-neon",
        spatial: "gemini-robotics-er-2-preview",
        live: "gemini-3.8-live")

    init(fast: String, smart: String, deep: String, spatial: String, live: String = "gemini-3.8-live") {
        self.fast = fast
        self.smart = smart
        self.deep = deep
        self.spatial = spatial
        self.live = live
    }

    /// Reads per-role overrides from Info.plist (set in Config/*.xcconfig); blanks keep the defaults.
    init(info: [String: Any]) {
        func value(_ key: String, _ fallback: String) -> String {
            let text = (info[key] as? String ?? "").trimmingCharacters(in: .whitespaces)
            return text.isEmpty || text.hasPrefix("$(") ? fallback : text
        }
        let d = Self.defaults
        self.init(fast: value("GeminiModelFast", d.fast), smart: value("GeminiModelSmart", d.smart),
                  deep: value("GeminiModelDeep", d.deep), spatial: value("GeminiModelSpatial", d.spatial),
                  live: value("GeminiModelLive", d.live))
    }

    /// Documented 3.x models each job falls back to.
    static let proven = (fast: "gemini-flash-lite-latest", smart: "gemini-flash-latest", deep: "gemini-pro-latest")

    func model(for role: Role) -> String {
        switch role {
        case .fast: fast
        case .smart: smart
        case .deep: deep
        case .spatial: spatial
        case .live: live
        }
    }

    /// Models to try in order for a job, with the thinking level that suits each.
    func chain(for role: Role) -> [Choice] {
        // "minimal" thinking only suits Flash-Lite; Gemini 4 Carbon and Argon reject it (they take "low").
        func pick(_ model: String) -> Choice {
            Choice(model: model, thinking: model.contains("flash-lite") ? "minimal" : "low")
        }
        let list: [Choice] = switch role {
        case .fast: [pick(fast), pick(Self.proven.fast)]
        case .smart: [pick(smart), pick(Self.proven.smart)]
        case .deep: [pick(deep), pick(Self.proven.deep)]
        case .spatial: [pick(spatial), pick("gemini-4-carbon"), pick(Self.proven.smart)]
        case .live: [Choice(model: live, thinking: nil), Choice(model: "gemini-3.1-flash-live-preview", thinking: nil),
                     Choice(model: "gemini-2.5-flash-native-audio-latest", thinking: nil)]
        }
        var seen = Set<String>()
        return list.filter { seen.insert($0.model).inserted }
    }
}
