import Vision

/// On-device OCR with Vision, off the main thread. Works without a network.
actor TextRecognizer {
    /// Where text is, quickly (about 4 times a second), for aiming guidance.
    /// Boxes are normalized with the origin at the top left.
    func locate(_ frame: Frame) -> [CGRect] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .fast
        request.usesLanguageCorrection = false
        let handler = VNImageRequestHandler(cvPixelBuffer: frame.pixelBuffer, orientation: .up)
        try? handler.perform([request])
        return (request.results ?? [])
            .filter { ($0.topCandidates(1).first?.confidence ?? 0) >= 0.3 }
            .map { CGRect(x: $0.boundingBox.minX, y: 1 - $0.boundingBox.maxY,
                          width: $0.boundingBox.width, height: $0.boundingBox.height) }
    }

    /// Recognized lines, top to bottom, at the best accuracy.
    func read(_ frame: Frame) -> [String] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true

        let handler = VNImageRequestHandler(cvPixelBuffer: frame.pixelBuffer, orientation: .up)
        try? handler.perform([request])

        return (request.results ?? [])
            .compactMap { observation -> (text: String, top: CGFloat, left: CGFloat)? in
                guard let best = observation.topCandidates(1).first, best.confidence >= 0.3 else { return nil }
                return (best.string, observation.boundingBox.maxY, observation.boundingBox.minX)
            }
            .sorted { ($0.top, -$0.left) > ($1.top, -$1.left) }  // Vision's y grows upward
            .map(\.text)
    }
}
