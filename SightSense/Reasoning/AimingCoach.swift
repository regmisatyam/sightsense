import CoreGraphics

/// What to tell someone who can't see the screen about where the text is.
enum AimingHint: Equatable {
    enum Edge { case top, bottom, left, right }

    case noText
    case moveCloser
    case moveBack
    case cutOff(Edge)
    case holdSteady
    case ready

    var phrase: String? {
        switch self {
        case .noText: "No text yet. Move slowly."
        case .moveCloser: "Text is small. Move closer."
        case .moveBack: "Too close. Move back a little."
        case .cutOff(.top): "Text continues above. Tilt up a little."
        case .cutOff(.bottom): "Text continues below. Tilt down a little."
        case .cutOff(.left): "Text continues to the left. Move left a little."
        case .cutOff(.right): "Text continues to the right. Move right a little."
        case .holdSteady: "Hold steady."
        case .ready: nil
        }
    }
}

/// Guides the camera onto text without sight: which edge text runs off, whether it's too
/// small, and when to hold still. Boxes are normalized with the origin at the top left.
enum AimingCoach {
    static func hint(for boxes: [CGRect], steady: Bool) -> AimingHint {
        guard let first = boxes.first else { return .noText }
        let all = boxes.dropFirst().reduce(first) { $0.union($1) }
        let margin: CGFloat = 0.015
        let top = all.minY < margin, bottom = all.maxY > 1 - margin
        let left = all.minX < margin, right = all.maxX > 1 - margin

        if (left && right) || (top && bottom) { return .moveBack }
        if top { return .cutOff(.top) }
        if bottom { return .cutOff(.bottom) }
        if left { return .cutOff(.left) }
        if right { return .cutOff(.right) }

        let heights = boxes.map(\.height).sorted()
        if heights[heights.count / 2] < 0.015 { return .moveCloser }
        return steady ? .ready : .holdSteady
    }
}
