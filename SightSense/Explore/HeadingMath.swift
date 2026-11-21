import Foundation
import simd

/// Compass and map math for orientation features. Pure functions, unit tested.
nonisolated enum HeadingMath {
    /// Which way the back camera faces, in degrees clockwise from magnetic north, from gravity
    /// and the calibrated magnetic field (both in the phone's own axes). With the phone upright
    /// on the chest this is the direction the wearer's body faces. Nil if the phone is too flat
    /// to tell, or the readings are degenerate.
    static func cameraHeading(gravity: SIMD3<Double>, magneticField: SIMD3<Double>) -> Double? {
        guard simd_length(gravity) > 0.1, simd_length(magneticField) > 1e-6 else { return nil }
        let down = simd_normalize(gravity)
        let north = magneticField - simd_dot(magneticField, down) * down   // horizontal part points north
        guard simd_length(north) > 1e-6 else { return nil }
        let east = simd_cross(down, north)
        let camera = SIMD3<Double>(0, 0, -1)                                // back camera looks along -z
        let forward = camera - simd_dot(camera, down) * down
        guard simd_length(forward) > 0.2 else { return nil }               // phone lying flat
        return normalized(atan2(simd_dot(forward, east), simd_dot(forward, north)) * 180 / .pi)
    }

    /// Initial great-circle bearing from one coordinate to another, degrees clockwise from true north.
    static func bearing(fromLatitude lat1: Double, longitude lon1: Double, toLatitude lat2: Double, longitude lon2: Double) -> Double {
        let φ1 = lat1 * .pi / 180, φ2 = lat2 * .pi / 180, Δλ = (lon2 - lon1) * .pi / 180
        let y = sin(Δλ) * cos(φ2)
        let x = cos(φ1) * sin(φ2) - sin(φ1) * cos(φ2) * cos(Δλ)
        return normalized(atan2(y, x) * 180 / .pi)
    }

    /// Angle from the way you face to a bearing: 0 ahead, negative left, positive right, ±180 behind.
    static func relative(_ bearing: Double, to heading: Double) -> Double {
        let angle = normalized(bearing - heading)
        return angle > 180 ? angle - 360 : angle
    }

    static func normalized(_ degrees: Double) -> Double {
        let value = degrees.truncatingRemainder(dividingBy: 360)
        return value < 0 ? value + 360 : value
    }

    /// "north", "north-east", … for a heading in degrees.
    static func compassPoint(_ degrees: Double) -> String {
        let names = ["north", "north-east", "east", "south-east", "south", "south-west", "west", "north-west"]
        return names[Int((normalized(degrees) + 22.5) / 45) % 8]
    }
}
