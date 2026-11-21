/// What the app does beyond hazard alerts, which are on in every mode.
enum AppMode: CaseIterable {
    /// Quiet unless something is in the way.
    case navigate
    /// Gentle narration of the surroundings while nothing is near.
    case calm
    /// Hands-free: the agent's microphone stays open, so you can just talk.
    case live

    var spokenName: String {
        switch self {
        case .navigate: "Navigation mode"
        case .calm: "Calm mode"
        case .live: "Live mode"
        }
    }

    var shortName: String {
        switch self {
        case .navigate: "Navigate"
        case .calm: "Calm"
        case .live: "Live"
        }
    }

    /// The Mode button cycles Navigation → Calm → Live.
    var next: AppMode {
        switch self {
        case .navigate: .calm
        case .calm: .live
        case .live: .navigate
        }
    }
}
