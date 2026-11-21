import UIKit

/// Buzz patterns, felt through the chest mount even when it's too loud to hear:
/// two strong taps = obstacle, three slow taps = drop-off, three quick taps = approaching.
enum Haptics {
    /// Confirms a tap registered.
    static func tap() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    static func alert(_ kind: Alert.Kind) {
        switch kind {
        case .dropOff: pulse(count: 3, gap: 0.2, style: .heavy)
        case .approaching: pulse(count: 3, gap: 0.08, style: .rigid)
        case .object, .obstacle, .crowd: pulse(count: 2, gap: 0.12, style: .heavy)
        }
    }

    private static func pulse(count: Int, gap: Double, style: UIImpactFeedbackGenerator.FeedbackStyle) {
        let generator = UIImpactFeedbackGenerator(style: style)
        generator.prepare()
        Task {
            for i in 0..<count {
                generator.impactOccurred(intensity: 1)
                if i < count - 1 { try? await Task.sleep(for: .seconds(gap)) }
            }
        }
    }
}
