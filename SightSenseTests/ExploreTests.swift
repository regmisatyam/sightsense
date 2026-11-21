import Testing
import simd
@testable import SightSense

@Suite("Compass and map math")
struct HeadingMathTests {
    /// Phone upright on the chest (gravity along -y). Earth's field points north and down.
    /// `facing` is the compass direction the camera points.
    func upright(facing: Double, tiltDegrees: Double = 0) -> (gravity: SIMD3<Double>, field: SIMD3<Double>) {
        // World directions in phone axes (x right, y top, z out of the screen), for a phone whose
        // top leans forward by `tilt`, so the camera (-z) points that much below the horizon.
        let f = facing * .pi / 180, t = tiltDegrees * .pi / 180
        let forward = SIMD3<Double>(0, sin(t), -cos(t))   // horizontal direction the camera faces
        let right = SIMD3<Double>(1, 0, 0)
        let down = SIMD3<Double>(0, -cos(t), -sin(t))
        let north = cos(f) * forward - sin(f) * right    // facing east means north is on the left
        return (down, 30 * north + 40 * down)
    }

    @Test(arguments: [0.0, 45, 90, 180, 270, 315])
    func facingDirection(_ facing: Double) throws {
        let (gravity, field) = upright(facing: facing)
        let heading = try #require(HeadingMath.cameraHeading(gravity: gravity, magneticField: field))
        #expect(abs(HeadingMath.relative(heading, to: facing)) < 0.5, "got \(heading)")
    }

    @Test func tiltedForwardStillWorks() throws {
        let (gravity, field) = upright(facing: 120, tiltDegrees: 20)
        let heading = try #require(HeadingMath.cameraHeading(gravity: gravity, magneticField: field))
        #expect(abs(HeadingMath.relative(heading, to: 120)) < 0.5, "got \(heading)")
    }

    @Test func phoneLyingFlatHasNoHeading() {
        #expect(HeadingMath.cameraHeading(gravity: [0, 0, -1], magneticField: [30, 0, -40]) == nil)
    }

    @Test func bearings() {
        #expect(abs(HeadingMath.bearing(fromLatitude: 0, longitude: 0, toLatitude: 1, longitude: 0) - 0) < 0.01)
        #expect(abs(HeadingMath.bearing(fromLatitude: 0, longitude: 0, toLatitude: 0, longitude: 1) - 90) < 0.01)
        #expect(abs(HeadingMath.bearing(fromLatitude: 0, longitude: 0, toLatitude: -1, longitude: 0) - 180) < 0.01)
        #expect(HeadingMath.relative(350, to: 10) == -20)
        #expect(HeadingMath.relative(10, to: 350) == 20)
        #expect(HeadingMath.compassPoint(44) == "north-east")
        #expect(HeadingMath.compassPoint(359) == "north")
    }

    @Test func placeWords() {
        #expect(SpokenPosition.placeDirection(5) == "ahead")
        #expect(SpokenPosition.placeDirection(-30) == "ahead to your left")
        #expect(SpokenPosition.placeDirection(100) == "to your right")
        #expect(SpokenPosition.placeDirection(-170) == "behind you")
        #expect(SpokenPosition.placeDistance(42) == "about 40 meters")
        #expect(SpokenPosition.placeDistance(347) == "about 350 meters")
        #expect(SpokenPosition.placeDistance(1530) == "about 1.5 kilometers")
        #expect(SpokenPosition.placeDistance(2) == "about 3 steps away")
    }
}
