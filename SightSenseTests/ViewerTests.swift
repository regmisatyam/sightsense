import CoreGraphics
import Foundation
import Testing
@testable import SightSense

@Suite("Laptop viewer: what's drawn matches what's measured")
struct FloorProjectionTests {
    let camera = TestScenes.camera(fovDegrees: 100, pitchDegrees: 10)

    @Test func layoutOfTheFloor() throws {
        let projection = try #require(FloorProjection(camera: camera, cameraHeight: 1.3))
        let near = try #require(projection.imagePoint(x: 0, z: 1))
        let far = try #require(projection.imagePoint(x: 0, z: 5))
        #expect(abs(near.x - 0.5) < 1e-9)              // straight ahead is the center column
        #expect(far.y < near.y)                        // farther floor is higher in the picture
        #expect(far.y > projection.horizonY)           // but always below the horizon
        #expect(try #require(projection.imagePoint(x: 0.5, z: 2)).x > 0.5)  // right is right
        #expect(projection.imagePoint(x: 0, z: -1) == nil)                   // behind the camera
    }

    @Test func nothingToDrawUntilTheTiltIsKnown() {
        #expect(FloorProjection(camera: TestScenes.camera(pitchDegrees: nil), cameraHeight: 1.3) == nil)
    }

    /// A ring drawn at d meters sits where the path scanner's ray math says the floor is d meters away.
    @Test(arguments: [1.0, 2.0, 3.0, 5.0])
    func ringsMatchThePathScanner(_ meters: Double) throws {
        let projection = try #require(FloorProjection(camera: camera, cameraHeight: 1.3))
        let point = try #require(projection.imagePoint(x: 0, z: meters))
        let pitch = 10 * Double.pi / 180
        let slope = (point.y - 0.5) * 2 * tan(camera.verticalFOV / 2)  // as in PathScanner's Rays
        let depth = 1.3 / (sin(pitch) + slope * cos(pitch))
        let forward = depth * (cos(pitch) - slope * sin(pitch))
        #expect(abs(forward - meters) < 0.001, "\(forward) m")
    }

    /// A person drawn standing d meters ahead is measured d meters away by the distance estimator.
    @Test(arguments: [2.0, 3.0, 4.5])
    func aPersonDrawnAtADistanceIsMeasuredThere(_ meters: Double) throws {
        let projection = try #require(FloorProjection(camera: camera, cameraHeight: 1.3))
        let feet = try #require(projection.imagePoint(x: 0, z: meters))
        let head = try #require(projection.imagePoint(x: 0, z: meters, height: 1.7))
        let halfWidth = 0.25 / (2 * meters * tan(camera.horizontalFOV / 2))
        let box = CGRect(x: 0.5 - halfWidth, y: head.y, width: 2 * halfWidth, height: feet.y - head.y)
        var estimator = DistanceEstimator()
        estimator.cameraHeight = 1.3
        let measured = estimator.locate(label: "person", box: box, camera: camera).meters
        #expect(abs(measured - meters) < 0.1 * meters, "\(measured) m")
    }

    @Test func floorPointsFromDirectionAndDistance() {
        let ahead = FloorProjection.floorPoint(meters: 2, bearingDegrees: 0)
        #expect(abs(ahead.x) < 1e-9 && abs(ahead.z - 2) < 1e-9)
        let right = FloorProjection.floorPoint(meters: 2, bearingDegrees: 90)
        #expect(abs(right.x - 2) < 1e-9 && abs(right.z) < 1e-9)
    }
}

@Suite("Laptop viewer: server and messages")
struct ViewerServerTests {
    @Test func requestPaths() {
        func path(_ request: String) -> String? { ViewerServer.requestPath(Data(request.utf8)) }
        #expect(path("GET /events HTTP/1.1\r\nHost: 192.168.1.23:8080\r\n\r\n") == "/events")
        #expect(path("GET /?refresh=1 HTTP/1.1\r\n\r\n") == "/")
        #expect(path("POST / HTTP/1.1\r\n\r\n") == nil)
        #expect(path("garbage") == nil)
    }

    @Test func snapshotIsOneLineOfJSON() throws {
        let snapshot = ViewerSnapshot(
            time: 1, mode: "Navigate", grid: nil,
            objects: [.init(id: 3, label: "chair", box: [0.4, 0.5, 0.2, 0.3], meters: 2, bearing: 5,
                            x: 0.17, z: 1.99, inPath: true, urgent: false, closing: nil)],
            path: .init(obstacle: nil, drop: nil, clear: true), found: nil,
            status: .init(fps: 15, detectMs: 30, depthMs: 80, detector: "model", depth: "working", walking: true,
                          heading: nil, beeps: "path", level: "essential", filtered: 2, pipelineMs: nil, thermal: "normal"),
            agent: .init(state: "ready", listening: false, speaking: true, working: false, live: false, muted: false,
                         heard: "where's the door\n", said: "Straight ahead.", tools: []),
            spoken: [], models: [], guidance: nil)
        let json = try JSONEncoder().encode(snapshot)
        #expect(!json.contains(UInt8(ascii: "\n")))  // a raw newline would end the event early
        let decoded = try #require(JSONSerialization.jsonObject(with: json) as? [String: Any])
        #expect((decoded["objects"] as? [[String: Any]])?.first?["label"] as? String == "chair")
        #expect(decoded["grid"] == nil)  // left out until the tilt is known
    }

    @Test func modelLogKeepsTheLatestTwelve() {
        let log = ModelLog()
        for i in 0..<20 { log.record(.init(time: Double(i), role: "fast", model: "m", ms: i, status: 200)) }
        #expect(log.recent.count == 12)
        #expect(log.recent.last?.ms == 19)
    }
}
