import CoreImage
import Foundation
import Vision

/// The people the user chose to save, and recognizing them, all on the phone.
///
/// iOS has no public face-recognition API, so each face becomes a Vision feature print (a
/// 768-number signature) of a tight grayscale crop. Signatures of one person sit closer together
/// than those of different people; several are kept per person, from different moments, and
/// `FaceMatcher` decides. It's good for telling apart a handful of saved people in decent light,
/// not a dedicated face model: similar-looking people can be mixed up, so Settings › People has a
/// strictness choice and the laptop viewer shows every match score.
///
/// Stored only on this phone (excluded from backups), as signatures, never photos.
actor FaceMemory {
    /// A face in a frame, and who it is (if anyone saved).
    nonisolated struct Face: Sendable, Equatable {
        /// Normalized, top-left origin.
        let box: CGRect
        let name: String?
        /// Distance to the closest saved person, and how close counts as them (for tuning).
        let distance: Float?
        let limit: Float?
        /// Big, frontal, and sharp enough to compare.
        let usable: Bool
    }

    /// How one moment of saving someone went.
    nonisolated enum Sample: Sendable, Equatable { case added(Int), noFace, severalFaces, tooFar, turnedAway }

    nonisolated enum Saved: Sendable, Equatable { case new(Int), updated(Int), tooFew }

    private nonisolated struct Person {
        var name: String
        var prints: [VNFeaturePrintObservation]
        var limit: Float
        let saved: Date
    }

    private nonisolated struct Stored: Codable {
        let name: String
        let limit: Float
        let saved: Date
        let prints: Data
    }

    private nonisolated struct Candidate {
        let box: CGRect
        let usable: Bool
        let frontal: Bool
    }

    private var people: [Person]
    private var draft: [VNFeaturePrintObservation] = []
    private var strictness: Float = 1
    private let context = CIContext()
    private let file: URL

    init() {
        file = URL.applicationSupportDirectory.appending(path: "People/people.json")
        people = Self.load(from: file)
    }

    var names: [String] { people.map(\.name) }

    /// 0.85 strict … 1.2 relaxed (Settings › People).
    func setStrictness(_ value: Float) { strictness = value }

    // MARK: - Recognizing

    /// Every face in view, with the saved person it matches, if any.
    func scan(_ frame: Frame) -> [Face] {
        detect(frame).map { candidate in
            guard candidate.usable, !people.isEmpty, let print = featurePrint(of: candidate.box, in: frame) else {
                return Face(box: candidate.box, name: nil, distance: nil, limit: nil, usable: false)
            }
            let distances = people.map { person in person.prints.map { distance(print, $0) }.min() ?? .infinity }
            let decision = FaceMatcher.decide(distances: distances, limits: people.map { $0.limit * strictness })
            return Face(box: candidate.box, name: decision.index.map { people[$0].name },
                        distance: decision.best, limit: decision.limit, usable: true)
        }
    }

    // MARK: - Saving and forgetting

    func beginSaving() { draft = [] }

    /// Adds one view of the face in front (the biggest, if it's clearly the one meant).
    func addSample(from frame: Frame) -> Sample {
        let faces = detect(frame).sorted { $0.box.width * $0.box.height > $1.box.width * $1.box.height }
        guard let main = faces.first else { return .noFace }
        let area = main.box.width * main.box.height
        if faces.count > 1, faces[1].box.width * faces[1].box.height > area * 0.6 { return .severalFaces }
        guard main.box.height >= 0.08 else { return .tooFar }
        guard main.frontal, main.usable else { return .turnedAway }
        guard let print = featurePrint(of: main.box, in: frame) else { return .noFace }
        // Different moments make a better memory than near-copies of one.
        if let nearest = draft.map({ distance(print, $0) }).min(), nearest < 0.08 { return .added(draft.count) }
        draft.append(print)
        return .added(draft.count)
    }

    /// Saves the collected views under `name` (adding to anyone already saved with that name).
    func finishSaving(as name: String) -> Saved {
        defer { draft = [] }
        guard draft.count >= 4 else { return .tooFew }
        var own: [Float] = []
        for i in draft.indices {
            for j in draft.indices where j > i { own.append(distance(draft[i], draft[j])) }
        }
        let limit = FaceMatcher.limit(ownDistances: own)
        if let index = people.firstIndex(where: { $0.name.lowercased() == name.lowercased() }) {
            people[index].prints = Array((people[index].prints + draft).suffix(24))
            people[index].limit = max(people[index].limit, limit)
            save()
            return .updated(draft.count)
        }
        people.append(Person(name: name, prints: draft, limit: limit, saved: .now))
        save()
        return .new(draft.count)
    }

    /// Deletes someone. Returns the name as saved, or nil if no one is saved by that name.
    func forget(_ name: String) -> String? {
        guard let index = people.firstIndex(where: { $0.name.lowercased() == name.lowercased() }) else { return nil }
        let removed = people.remove(at: index).name
        save()
        return removed
    }

    // MARK: - Vision

    private func detect(_ frame: Frame) -> [Candidate] {
        let handler = VNImageRequestHandler(cvPixelBuffer: frame.pixelBuffer, orientation: .up)
        let faces = VNDetectFaceRectanglesRequest()
        try? handler.perform([faces])
        guard let found = faces.results, !found.isEmpty else { return [] }
        let quality = VNDetectFaceCaptureQualityRequest()
        quality.inputFaceObservations = found
        try? handler.perform([quality])
        return (quality.results ?? found).map { face in
            let b = face.boundingBox  // Vision: bottom-left origin
            let frontal = abs(face.yaw?.doubleValue ?? 0) < 0.6  // within about 35°
            let sharp = (face.faceCaptureQuality ?? 0.5) >= 0.2
            return Candidate(box: CGRect(x: b.minX, y: 1 - b.maxY, width: b.width, height: b.height),
                             usable: b.height >= 0.06 && frontal && sharp, frontal: frontal)
        }
    }

    /// The signature of a tight, square, grayscale crop around the face.
    private func featurePrint(of box: CGRect, in frame: Frame) -> VNFeaturePrintObservation? {
        let image = CIImage(cvPixelBuffer: frame.pixelBuffer)
        let extent = image.extent
        let side = max(box.width * extent.width, box.height * extent.height) * 1.15
        let center = CGPoint(x: box.midX * extent.width, y: (1 - box.midY) * extent.height)  // Core Image: bottom-left
        let square = CGRect(x: center.x - side / 2, y: center.y - side / 2, width: side, height: side).intersection(extent)
        guard square.width > 20, square.height > 20 else { return nil }
        let crop = image.cropped(to: square)
            .transformed(by: CGAffineTransform(translationX: -square.minX, y: -square.minY))
            .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0])
            .transformed(by: CGAffineTransform(scaleX: 224 / square.width, y: 224 / square.height))
        guard let picture = context.createCGImage(crop, from: CGRect(x: 0, y: 0, width: 224, height: 224)) else { return nil }
        let request = VNGenerateImageFeaturePrintRequest()
        request.imageCropAndScaleOption = .scaleFill
        try? VNImageRequestHandler(cgImage: picture).perform([request])
        return request.results?.first
    }

    private func distance(_ a: VNFeaturePrintObservation, _ b: VNFeaturePrintObservation) -> Float {
        var value: Float = .infinity
        try? a.computeDistance(&value, to: b)
        return value
    }

    // MARK: - Storage (this phone only)

    private func save() {
        let stored = people.compactMap { person -> Stored? in
            guard let data = try? NSKeyedArchiver.archivedData(withRootObject: person.prints, requiringSecureCoding: true) else { return nil }
            return Stored(name: person.name, limit: person.limit, saved: person.saved, prints: data)
        }
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(stored).write(to: file, options: [.atomic, .completeFileProtection])
            var values = URLResourceValues()
            values.isExcludedFromBackup = true  // face signatures never leave the phone, not even in backups
            var url = file
            try url.setResourceValues(values)
        } catch {
            print("FaceMemory: couldn't save (\(error))")
        }
    }

    private nonisolated static func load(from file: URL) -> [Person] {
        guard let data = try? Data(contentsOf: file),
              let stored = try? JSONDecoder().decode([Stored].self, from: data) else { return [] }
        return stored.compactMap { item in
            guard let prints = try? NSKeyedUnarchiver.unarchivedArrayOfObjects(ofClass: VNFeaturePrintObservation.self, from: item.prints),
                  !prints.isEmpty else { return nil }
            return Person(name: item.name, prints: prints, limit: item.limit, saved: item.saved)
        }
    }
}
