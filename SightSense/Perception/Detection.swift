import CoreGraphics

/// One object seen in one frame. `box` is normalized (0–1) with the origin at the top left.
nonisolated struct Detection: Sendable {
    let label: String
    let confidence: Float
    let box: CGRect
}
