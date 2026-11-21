import Testing
@testable import SightSense

@Suite("Depth path scanner: obstacles and drop-offs without names")
struct PathScannerTests {
    struct Lens: Sendable, CustomTestStringConvertible {
        let fov: Double, pitch: Double
        var testDescription: String { "\(Int(fov))° lens, tilted \(Int(pitch))°" }
    }

    nonisolated static let lenses = [Lens(fov: 69, pitch: 5), Lens(fov: 100, pitch: 8), Lens(fov: 100, pitch: 0)]

    @Test(arguments: lenses) func emptyFloorIsClear(_ lens: Lens) {
        let camera = TestScenes.camera(fovDegrees: lens.fov, pitchDegrees: lens.pitch)
        var scanner = PathScanner()
        let scan = scanner.scan(TestScenes.depth(camera: camera), camera: camera, now: 0)
        #expect(scan.reliable)
        #expect(scan.obstacle == nil)
        #expect(scan.dropOff == nil)
    }

    @Test(arguments: lenses) func poleInThePath(_ lens: Lens) throws {
        let camera = TestScenes.camera(fovDegrees: lens.fov, pitchDegrees: lens.pitch)
        var scanner = PathScanner()
        let pole = TestScenes.Block(forward: 2, sideways: 0.1, width: 0.15, height: 2.0)
        let scan = scanner.scan(TestScenes.depth(camera: camera, block: pole), camera: camera, now: 0)
        let obstacle = try #require(scan.obstacle)
        #expect(abs(obstacle.meters - 2) < 0.3, "found at \(obstacle.meters) m")
    }

    @Test(arguments: lenses) func boxBesideThePathIsIgnored(_ lens: Lens) {
        let camera = TestScenes.camera(fovDegrees: lens.fov, pitchDegrees: lens.pitch)
        var scanner = PathScanner()
        let bin = TestScenes.Block(forward: 2.5, sideways: 1.3, width: 0.5, height: 1.0)
        #expect(scanner.scan(TestScenes.depth(camera: camera, block: bin), camera: camera, now: 0).obstacle == nil)
    }

    @Test(arguments: lenses) func stairsGoingDown(_ lens: Lens) throws {
        let camera = TestScenes.camera(fovDegrees: lens.fov, pitchDegrees: lens.pitch)
        var scanner = PathScanner()
        let scan = scanner.scan(TestScenes.depth(camera: camera, dropAt: 3), camera: camera, now: 0)
        let drop = try #require(scan.dropOff)
        #expect(abs(drop.meters - 3) < 0.6, "edge at \(drop.meters) m")
        #expect(scan.obstacle == nil)
    }

    /// The wide lens sees the floor about 1 m ahead, so even a near drop has real floor to calibrate against.
    @Test(arguments: [0.0, 8.0]) func nearbyDropWithWideLens(pitch: Double) throws {
        let camera = TestScenes.camera(fovDegrees: 100, pitchDegrees: pitch)
        var scanner = PathScanner()
        let scan = scanner.scan(TestScenes.depth(camera: camera, dropAt: 2), camera: camera, now: 0)
        #expect(abs(try #require(scan.dropOff).meters - 2) < 0.3)
        #expect(scan.obstacle == nil)
    }

    @Test func metricDepthNeedsNoCalibration() throws {
        let camera = TestScenes.camera(fovDegrees: 100, pitchDegrees: 8)
        var scanner = PathScanner()
        let wall = TestScenes.Block(forward: 1.2, width: 2, height: 2)
        let scan = scanner.scan(TestScenes.depth(camera: camera, block: wall, kind: .metric), camera: camera, now: 0)
        #expect(abs(try #require(scan.obstacle).meters - 1.2) < 0.2)
    }

    @Test func unknownTiltIsUnreliable() {
        let camera = TestScenes.camera(pitchDegrees: nil)
        var scanner = PathScanner()
        #expect(!scanner.scan(TestScenes.depth(camera: TestScenes.camera()), camera: camera, now: 0).reliable)
    }

    @Test func respectsChestHeight() throws {
        // Scene rendered for a 1.3 m camera; telling the scanner 1.5 m should scale distances up ~15%.
        let camera = TestScenes.camera(fovDegrees: 100, pitchDegrees: 8)
        var scanner = PathScanner()
        scanner.cameraHeight = 1.5
        let scan = scanner.scan(TestScenes.depth(camera: camera, block: .init(forward: 2, width: 1, height: 1.5)), camera: camera, now: 0)
        #expect(try #require(scan.obstacle).meters > 2.1)
    }
}

@Suite("Depth findings must hold up over several scans")
struct PathConfirmerTests {
    let pole = PathScan(obstacle: .init(meters: 2, bearingDegrees: 0), dropOff: nil, reliable: true)
    let clear = PathScan(obstacle: nil, dropOff: nil, reliable: true)

    @Test func needsThreeOfFour() {
        var confirmer = PathConfirmer()
        #expect(confirmer.update(pole, at: 0).obstacle == nil)
        #expect(confirmer.update(clear, at: 0.27).obstacle == nil)
        #expect(confirmer.update(pole, at: 0.53).obstacle == nil)
        let confirmed = confirmer.update(pole, at: 0.8).obstacle
        #expect(confirmed?.meters == 2)
        #expect(confirmed?.firstSeenAt == 0)
    }

    @Test func inconsistentDistancesAreNotTrusted() {
        var confirmer = PathConfirmer()
        for (i, meters) in [1.0, 3.5, 2.0].enumerated() {
            _ = confirmer.update(PathScan(obstacle: .init(meters: meters, bearingDegrees: 0), dropOff: nil, reliable: true), at: Double(i) * 0.27)
        }
        #expect(confirmer.current.obstacle == nil)
    }

    @Test func staleHistoryIsDropped() {
        var confirmer = PathConfirmer()
        for i in 0..<3 { _ = confirmer.update(pole, at: Double(i) * 0.27) }
        #expect(confirmer.current.obstacle != nil)
        #expect(confirmer.update(clear, at: 5).obstacle == nil)
    }
}
