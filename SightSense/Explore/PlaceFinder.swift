import CoreLocation
import MapKit

/// A named place nearby.
nonisolated struct Place: Sendable, Identifiable, Hashable {
    let id: String
    let name: String
    let category: String?
    let latitude: Double
    let longitude: Double

    var location: CLLocation { CLLocation(latitude: latitude, longitude: longitude) }
}

/// Street address of a spot.
nonisolated struct StreetAddress: Sendable {
    let street: String?
    let number: String?
    let area: String?
}

/// Looks up places and addresses with Apple Maps (MapKit): no extra keys, accounts, or packages.
/// Queries go to Apple's servers, so they need a network; everything else in SightSense works without.
nonisolated enum PlaceFinder {
    /// Points of interest within `radius` meters.
    @concurrent static func nearby(latitude: Double, longitude: Double, radius: Double = 200) async -> [Place] {
        let center = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        let request = MKLocalPointsOfInterestRequest(center: center, radius: radius)
        guard let response = try? await MKLocalSearch(request: request).start() else { return [] }
        return response.mapItems.compactMap(place)
    }

    /// Places matching a spoken or typed search, near the wearer.
    @concurrent static func search(_ query: String, latitude: Double, longitude: Double) async -> [Place] {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        request.region = MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
                                            latitudinalMeters: 3000, longitudinalMeters: 3000)
        guard let response = try? await MKLocalSearch(request: request).start() else { return [] }
        return response.mapItems.compactMap(place)
    }

    @concurrent static func address(latitude: Double, longitude: Double) async -> StreetAddress? {
        let location = CLLocation(latitude: latitude, longitude: longitude)
        guard let placemark = try? await CLGeocoder().reverseGeocodeLocation(location).first else { return nil }
        return StreetAddress(street: placemark.thoroughfare, number: placemark.subThoroughfare,
                             area: placemark.subLocality ?? placemark.locality)
    }

    private static func place(_ item: MKMapItem) -> Place? {
        guard let name = item.name else { return nil }
        let coordinate = item.placemark.coordinate
        return Place(id: "\(name)@\(String(format: "%.5f,%.5f", coordinate.latitude, coordinate.longitude))",
                     name: name, category: item.pointOfInterestCategory.map(readable),
                     latitude: coordinate.latitude, longitude: coordinate.longitude)
    }

    /// "MKPOICategoryPublicTransport" → "public transport".
    private static func readable(_ category: MKPointOfInterestCategory) -> String {
        let raw = category.rawValue.replacingOccurrences(of: "MKPOICategory", with: "")
        return raw.reduce(into: "") { text, character in
            if character.isUppercase && !text.isEmpty { text += " " }
            text += character.lowercased()
        }
    }
}
