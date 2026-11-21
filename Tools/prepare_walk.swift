// Prepares a SightSense walk recording for review in the cloud (used by Tools/review_walk.py):
//   xcrun swift Tools/prepare_walk.swift <recording folder> <output folder>
//
// - Blurs every face first: footage of other people never leaves the Mac unblurred.
// - walk.mp4: the whole walk at its real timing, for agentic video understanding.
// - upload/: the walk's logs plus a few frames (one every half second, and every frame within a
//   second of each thing the app said), for the Managed Agent to look at.
// Apple frameworks only (AVFoundation, Core Image, Vision).
import AVFoundation
import CoreImage
import Foundation
import Vision

struct FrameRecord: Decodable { let index: Int; let time: Double }
struct EventRecord: Decodable { let time: Double }

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func lines<T: Decodable>(_ url: URL, as type: T.Type) -> [T] {
    guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
    return text.split(separator: "\n").compactMap { try? JSONDecoder().decode(T.self, from: Data($0.utf8)) }
}

let arguments = CommandLine.arguments
guard arguments.count == 3 else { fail("usage: xcrun swift Tools/prepare_walk.swift <recording folder> <output folder>") }
let recording = URL(fileURLWithPath: arguments[1])
let output = URL(fileURLWithPath: arguments[2])
let uploadFrames = output.appending(path: "upload/frames")
try FileManager.default.createDirectory(at: uploadFrames, withIntermediateDirectories: true)

let frames = lines(recording.appending(path: "frames.jsonl"), as: FrameRecord.self).sorted { $0.time < $1.time }
let events = lines(recording.appending(path: "events.jsonl"), as: EventRecord.self)
guard let first = frames.first else { fail("No frames.jsonl in \(recording.path)") }

// Frames to show the agent: one every 0.5 s, plus everything within 1 s of an announcement.
var chosen = Set<Int>()
var nextKeyframe = first.time
for frame in frames {
    if frame.time >= nextKeyframe { chosen.insert(frame.index); nextKeyframe = frame.time + 0.5 }
    if events.contains(where: { abs($0.time - frame.time) <= 1 }) { chosen.insert(frame.index) }
}

let context = CIContext()

/// The frame with every face pixelated.
func blurred(_ image: CIImage) -> CIImage {
    let request = VNDetectFaceRectanglesRequest()
    try? VNImageRequestHandler(ciImage: image).perform([request])
    var result = image
    for face in request.results ?? [] {
        let box = VNImageRectForNormalizedRect(face.boundingBox, Int(image.extent.width), Int(image.extent.height))
            .insetBy(dx: -0.15 * face.boundingBox.width * image.extent.width, dy: -0.15 * face.boundingBox.height * image.extent.height)
        let pixelated = image.applyingFilter("CIPixellate", parameters: [kCIInputScaleKey: max(box.width / 8, 8)]).cropped(to: box)
        result = pixelated.composited(over: result)
    }
    return result.cropped(to: image.extent)
}

// The video, at the size of the first frame (even dimensions for H.264).
guard let firstImage = CIImage(contentsOf: recording.appending(path: String(format: "frames/%06d.jpg", first.index))) else {
    fail("Can't read the first frame")
}
let width = Int(firstImage.extent.width) & ~1
let height = Int(firstImage.extent.height) & ~1
let videoURL = output.appending(path: "walk.mp4")
try? FileManager.default.removeItem(at: videoURL)
let writer = try AVAssetWriter(outputURL: videoURL, fileType: .mp4)
let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
    AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
])
input.expectsMediaDataInRealTime = false
let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: width,
    kCVPixelBufferHeightKey as String: height,
])
writer.add(input)
writer.startWriting()
writer.startSession(atSourceTime: .zero)

var written = 0
var lastTime = -1.0
for frame in frames {
    let name = String(format: "%06d.jpg", frame.index)
    guard let image = CIImage(contentsOf: recording.appending(path: "frames/\(name)")) else { continue }
    let safe = blurred(image)
    if chosen.contains(frame.index), let jpeg = context.jpegRepresentation(of: safe, colorSpace: CGColorSpaceCreateDeviceRGB()) {
        try jpeg.write(to: uploadFrames.appending(path: name))
    }
    let seconds = frame.time - first.time
    guard seconds > lastTime else { continue }  // timestamps must keep increasing
    while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.005) }
    var buffer: CVPixelBuffer?
    guard let pool = adaptor.pixelBufferPool, CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess,
          let buffer else { continue }
    context.render(safe.cropped(to: CGRect(x: 0, y: 0, width: width, height: height)), to: buffer)
    adaptor.append(buffer, withPresentationTime: CMTime(seconds: seconds, preferredTimescale: 600))
    lastTime = seconds
    written += 1
}
input.markAsFinished()
await writer.finishWriting()
guard writer.status == .completed else { fail("Video failed: \(writer.error?.localizedDescription ?? "unknown")") }

for log in ["frames.jsonl", "events.jsonl"] {
    let source = recording.appending(path: log)
    let target = output.appending(path: "upload/\(log)")
    try? FileManager.default.removeItem(at: target)
    if FileManager.default.fileExists(atPath: source.path) { try FileManager.default.copyItem(at: source, to: target) }
}
print("Prepared \(written) frames → walk.mp4 (\(String(format: "%.0f", lastTime)) s), \(chosen.count) frames for the agent, faces blurred.")
