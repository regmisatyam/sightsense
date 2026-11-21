import CoreImage
import Foundation
import QuartzCore

/// Plays back a recorded walk as if it were the camera, at its recorded timing, so the whole
/// app can be run and tuned on the same footage (e.g. in the simulator).
nonisolated final class ReplayFrameSource: FrameSource, @unchecked Sendable {
    let frames: AsyncStream<Frame>

    private let continuation: AsyncStream<Frame>.Continuation
    private let folder: URL
    private let lock = NSLock()
    private var task: Task<Void, Never>?

    init(folder: URL) {
        self.folder = folder
        (frames, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
    }

    /// The recording named by the launch argument `-replay <folder>`, if any.
    static func fromLaunchArguments() -> ReplayFrameSource? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let flag = arguments.firstIndex(of: "-replay"), flag + 1 < arguments.count else { return nil }
        let name = arguments[flag + 1]
        let folder = name.hasPrefix("/") ? URL(filePath: name) : WalkRecorder.recordingsFolder.appending(path: name)
        return FileManager.default.fileExists(atPath: folder.path) ? ReplayFrameSource(folder: folder) : nil
    }

    func start() {
        let folder = folder, continuation = continuation
        let replay = Task.detached {
            let lines = (try? String(contentsOf: folder.appending(path: "frames.jsonl"), encoding: .utf8))?
                .split(separator: "\n") ?? []
            let context = CIContext()
            var previous: Double?
            for line in lines {
                guard !Task.isCancelled else { break }
                guard let record = try? JSONDecoder().decode(FrameRecord.self, from: Data(line.utf8)) else { continue }
                if let previous { try? await Task.sleep(for: .seconds(max(0, record.time - previous))) }
                previous = record.time
                let url = folder.appending(path: String(format: "frames/%06d.jpg", record.index))
                guard let buffer = Self.pixelBuffer(from: url, context: context) else { continue }
                let motion = record.acceleration.map {
                    MotionSample(acceleration: $0, rotation: record.rotation ?? 0, heading: record.heading)
                }
                continuation.yield(Frame(pixelBuffer: buffer, capturedAt: CACurrentMediaTime(),
                                         camera: record.camera, motion: motion))
            }
            continuation.finish()
        }
        lock.withLock { task = replay }
    }

    func stop() {
        lock.withLock { task?.cancel() }
    }

    private static func pixelBuffer(from url: URL, context: CIContext) -> CVPixelBuffer? {
        guard let image = CIImage(contentsOf: url) else { return nil }
        var buffer: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
        CVPixelBufferCreate(nil, Int(image.extent.width), Int(image.extent.height),
                            kCVPixelFormatType_32BGRA, attributes, &buffer)
        guard let buffer else { return nil }
        context.render(image, to: buffer)
        return buffer
    }
}
