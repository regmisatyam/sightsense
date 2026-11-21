import Testing
@testable import SightSense

@Suite("What gets said, and what is filtered as noise")
struct AlertPlannerTests {
    let none = ConfirmedPath()

    func walking(_ time: Double, heading: Double? = 0) -> AlertContext {
        AlertContext(now: time, isWalking: true, heading: heading)
    }

    func standing(_ time: Double) -> AlertContext {
        AlertContext(now: time, isWalking: false, heading: 0)
    }

    func chair(id: Int = 1, meters: Double, bearing: Double = 0, gap: Double = 0) -> Hazard {
        TestScenes.hazard(id: id, meters: meters, bearing: bearing, gap: gap)
    }

    // MARK: Safety alerts

    @Test func closeObjectInPathIsUrgentWithStop() throws {
        var planner = AlertPlanner()
        let planned = planner.plan(hazards: [chair(meters: 1.0)], path: none, context: walking(0))
        let alert = try #require(planned)
        #expect(alert.urgent)
        #expect(alert.text == "Stop. Chair, ahead, 1 step.")
    }

    @Test func dropOffComesFirst() throws {
        var planner = AlertPlanner()
        let path = ConfirmedPath(obstacle: nil, dropOff: PathFinding(meters: 1.5, bearingDegrees: 0, firstSeenAt: 0))
        let planned = planner.plan(hazards: [chair(meters: 1.0)], path: path, context: walking(0))
        let alert = try #require(planned)
        #expect(alert.kind == .dropOff)
        #expect(alert.text == "Drop ahead, 2 steps.")
    }

    @Test func approachingFastEvenWhenStandingStill() throws {
        var planner = AlertPlanner()
        let bike = TestScenes.hazard(id: 2, label: "bicycle", meters: 4, bearing: 20, gap: 1, score: 0.2, growth: 0.7)
        let planned = planner.plan(hazards: [bike], path: none, context: standing(0))
        let alert = try #require(planned)
        #expect(alert.kind == .approaching)
        #expect(alert.text == "Bicycle approaching, right.")
    }

    // MARK: Context

    @Test func standingStillTheSurroundingsAreNotNews() {
        var planner = AlertPlanner()
        planner.policy.level = .everything
        let things = [chair(meters: 2.5), chair(id: 2, meters: 3, bearing: 20, gap: 1)]
        #expect(planner.plan(hazards: things, path: none, context: standing(0)) == nil)
    }

    @Test func standingNextToSomethingWarnsOnceWithoutStop() {
        var planner = AlertPlanner()
        let table = TestScenes.hazard(id: 1, label: "dining table", meters: 1.0)
        #expect(planner.plan(hazards: [table], path: none, context: standing(0))?.text == "Table, ahead, 1 step.")
        for t in stride(from: 1.0, through: 60, by: 1) {
            #expect(planner.plan(hazards: [table], path: none, context: standing(t)) == nil)
        }
    }

    @Test func essentialSkipsThingsBesideThePath() {
        var essential = AlertPlanner()
        #expect(essential.plan(hazards: [chair(meters: 2.5, bearing: -25, gap: 1)], path: none, context: walking(0)) == nil)
        var balanced = AlertPlanner()
        balanced.policy.level = .balanced
        #expect(balanced.plan(hazards: [chair(meters: 2.5, bearing: -25, gap: 1)], path: none, context: walking(0)) != nil)
    }

    @Test func farThingsInThePathWaitUntilTheyMatter() {
        var planner = AlertPlanner()
        #expect(planner.plan(hazards: [chair(meters: 6)], path: none, context: walking(0)) == nil)
        #expect(planner.plan(hazards: [chair(meters: 4)], path: none, context: walking(1.5)) != nil)
    }

    // MARK: Saying each thing once

    @Test func walkingTowardAChairSaysItOnceThenOnlyWhenUrgent() {
        var planner = AlertPlanner()
        var spoken: [String] = []
        // Walking toward a chair from 4.2 m to 0.6 m, one detection pass every 0.25 s.
        for (step, meters) in stride(from: 4.2, through: 0.6, by: -0.12).enumerated() {
            if let alert = planner.plan(hazards: [chair(meters: meters)], path: none, context: walking(Double(step) * 0.25)) {
                spoken.append(alert.text)
            }
        }
        #expect(spoken.count <= 3, "\(spoken)")
        #expect(spoken.first == "Chair, ahead, 6 steps.")
        #expect(spoken.contains { $0.hasPrefix("Stop.") })
    }

    @Test func detectorFlickerIsNotANewThing() {
        var planner = AlertPlanner()
        #expect(planner.plan(hazards: [chair(id: 1, meters: 3)], path: none, context: walking(0)) != nil)
        // The detector lost it and found it again under a new track number.
        #expect(planner.plan(hazards: [chair(id: 9, meters: 2.8, bearing: 4)], path: none, context: walking(6)) == nil)
        #expect(planner.filtered > 0)
    }

