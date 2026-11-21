import CoreML
import Vision

/// Monocular depth for every pixel from Models/Depth.mlpackage (Apple's Core ML build of
/// Depth Anything V2 Small), off the main thread. Output is relative inverse depth, which
/// `PathScanner` calibrates to meters against the floor.
actor DepthEstimator {
    private var request: VNCoreMLRequest?
    private let step = 4  // keep every 4th pixel each way: plenty for path scanning, and cheap

    /// Loads the model Xcode compiled into the app bundle as Depth.mlmodelc. False if missing.
    func load() -> Bool {
        guard let url = Bundle.main.url(forResource: "Depth", withExtension: "mlmodelc"),
              let model = try? MLModel(contentsOf: url),
              let visionModel = try? VNCoreMLModel(for: model) else { return false }
        let request = VNCoreMLRequest(model: visionModel)
        request.imageCropAndScaleOption = .scaleFill  // whole frame, so pixels map 1:1 by position
        self.request = request
        return true
    }

    func estimate(_ frame: Frame) -> DepthGrid? {
        guard let request else { return nil }
        let handler = VNImageRequestHandler(cvPixelBuffer: frame.pixelBuffer, orientation: .up)
        guard (try? handler.perform([request])) != nil, let result = request.results?.first else { return nil }
        if let observation = result as? VNPixelBufferObservation {
            return grid(from: observation.pixelBuffer)
        }
        if let observation = result as? VNCoreMLFeatureValueObservation,
           let array = observation.featureValue.multiArrayValue {
            return grid(from: array)
        }
        return nil
    }

    private func grid(from buffer: CVPixelBuffer) -> DepthGrid? {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        let read: (UnsafeRawPointer, Int) -> Float
        switch CVPixelBufferGetPixelFormatType(buffer) {
        case kCVPixelFormatType_OneComponent16Half, kCVPixelFormatType_DepthFloat16, kCVPixelFormatType_DisparityFloat16:
            read = { row, x in Float(row.load(fromByteOffset: x * 2, as: Float16.self)) }
        case kCVPixelFormatType_OneComponent32Float, kCVPixelFormatType_DepthFloat32, kCVPixelFormatType_DisparityFloat32:
            read = { row, x in row.load(fromByteOffset: x * 4, as: Float.self) }
        case kCVPixelFormatType_OneComponent8:
            read = { row, x in Float(row.load(fromByteOffset: x, as: UInt8.self)) }
        default:
            return nil
        }
        var values: [Float] = []
        for y in stride(from: 0, to: height, by: step) {
            let row = UnsafeRawPointer(base + y * rowBytes)
            for x in stride(from: 0, to: width, by: step) {
                values.append(read(row, x))
            }
        }
        return DepthGrid(width: (width + step - 1) / step, height: (height + step - 1) / step,
                         values: values, kind: .relativeInverse)
    }

    private func grid(from array: MLMultiArray) -> DepthGrid? {
        let shape = array.shape.map(\.intValue)
        let strides = array.strides.map(\.intValue)
        guard shape.count >= 2 else { return nil }
        let height = shape[shape.count - 2], width = shape[shape.count - 1]
        let rowStride = strides[strides.count - 2], columnStride = strides[strides.count - 1]
        var values: [Float] = []
        for y in stride(from: 0, to: height, by: step) {
            for x in stride(from: 0, to: width, by: step) {
                values.append(array[y * rowStride + x * columnStride].floatValue)
            }
        }
        return DepthGrid(width: (width + step - 1) / step, height: (height + step - 1) / step,
                         values: values, kind: .relativeInverse)
    }
}
