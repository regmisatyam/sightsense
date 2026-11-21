import CoreLocation
import Observation

/// Soundscape-style orientation, alongside the obstacle warnings:
/// "Where am I", "Around me", "Ahead of me", places called out as you walk past them,
/// and an audio beacon that guides you toward a chosen place.
@Observable
final class Explorer {
    private(set) var nearby: [Place] = []
    private(set) var results: [Place] = []
    private(set) var beacon: Place?
    let compass = Compass()

    @ObservationIgnored private let speech: SpeechQueue
    @ObservationIgnored private let settings: Settings
    @ObservationIgnored private let beaconAudio = BeaconAudio()
    @ObservationIgnored private var fetched: (location: CLLocation, time: Date)?
    @ObservationIgnored private var isFetching = false
    @ObservationIgnored private var calledOut: [String: Date] = [:]
    @ObservationIgnored private var lastCalloutAt = Date.distantPast
    @ObservationIgnored private var beaconProgress: (meters: Double, time: Date)?
    @ObservationIgnored private var started = false
    /// Something Find located in the camera: its compass bearing, guided by the beacon for a while.
    @ObservationIgnored private var sightTarget: (label: String, bearing: Double, until: Date)?

    init(speech: SpeechQueue, settings: Settings) {
        self.speech = speech
        self.settings = settings
    }

    func start() {
        guard !started else { return }
        started = true
        compass.onLocation = { [weak self] in self?.moved(to: $0) }
        compass.start()
    }

    /// Called for every camera frame with the direction the camera faces (from magnetic north).
    func update(magneticHeading: Double?) {
        compass.update(magneticHeading: magneticHeading)
        if let target = sightTarget {
            if Date() > target.until {
                sightTarget = nil
                if beacon == nil { beaconAudio.point(nil) }
            } else if let heading = compass.heading {
                beaconAudio.point(HeadingMath.relative(target.bearing, to: heading))
            }
        } else if let beacon {
            beaconAudio.point(compass.location.flatMap { relative(to: beacon, from: $0) })
        }
    }

    /// Guides by sound toward something seen `relativeBearing` degrees from where the camera
    /// faces (from Find), for 45 seconds. Needs the compass, so the sound stays put as you turn.
    @discardableResult
    func guide(toward label: String, relativeBearing: Double) -> Bool {
        guard let heading = compass.heading else { return false }
        sightTarget = (label, HeadingMath.normalized(heading + relativeBearing), Date().addingTimeInterval(45))
        beaconAudio.point(relativeBearing)
        return true
    }

    func stopGuiding() {
        sightTarget = nil
        if beacon == nil { beaconAudio.point(nil) }
    }

    // MARK: Spoken requests (also tools for the AI agent, which gets the text)

    func whereAmI() async { say(await whereAmIText()) }
    func aroundMe() async { say(await aroundMeText()) }
    func aheadOfMe() async { say(await aheadOfMeText()) }

    func whereAmIText() async -> String {
        guard let here = compass.location else { return locationProblem }
        let address = await PlaceFinder.address(latitude: here.coordinate.latitude, longitude: here.coordinate.longitude)
        var parts: [String] = []
        if let street = address?.street {
            let number = address?.number.map { ", near number \($0)" } ?? ""
            let area = address?.area.map { ", in \($0)" } ?? ""
            parts.append("You're on \(street)\(number)\(area).")
        } else if let area = address?.area {
            parts.append("You're in \(area).")
        } else {
            parts.append("I can't find the street name here.")
        }
        if let heading = compass.heading {
            parts.append("Facing \(HeadingMath.compassPoint(heading)).")
        }
        await refreshNearby(here, force: false)
        if let place = sortedByDistance(from: here).first {
            parts.append("Nearest place: \(describe(place, from: here)).")
        }
        return parts.joined(separator: " ")
    }

    /// The nearest place in each direction (ahead, right, behind, left), like Soundscape.
    func aroundMeText() async -> String {
        guard let here = compass.location else { return locationProblem }
        await refreshNearby(here, force: true)
        let candidates = sortedByDistance(from: here).filter { here.distance(from: $0.location) < 200 }
        var picks: [Place] = []
        if compass.heading == nil {
            picks = Array(candidates.prefix(4))
        } else {
            for quadrant in [0.0, 90, 180, -90] {
                if let place = candidates.first(where: { place in
                    !picks.contains(place) && abs(HeadingMath.relative(relative(to: place, from: here) ?? 0, to: quadrant)) <= 45
                }) {
                    picks.append(place)
                }
            }
        }
        return picks.isEmpty ? "No named places found nearby." : picks.map { describe($0, from: here) }.joined(separator: ". ") + "."
    }

    func aheadOfMeText() async -> String {
        guard let here = compass.location else { return locationProblem }
        guard compass.heading != nil else {
            return "I can't tell which way you're facing yet. Keep the phone upright on your chest."
        }
        await refreshNearby(here, force: false)
        let ahead = sortedByDistance(from: here).filter { abs(relative(to: $0, from: here) ?? 180) < 45 }.prefix(4)
        return ahead.isEmpty ? "No named places ahead." : ahead.map { describe($0, from: here) }.joined(separator: ". ") + "."
    }

