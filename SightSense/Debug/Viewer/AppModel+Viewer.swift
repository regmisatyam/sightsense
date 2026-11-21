import CoreGraphics
import Foundation
import QuartzCore

/// Gathers what the laptop viewer shows for one camera frame, from across the app.
extension AppModel {
    func viewerSnapshot(for frame: Frame) -> ViewerSnapshot {
        let projection = FloorProjection(camera: frame.camera, cameraHeight: settings.chestHeight)
        func at(_ x: Double, _ z: Double) -> [Double]? {
            projection?.imagePoint(x: x, z: z).map { [Double($0.x), Double($0.y)] }
        }
        func mark(_ finding: PathFinding?) -> ViewerSnapshot.Mark? {
            guard let finding else { return nil }
            let floor = FloorProjection.floorPoint(meters: finding.meters, bearingDegrees: finding.bearingDegrees)
            return .init(meters: finding.meters, bearing: finding.bearingDegrees, x: floor.x, z: floor.z, at: at(floor.x, floor.z))
        }

        let objects = fastLoop.hazards.map { hazard -> ViewerSnapshot.Object in
            let box = hazard.object.box
            let floor = FloorProjection.floorPoint(meters: hazard.location.meters, bearingDegrees: hazard.location.bearingDegrees)
            return .init(id: hazard.object.id, label: hazard.name,
                         box: [box.minX, box.minY, box.width, box.height].map(Double.init),
                         meters: hazard.location.meters, bearing: hazard.location.bearingDegrees,
                         x: floor.x, z: floor.z, inPath: hazard.location.isInPath, urgent: hazard.isUrgent,
                         closing: hazard.closingSpeed)
        }
        let found = lastSighting.flatMap { sighting -> ViewerSnapshot.Found? in
            let age = CACurrentMediaTime() - sighting.time
            guard age < 15 else { return nil }
            return .init(label: sighting.label, at: [sighting.x, sighting.y], meters: sighting.meters,
                         bearing: sighting.bearing, age: age)
        }

        return ViewerSnapshot(
            time: Date().timeIntervalSince1970,
            mode: mode.shortName,
            grid: projection.map(Self.grid),
            objects: objects,
            path: .init(obstacle: mark(fastLoop.path.obstacle), drop: mark(fastLoop.path.dropOff), clear: fastLoop.isPathClear),
            found: found,
            status: .init(
                fps: stats.fps, detectMs: fastLoop.detectMs, depthMs: fastLoop.depthMs,
                detector: "\(fastLoop.detectorSource)", depth: "\(fastLoop.depthStatus)",
                walking: !fastLoop.isStationary, heading: explorer.compass.heading,
                beeps: settings.beepMode.rawValue, level: settings.announcementLevel.rawValue,
                filtered: fastLoop.filteredCount, pipelineMs: fastLoop.latency.lastPipelineMs,
                thermal: Self.thermalName),
            agent: .init(
                state: "\(agent.state)", listening: agent.isListening, speaking: agent.isSpeaking,
                working: agent.isWorking, live: agent.alwaysListening, muted: agent.isMuted,
                heard: agent.heard, said: agent.said, tools: viewer.tools),
            spoken: viewer.spoken,
            models: modelLog.recent,
            guidance: wayFinder.target,
            faces: people.currentFaces.map { face in
                .init(box: [face.box.minX, face.box.minY, face.box.width, face.box.height].map(Double.init),
                      name: face.name, distance: face.distance, limit: face.limit, usable: face.usable)
            })
    }

    /// Distance rings (1, 2, 3, 5 m) and the walking lane (±0.45 m and its center), on the floor.
    private static func grid(_ projection: FloorProjection) -> ViewerSnapshot.Grid {
        func point(_ x: Double, _ z: Double) -> [Double]? {
            guard let p = projection.imagePoint(x: x, z: z), (-1...2).contains(p.x), (-1...2).contains(p.y) else { return nil }
            return [Double(p.x), Double(p.y)]
        }
        let rings = [1.0, 2, 3, 5].map { meters in
            ViewerSnapshot.Ring(
                meters: meters,
                points: stride(from: -70.0, through: 70, by: 5).compactMap { bearing in
                    let floor = FloorProjection.floorPoint(meters: meters, bearingDegrees: bearing)
                    return point(floor.x, floor.z)
                },
                label: point(0, meters))
        }
        let distances = [0.3, 0.5, 0.75, 1, 1.5, 2, 3, 4, 6, 8, 12]
        let lanes = [-0.45, 0, 0.45].map { x in
            ViewerSnapshot.Lane(x: x, points: distances.compactMap { point(x, $0) })
        }
        return .init(pitch: projection.pitch * 180 / .pi, horizon: projection.horizonY, rings: rings, lanes: lanes)
    }

    private static var thermalName: String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: "normal"
        case .fair: "warm"
        case .serious: "hot"
        case .critical: "critical"
        @unknown default: "unknown"
        }
    }
}
