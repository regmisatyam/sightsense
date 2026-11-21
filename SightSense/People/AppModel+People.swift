import CoreGraphics
import Foundation

/// Saved people: announcing them, and the agent's "who's here" tool.
extension AppModel {
    /// "Alex is in view, slightly left, 3 steps." after a friendly three-note chime.
    func announceArrival(_ name: String, _ face: FaceMemory.Face) {
        guard let frame = latestFrame else { return }
        fastLoop.audio.play(.friend)
        speech.say("\(name) is in view, \(position(of: face.box, in: frame)).")
    }

    /// Who's around, for the agent: saved people by name with where they are, and how many others.
    func whoIsHere() -> String {
        guard !people.savedNames.isEmpty else {
            return "No one is saved yet. To save someone, they can ask you to remember the person in front of them, with a name."
        }
        guard settings.recognizePeople else { return "Recognizing saved people is turned off in Settings." }
        guard let frame = latestFrame else { return "The camera isn't ready yet." }
        let faces = people.currentFaces
        guard !faces.isEmpty else { return "No faces in view right now." }
        var parts = faces.compactMap { face in face.name.map { "\($0): \(position(of: face.box, in: frame))" } }
        let others = faces.count - parts.count
        if others > 0 { parts.append("\(others) \(others == 1 ? "face" : "faces") not saved") }
        return parts.isEmpty ? "No one saved is in view." : "In view: " + parts.joined(separator: "; ") + "."
    }

    /// "slightly left, 3 steps", from the face's place in the picture and the measured distance there
    /// (or, failing that, the face's size: a face is about 21 cm from brow to chin).
    private func position(of box: CGRect, in frame: Frame) -> String {
        let bearing = atan((box.midX - 0.5) * 2 * tan(frame.camera.horizontalFOV / 2)) * 180 / .pi
        let meters = fastLoop.distance(to: CGPoint(x: box.midX, y: box.midY))
            ?? 0.21 / (max(box.height, 0.01) * 2 * tan(frame.camera.verticalFOV / 2))
        return SpokenPosition.direction(bearing) + ", " + SpokenPosition.distance(meters, units: settings.units)
    }
}
