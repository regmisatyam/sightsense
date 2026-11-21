import CoreImage
import ImageIO
import Vision

/// Turns frames into images: small JPEGs for the cloud and recordings, CGImages for the debug preview.
nonisolated enum FrameImage {
    private static let context = CIContext()

    /// JPEG whose long side is at most `maxSide` pixels.
    /// - blurFaces: pixelate faces so bystanders can't be identified in anything that leaves the phone.
    static func jpeg(_ frame: Frame, maxSide: CGFloat, quality: CGFloat = 0.6, blurFaces: Bool = false) -> Data? {
        var image = CIImage(cvPixelBuffer: frame.pixelBuffer)
        if blurFaces {
            image = hidingFaces(in: image, of: frame.pixelBuffer)
        }
        let scale = min(1, maxSide / max(image.extent.width, image.extent.height))
        let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return context.jpegRepresentation(
            of: scaled,
            colorSpace: colorSpace,
            options: [CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): quality]
        )
    }

    static func cgImage(_ frame: Frame) -> CGImage? {
        let image = CIImage(cvPixelBuffer: frame.pixelBuffer)
        return context.createCGImage(image, from: image.extent)
    }

    private static func hidingFaces(in image: CIImage, of buffer: CVPixelBuffer) -> CIImage {
        let request = VNDetectFaceRectanglesRequest()
        try? VNImageRequestHandler(cvPixelBuffer: buffer, orientation: .up).perform([request])
        guard let faces = request.results, !faces.isEmpty else { return image }

        let extent = image.extent
        let blocks = image.clampedToExtent()
            .applyingFilter("CIPixellate", parameters: [kCIInputScaleKey: max(extent.width, extent.height) / 25])
            .cropped(to: extent)
        return faces.reduce(image) { result, face in
            // Vision and Core Image both put the origin at the bottom left.
            let rect = VNImageRectForNormalizedRect(face.boundingBox, Int(extent.width), Int(extent.height))
            let padded = rect.insetBy(dx: -rect.width * 0.3, dy: -rect.height * 0.3)
            return blocks.cropped(to: padded).composited(over: result)
        }
    }
}