    func search(_ query: String) async {
        guard let here = compass.location, !query.trimmingCharacters(in: .whitespaces).isEmpty else {
            results = []
            return
        }
        let found = await PlaceFinder.search(query, latitude: here.coordinate.latitude, longitude: here.coordinate.longitude)
        results = found.sorted { here.distance(from: $0.location) < here.distance(from: $1.location) }
    }

    func setBeacon(_ place: Place) {
        beacon = place
        beaconProgress = nil
        guard let here = compass.location else {
            say("Beacon set on \(place.name). Follow the sound.")
            return
        }
        beaconProgress = (here.distance(from: place.location), Date())
        say("Beacon set on \(place.name), \(position(of: place, from: here)). Follow the sound.")
        beaconAudio.point(relative(to: place, from: here))
    }

    func stopBeacon() {
        beacon = nil
        beaconAudio.point(nil)
        say("Beacon off.")
    }

    /// Nearby places in words ("Blue Bottle Coffee, cafe, ahead to your right, about 40 meters"),
    /// so the AI can answer questions like "is there a café near here?".
    func placeSummaries(limit: Int = 6) -> [String] {
        guard let here = compass.location else { return [] }
        return sortedByDistance(from: here).prefix(limit).map { describe($0, from: here) }
    }

    /// "ahead to your right, about 40 meters", for the Places list.
    func position(of place: Place) -> String {
        compass.location.map { position(of: place, from: $0) } ?? ""
    }

    // MARK: Walking updates

    private func moved(to here: CLLocation) {
        Task { await refreshNearby(here, force: false) }
        calloutPassing(here)
        updateBeacon(here)
    }

    /// Mentions a place once as you pass within 25 m (again only after 10 minutes), at most one
    /// place every 30 seconds, and only while walking.
    /// Ambient priority: any hazard alert or answer takes precedence.
    private func calloutPassing(_ here: CLLocation) {
        let now = Date()
        guard settings.placeCallouts, here.speed < 0 || here.speed > 0.3,
              now.timeIntervalSince(lastCalloutAt) > 30 else { return }
        for place in sortedByDistance(from: here) where here.distance(from: place.location) < 25 {
            if let last = calledOut[place.id], now.timeIntervalSince(last) < 600 { continue }
            calledOut[place.id] = now
            lastCalloutAt = now
            speech.say(describe(place, from: here) + ".", priority: .ambient)
            return
        }
    }

    private func updateBeacon(_ here: CLLocation) {
        guard let beacon else { return }
        let meters = here.distance(from: beacon.location)
        if meters < 15 {
            self.beacon = nil
            beaconAudio.point(nil)
            say("Arriving at \(beacon.name). Beacon off.")
            return
        }
        if let last = beaconProgress, abs(meters - last.meters) < 50, Date().timeIntervalSince(last.time) < 90 { return }
        beaconProgress = (meters, Date())
        speech.say("\(beacon.name), \(position(of: beacon, from: here)).", priority: .ambient)
    }

    // MARK: Helpers

    private func refreshNearby(_ here: CLLocation, force: Bool) async {
        guard !isFetching else { return }
        if !force, let fetched, here.distance(from: fetched.location) < 40, Date().timeIntervalSince(fetched.time) < 120 { return }
        isFetching = true
        defer { isFetching = false }
        let places = await PlaceFinder.nearby(latitude: here.coordinate.latitude, longitude: here.coordinate.longitude)
        if !places.isEmpty || force {
            nearby = places
            fetched = (here, Date())
        }
    }

    func sortedByDistance(from here: CLLocation) -> [Place] {
        nearby.sorted { here.distance(from: $0.location) < here.distance(from: $1.location) }
    }

    private func relative(to place: Place, from here: CLLocation) -> Double? {
        guard let heading = compass.heading else { return nil }
        let bearing = HeadingMath.bearing(fromLatitude: here.coordinate.latitude, longitude: here.coordinate.longitude,
                                          toLatitude: place.latitude, longitude: place.longitude)
        return HeadingMath.relative(bearing, to: heading)
    }

    /// "Blue Bottle Coffee, cafe, ahead to your right, about 40 meters"
    private func describe(_ place: Place, from here: CLLocation) -> String {
        var parts = [place.name]
        if let category = place.category, !place.name.lowercased().contains(category) { parts.append(category) }
        parts.append(position(of: place, from: here))
        return parts.joined(separator: ", ")
    }

    private func position(of place: Place, from here: CLLocation) -> String {
        let distance = SpokenPosition.placeDistance(here.distance(from: place.location), units: settings.units)
        guard let relative = relative(to: place, from: here) else { return distance }
        return "\(SpokenPosition.placeDirection(relative)), \(distance)"
    }

    /// Why there's no location yet.
    private var locationProblem: String {
        compass.isDenied
            ? "Location access is off. Turn it on in the Settings app, under Privacy, Location Services, SightSense."
            : "Finding your location. Try again in a moment."
    }

    private func say(_ text: String) {
        speech.cancelNonUrgent()
        speech.say(text)
    }
}
