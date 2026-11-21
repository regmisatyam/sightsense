import SwiftUI

/// A named action VoiceOver users reach by swiping up or down on a zone.
struct VoiceAction: Identifiable {
    let name: String
    let action: () -> Void
    var id: String { name }
}

/// What each swipe direction does on the big zones.
struct Swipes {
    let up: () -> Void
    let down: () -> Void
    let left: () -> Void
    let right: () -> Void
}

/// A big full-width band of the screen.
/// Touch: tap = its action (instant), press and hold = stop speaking, swipes = `Swipes`.
/// VoiceOver: with direct touch on, the same gestures work as-is; otherwise double tap = action,
/// two-finger double tap (Magic Tap) = Ask, and the rest are in the Actions rotor.
struct TapZone: View {
    let title: String
    let systemImage: String
    let hint: String
    var value = ""
    let background: Color
    let foreground: Color
    let directTouch: Bool
    let onTap: () -> Void
    let onLongPress: () -> Void
    let swipes: Swipes
    let voiceActions: [VoiceAction]
    let onMagicTap: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 64, weight: .bold))
            Text(title)
                .font(.largeTitle.weight(.heavy))
                .minimumScaleFactor(0.5)
        }
        .foregroundStyle(foreground)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(background)
        .contentShape(.rect)
        .gesture(
            LongPressGesture(minimumDuration: 0.6).onEnded { _ in fire(onLongPress) }
                .exclusively(before: TapGesture().onEnded { fire(onTap) })
        )
        .simultaneousGesture(
            DragGesture(minimumDistance: 40).onEnded { drag in
                let dy = drag.translation.height, dx = drag.translation.width
                if abs(dy) > 80, abs(dy) > 1.5 * abs(dx) {
                    fire(dy < 0 ? swipes.up : swipes.down)
                } else if abs(dx) > 80, abs(dx) > 1.5 * abs(dy) {
                    fire(dx < 0 ? swipes.left : swipes.right)
                }
            }
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(value)
        .accessibilityHint(hint)
        .accessibilityAddTraits(directTouch ? [.isButton, .allowsDirectInteraction] : .isButton)
        .accessibilityAction { onTap() }
        .accessibilityAction(.magicTap) { onMagicTap() }
        .accessibilityActions {
            ForEach(voiceActions) { item in
                Button(item.name, action: item.action)
            }
        }
    }

    private func fire(_ action: () -> Void) {
        Haptics.tap()
        action()
    }
}

/// One of the three big buttons along the bottom edge (corners are easy to find by touch).
struct BarButton: View {
    let title: String
    let caption: String
    let systemImage: String
    let spoken: String
    let hint: String
    let action: () -> Void

    var body: some View {
        Button {
            Haptics.tap()
            action()
        } label: {
            VStack(spacing: 4) {
                Image(systemName: systemImage)
                    .font(.system(size: 28, weight: .bold))
                Text(title)
                    .font(.title3.weight(.heavy))
                    .minimumScaleFactor(0.6)
                Text(caption)
                    .font(.footnote.weight(.semibold))
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(white: 0.14))
            .overlay(Rectangle().stroke(.white.opacity(0.85), lineWidth: 3))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken)
        .accessibilityHint(hint)
        .accessibilityAddTraits(.isButton)
    }
}
