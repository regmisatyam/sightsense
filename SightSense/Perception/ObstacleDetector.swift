import CoreML
import Vision

/// Finds objects in frames, off the main thread.
/// Uses Models/Detector.mlmodel when present (a YOLO-style model with NMS, e.g. Apple's
/// YOLOv3 Tiny). Without one, falls back to Vision's built-in people and pet detectors,
/// so the hazard loop always works.
actor ObstacleDetector {
    nonisolated enum Source: Sendable {
        case loading
        case model    // Detector.mlmodel: ~80 everyday object classes
        case builtIn  // Vision only: people, dogs, cats
    }

    nonisolated struct Pass: Sendable {
        let detections: [Detection]
        let source: Source
    }

    private var source = Source.loading
    private var modelRequest: VNCoreMLRequest?
    private let humanRequest: VNDetectHumanRectanglesRequest = {
        let request = VNDetectHumanRectanglesRequest()
        request.upperBodyOnly = false
        return request
    }()
    private let animalRequest = VNRecognizeAnimalsRequest()
    private let minConfidence: Float = 0.4

    /// Loads the model Xcode compiled into the app bundle as Detector.mlmodelc, if any.
    func load() -> Source {
        if let url = Bundle.main.url(forResource: "Detector", withExtension: "mlmodelc"),
           let model = try? MLModel(contentsOf: url),
           let visionModel = try? VNCoreMLModel(for: model) {
            let request = VNCoreMLRequest(model: visionModel)
            request.imageCropAndScaleOption = .scaleFill
            modelRequest = request
            source = .model
        } else {
            source = .builtIn
        }
        return source
    }

    func detect(_ frame: Frame) -> Pass {
        let handler = VNImageRequestHandler(cvPixelBuffer: frame.pixelBuffer, orientation: .up)

        if let modelRequest {
            try? handler.perform([modelRequest])
            let results = modelRequest.results ?? []
            let objects = results.compactMap { $0 as? VNRecognizedObjectObservation }
            if objects.isEmpty && !results.isEmpty {
                // Raw tensors instead of boxes: the model was exported without NMS.
                print("ObstacleDetector: Detector.mlmodel has no NMS output; using built-in detection.")
                self.modelRequest = nil
                source = .builtIn
            } else {
                return Pass(detections: objects.compactMap(detection), source: source)
            }
        }

        try? handler.perform([humanRequest, animalRequest])
        let people = (humanRequest.results ?? [])
            .filter { $0.confidence >= minConfidence }
            .map { Detection(label: "person", confidence: $0.confidence, box: Self.topLeft($0.boundingBox)) }
        let pets = (animalRequest.results ?? []).compactMap(detection)
        return Pass(detections: people + pets, source: source)
    }

    private func detection(_ observation: VNRecognizedObjectObservation) -> Detection? {
        guard let top = observation.labels.first, top.confidence >= minConfidence else { return nil }
        return Detection(label: top.identifier.lowercased(), confidence: top.confidence, box: Self.topLeft(observation.boundingBox))
    }

    /// Vision puts the origin at the bottom left; the rest of the app uses top left.
    private static func topLeft(_ b: CGRect) -> CGRect {
        CGRect(x: b.minX, y: 1 - b.maxY, width: b.width, height: b.height)
    }
}
