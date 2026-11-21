import AVKit
import SwiftUI

/// Physical controls while the camera runs, so SightSense works with the phone on the chest and
/// the screen facing in:
/// - volume down, the Action button, Camera Control, or an AirPods stem click (iOS 26, H2 AirPods)
///   → Ask: press and speak, or hold while talking;
/// - volume up → Describe.
struct HardwareButtons: ViewModifier {
    let enabled: Bool
    let onAsk: (_ pressed: Bool) -> Void
    let onDescribe: () -> Void

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.onCameraCaptureEvent(isEnabled: enabled, defaultSoundDisabled: true,
                                         primaryAction: ask, secondaryAction: describe)
        } else {
            content.onCameraCaptureEvent(isEnabled: enabled, primaryAction: ask, secondaryAction: describe)
        }
    }

    private func ask(_ event: AVCaptureEvent) {
        switch event.phase {
        case .began: onAsk(true)
        case .ended, .cancelled: onAsk(false)
        @unknown default: break
        }
    }

    private func describe(_ event: AVCaptureEvent) {
        if event.phase == .ended { onDescribe() }
    }
}
