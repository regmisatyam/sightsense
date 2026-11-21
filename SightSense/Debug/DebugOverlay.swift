#if DEBUG
import SwiftUI

/// Developer readout (Debug builds only), hidden from VoiceOver:
/// - fps, detection and depth time, camera tilt, standing still or walking;
/// - honest latency: end-to-end (first seen → sound) median and 95th percentile;
/// - a camera preview with each object's distance and angle (red = in your path);
/// - what the depth path scanner sees, and the latest alert.
struct DebugOverlay: View {
    let model: AppModel

    private var loop: FastLoop { model.fastLoop }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(String(format: "%.0ffps det %.0fms depth %.0fms tilt %@ %@",
                        model.stats.fps, loop.detectMs, loop.depthMs,
                        loop.tiltDegrees.map { String(format: "%.0f°", $0) } ?? "–",
                        loop.isStationary ? "still" : "walking"))
            Text(latencyLine)
            Text("\(sourceText) · \(depthText)\(model.recorder.isRecording ? " · ● REC" : "")")
            Text("announce: \(model.settings.announcementLevel.rawValue) · filtered as noise: \(loop.filteredCount)")
            HStack(alignment: .top) {
                preview
                Button("Test\nalert", action: model.speechSelfTest)
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
            }
        }
        .font(.caption2.monospaced())
        .foregroundStyle(.green)
        .padding(6)
        .background(.black.opacity(0.75), in: .rect(cornerRadius: 8))
        .accessibilityHidden(true)
    }

    private var latencyLine: String {
        let last = loop.latency.lastPipelineMs.map { String(format: "%.0f", $0) } ?? "–"
        guard let p = loop.latency.endToEndPercentiles else { return "alert ms: frame→sound \(last)" }
        return String(format: "alert ms: frame→sound %@ · first seen→sound p50 %.0f p95 %.0f", last, p.p50, p.p95)
    }

    private var sourceText: String {
        switch loop.detectorSource {
        case .loading: "detector loading"
        case .model: "YOLO \(loop.hazards.count) obj"
        case .builtIn: "built-in \(loop.hazards.count) obj"
        }
    }

    private var depthText: String {
        switch loop.depthStatus {
        case .loading: return "depth loading"
        case .missing: return "no depth model"
        case .uncertain: return "depth: no floor fit"
        case .working:
            let obstacle = loop.path.obstacle.map { String(format: "path %.1fm", $0.meters) } ?? "path clear"
            let drop = loop.path.dropOff.map { String(format: " drop %.1fm", $0.meters) } ?? ""
            return obstacle + drop
        }
    }

    private var preview: some View {
        ZStack {
            if let image = model.preview {
                Image(decorative: image, scale: 1).resizable()
            } else {
                Color.gray.opacity(0.3)
            }
            GeometryReader { geo in
                ForEach(loop.hazards, id: \.object.id) { hazard in
                    let b = hazard.object.box
                    let box = CGRect(x: b.minX * geo.size.width, y: b.minY * geo.size.height,
                                     width: b.width * geo.size.width, height: b.height * geo.size.height)
                    Rectangle()
                        .stroke(hazard.location.isInPath ? .red : .yellow, lineWidth: 2)
                        .frame(width: box.width, height: box.height)
                        .position(x: box.midX, y: box.midY)
                    Text(String(format: "%@ %.1fm %+.0f°", hazard.object.label, hazard.location.meters, hazard.location.bearingDegrees))
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                        .background(.black.opacity(0.6))
                        .fixedSize()
                        .position(x: box.midX, y: max(box.minY - 6, 6))
                }
            }
        }
        .frame(width: 150, height: 200)
    }
}
#endif
