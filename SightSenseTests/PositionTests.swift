import CoreGraphics
import Testing
@testable import SightSense

@Suite("Distance and direction from a detector box")
struct DistanceEstimatorTests {
    let estimator = DistanceEstimator()

    struct Case: Sendable, CustomTestStringConvertible {
        let name: String, label: String, height: Double, width: Double, distance: Double, sideways: Double, pitch: Double
        var testDescription: String { name }
    }

    @Test(arguments: [
        Case(name: "person 3 m ahead", label: "person", height: 1.7, width: 0.5, distance: 3, sideways: 0, pitch: 5),
        Case(name: "person 6 m slightly left", label: "person", height: 1.7, width: 0.5, distance: 6, sideways: -0.9, pitch: 5),
        Case(name: "person 1 m, feet out of frame", label: "person", height: 1.7, width: 0.5, distance: 1, sideways: 0.1, pitch: 5),
        Case(name: "chair 0.6 m, base out of frame", label: "chair", height: 0.9, width: 0.5, distance: 0.6, sideways: 0, pitch: 5),
        Case(name: "table 1 m", label: "dining table", height: 0.75, width: 1.2, distance: 1, sideways: 0, pitch: 5),
        Case(name: "person 2 m, phone tilted up", label: "person", height: 1.7, width: 0.5, distance: 2, sideways: 0, pitch: -5),
        Case(name: "person 3 m, phone tilted 15° down", label: "person", height: 1.7, width: 0.5, distance: 3, sideways: 0, pitch: 15),
    ])
    func distanceWithin15Percent(_ c: Case) {
        let camera = TestScenes.camera(pitchDegrees: c.pitch)
        let box = TestScenes.box(height: c.height, width: c.width, distance: c.distance, sideways: c.sideways, camera: camera)
        let location = estimator.locate(label: c.label, box: box, camera: camera)
        #expect(abs(location.meters - c.distance) / c.distance < 0.15, "estimated \(location.meters) m")
        let trueBearing = atan(c.sideways / c.distance) * 180 / .pi
        #expect(abs(location.bearingDegrees - trueBearing) < 3, "bearing \(location.bearingDegrees)°")
    }

    @Test func worksWithoutMotionSensors() {
        let camera = TestScenes.camera(pitchDegrees: nil)
        let box = TestScenes.box(height: 1.7, width: 0.5, distance: 3, camera: TestScenes.camera(pitchDegrees: 0))
        #expect(abs(estimator.locate(label: "person", box: box, camera: camera).meters - 3) < 0.3)
    }

    @Test func pathGap() {
        let camera = TestScenes.camera()
        let ahead = estimator.locate(label: "chair", box: TestScenes.box(height: 0.9, width: 0.5, distance: 2, camera: camera), camera: camera)
        let aside = estimator.locate(label: "chair", box: TestScenes.box(height: 0.9, width: 0.5, distance: 2, sideways: 1.2, camera: camera), camera: camera)
        #expect(ahead.isInPath)
        #expect(!aside.isInPath)
        #expect(abs(aside.pathGap - 0.95) < 0.2)
    }
}

@Suite("Everyday words")
struct SpokenPositionTests {
    @Test func directions() {
        #expect(SpokenPosition.direction(0) == "straight ahead")
        #expect(SpokenPosition.direction(-10) == "slightly left")
        #expect(SpokenPosition.direction(20) == "to your right")
        #expect(SpokenPosition.direction(20, brief: true) == "right")
        #expect(SpokenPosition.direction(-3, brief: true) == "ahead")
    }

    @Test func distances() {
        #expect(SpokenPosition.distance(0.5) == "within arm's reach")
        #expect(SpokenPosition.distance(0.7) == "within arm's reach")
        #expect(SpokenPosition.distance(1.4) == "2 steps away")
        #expect(SpokenPosition.distance(2.8) == "about 4 steps away")
        #expect(SpokenPosition.distance(2.8, brief: true) == "4 steps")
        #expect(SpokenPosition.distance(0.8, brief: true) == "1 step")
        #expect(SpokenPosition.distance(20) == "far away")
        #expect(SpokenPosition.distance(1.46, units: .meters, brief: true) == "1.5 meters")
        #expect(SpokenPosition.distance(4.4, units: .meters) == "about 4 meters away")
    }
}
