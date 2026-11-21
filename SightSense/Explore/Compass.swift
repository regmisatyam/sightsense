import CoreLocation
import Observation

/// Where the wearer is and which way they face.
/// - Location: Core Location (when in use).
/// - Facing: comes from the camera frames' motion data (the direction the chest-mounted camera
///   points), converted from magnetic to true north with Core Location's local declination.
@Observable
final class Compass: NSObject {
    private(set) var location: CLLocation?
    private(set) var authorization: CLAuthorizationStatus = .notDetermined
    /// Degrees clockwise from true north that the wearer faces, if known.
    private(set) var heading: Double?

    @ObservationIgnored var onLocation: ((CLLocation) -> Void)?
    @ObservationIgnored private let manager = CLLocationManager()
    @ObservationIgnored private var declination = 0.0

    var isDenied: Bool { authorization == .denied || authorization == .restricted }

    func start() {
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = 3
        manager.headingFilter = 1
        authorization = manager.authorizationStatus
        manager.requestWhenInUseAuthorization()
        manager.startUpdatingLocation()
        manager.startUpdatingHeading()  // only used for the local magnetic declination
    }

    /// Facing from a camera frame, in degrees from magnetic north.
    func update(magneticHeading: Double?) {
        heading = magneticHeading.map { HeadingMath.normalized($0 + declination) }
    }

    private func received(_ location: CLLocation) {
        self.location = location
        onLocation?(location)
    }
}

extension Compass: CLLocationManagerDelegate {
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let last = locations.last, last.horizontalAccuracy >= 0, last.horizontalAccuracy < 50 else { return }
        let location = CLLocation(coordinate: last.coordinate, altitude: last.altitude,
                                  horizontalAccuracy: last.horizontalAccuracy, verticalAccuracy: last.verticalAccuracy,
                                  course: last.course, speed: last.speed, timestamp: last.timestamp)
        Task { @MainActor in self.received(location) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateHeading heading: CLHeading) {
        guard heading.trueHeading >= 0 else { return }
        var difference = heading.trueHeading - heading.magneticHeading
        if difference > 180 { difference -= 360 }
        if difference < -180 { difference += 360 }
        let declination = difference
        Task { @MainActor in self.declination = declination }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in self.authorization = status }
    }
}
