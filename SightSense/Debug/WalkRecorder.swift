import Foundation
import QuartzCore

/// Records walks so the app can be measured and tuned on real footage: every frame as a JPEG
/// with its sensor data, and every alert with its latency. Saved on the device only, under
/// Documents/Recordings/<date>/ (Files app › On My iPhone › SightSense). About 30 MB a minute.
///
/// Replay a walk through the whole app (e.g. in the simulator) with the launch argument
/// `-replay <folder name>`, and summarize one with `Tools/summarize_walk.py`.
final class WalkRecorder {
    private(set) var isRecording = false
    private var folder: URL?
    private var frameIndex = 0
    private var startedAt: CFTimeInterval = 0
    private let queue = DispatchQueue(label: "sightsense.recorder")

    nonisolated static var recordingsFolder: URL {
        URL.documentsDirectory.appending(path: "Recordings", directoryHint: .isDirectory)
    }

    func start() {
        guard !isRecording else { return }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let folder = Self.recordingsFolder.appending(path: formatter.string(from: .now), directoryHint: .isDirectory)
        do {
            try FileManager.default.createDirectory(at: folder.appending(path: "frames"), withIntermediateDirectories: true)
        } catch {
            print("WalkRecorder: \(error)")
            return
        }
        self.folder = folder
        frameIndex = 0
        startedAt = CACurrentMediaTime()
        isRecording = true
    }

    func stop() {
        isRecording = false
        folder = nil
    }

    func record(_ frame: Frame) {
        guard isRecording, let folder else { return }
        let record = FrameRecord(index: frameIndex, time: frame.capturedAt - startedAt, camera: frame.camera,
                                 acceleration: frame.motion?.acceleration, rotation: frame.motion?.rotation,
                                 heading: frame.motion?.heading)
        frameIndex += 1
        queue.async {
            let name = String(format: "frames/%06d.jpg", record.index)
            if let jpeg = FrameImage.jpeg(frame, maxSide: 640, quality: 0.6) {
                try? jpeg.write(to: folder.appending(path: name))
            }
            Self.append(record, to: folder.appending(path: "frames.jsonl"))
        }
    }

    func log(_ alert: Alert, pipelineMs: Double, endToEndMs: Double) {
        guard isRecording, let folder else { return }
        let record = EventRecord(time: CACurrentMediaTime() - startedAt, kind: "\(alert.kind)", urgent: alert.urgent,
                                 text: alert.text, pipelineMs: pipelineMs, endToEndMs: endToEndMs)
        queue.async { Self.append(record, to: folder.appending(path: "events.jsonl")) }
    }

    private nonisolated static func append(_ record: some Encodable, to url: URL) {
        guard var line = try? JSONEncoder().encode(record) else { return }
        line.append(0x0A)
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(line)
            try? handle.close()
        } else {
            try? line.write(to: url)
        }
    }
}

nonisolated struct FrameRecord: Codable, Sendable {
    let index: Int
    let time: Double
    let camera: CameraGeometry
    let acceleration: Double?
    let rotation: Double?
    let heading: Double?
}

nonisolated struct EventRecord: Codable, Sendable {
    let time: Double
    let kind: String
    let urgent: Bool
    let text: String
    let pipelineMs: Double
    let endToEndMs: Double
}