    @Test func turningDoesNotMakeThingsNew() {
        var planner = AlertPlanner()
        #expect(planner.plan(hazards: [chair(id: 1, meters: 3)], path: none, context: walking(0, heading: 0)) != nil)
        // Turned 30° right: the same chair now appears 30° to the left, with a new track number.
        let same = chair(id: 4, meters: 3, bearing: -30, gap: 0.3)
        #expect(planner.plan(hazards: [same], path: none, context: walking(6, heading: 30)) == nil)
    }

    @Test func aDifferentThingIsNew() {
        var planner = AlertPlanner()
        #expect(planner.plan(hazards: [chair(meters: 3)], path: none, context: walking(0)) != nil)
        let bench = TestScenes.hazard(id: 2, label: "bench", meters: 3.5, bearing: 3)
        #expect(planner.plan(hazards: [bench], path: none, context: walking(6))?.text == "Bench, ahead, 5 steps.")
    }

    @Test func nonUrgentAlertsAreSpacedOut() {
        var planner = AlertPlanner()
        #expect(planner.plan(hazards: [chair(meters: 3)], path: none, context: walking(0)) != nil)
        let bench = TestScenes.hazard(id: 2, label: "bench", meters: 3.5, bearing: 3)
        #expect(planner.plan(hazards: [bench], path: none, context: walking(2)) == nil)
        #expect(planner.plan(hazards: [bench], path: none, context: walking(5.5)) != nil)
    }

    // MARK: User control

    @Test func categoriesCanBeTurnedOffButSafetyStays() {
        var planner = AlertPlanner()
        planner.policy.categories.remove(.people)
        let farPerson = TestScenes.hazard(id: 1, label: "person", meters: 3)
        #expect(planner.plan(hazards: [farPerson], path: none, context: walking(0)) == nil)
        let closePerson = TestScenes.hazard(id: 2, label: "person", meters: 1.0)
        #expect(planner.plan(hazards: [closePerson], path: none, context: walking(1))?.urgent == true)
    }

    @Test func unnamedObstaclesCanBeTurnedOff() {
        let path = ConfirmedPath(obstacle: PathFinding(meters: 2.5, bearingDegrees: 0, firstSeenAt: 0), dropOff: nil)
        var on = AlertPlanner()
        #expect(on.plan(hazards: [], path: path, context: walking(0))?.text == "Obstacle ahead, 4 steps.")
        var off = AlertPlanner()
        off.policy.unnamedObstacles = false
        #expect(off.plan(hazards: [], path: path, context: walking(0)) == nil)
    }

    @Test func namedObstacleIsNotRepeatedAsUnnamed() {
        var planner = AlertPlanner()
        let path = ConfirmedPath(obstacle: PathFinding(meters: 2, bearingDegrees: 0, firstSeenAt: 0), dropOff: nil)
        #expect(planner.plan(hazards: [chair(meters: 2.2)], path: path, context: walking(0))?.kind == .object)
        #expect(planner.plan(hazards: [chair(meters: 2.2)], path: path, context: walking(6)) == nil)
    }

    @Test func crowdsAreGroupedWhenAskedFor() throws {
        var planner = AlertPlanner()
        planner.policy.level = .balanced
        let people = (1...4).map { TestScenes.hazard(id: $0, label: "person", meters: 3 + Double($0) * 0.4, gap: 0.8) }
        let planned = planner.plan(hazards: people, path: none, context: walking(0))
        #expect(try #require(planned).text == "4 people ahead.")
        #expect(planner.plan(hazards: people, path: none, context: walking(6)) == nil)
    }

    @Test func fullWording() {
        var planner = AlertPlanner()
        planner.policy.verbosity = .full
        let planned = planner.plan(hazards: [chair(meters: 2.8, bearing: -10, gap: 0.2)], path: none, context: walking(0))
        #expect(planned?.text == "Chair slightly left, about 4 steps away.")
    }
}

@Suite("Calm Mode only speaks when something changed")
struct NarrationGateTests {
    let park = SceneSnapshot(labels: ["bench", "person", "dog"], latitude: 51.5, longitude: -0.12, heading: 90)

    @Test func waitsForTheIntervalAndForAChange() {
        var gate = NarrationGate()
        #expect(gate.shouldNarrate(park, now: 0))
        gate.didNarrate(park, now: 0)
        #expect(!gate.shouldNarrate(park, now: 30))    // too soon
        #expect(!gate.shouldNarrate(park, now: 90))    // nothing changed
        #expect(gate.shouldNarrate(park, now: 301))    // a gentle update after five quiet minutes
    }

    @Test func walkingOnTurningOrNewSurroundingsCountAsChange() {
        var gate = NarrationGate()
        gate.didNarrate(park, now: 0)
        var walkedOn = park
        walkedOn.latitude = 51.5002  // about 22 m north
        #expect(gate.shouldNarrate(walkedOn, now: 61))
        var turned = park
        turned.heading = 150
        #expect(gate.shouldNarrate(turned, now: 61))
        var street = park
        street.labels = ["car", "bus", "person"]
        #expect(gate.shouldNarrate(street, now: 61))
        var similar = park
        similar.labels = ["bench", "person", "dog", "bicycle"]
        #expect(!gate.shouldNarrate(similar, now: 61))
    }
}
