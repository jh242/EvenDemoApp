import Foundation
import CoreLocation

private let maxStationDistance: CLLocationDistance = 3_000  // meters

struct TransitSource: GlanceSource {
    let name = "transit"
    var enabled = true
    var cacheDuration: TimeInterval = 120

    let location: NativeLocation

    func fetch() async -> String? {
        var loc = location.lastKnownLocation()
        if loc == nil { loc = await location.requestLocation() }
        guard let userLoc = loc else { return nil }

        let stations: [WTFTClient.Station]
        do {
            stations = try await WTFTClient.fetchByLocation(
                lat: userLoc.coordinate.latitude,
                lon: userLoc.coordinate.longitude
            )
        } catch {
            return nil
        }

        guard let station = stations.first,
              let lat = station.latitude, let lon = station.longitude
        else { return nil }

        let distMeters = CLLocation(latitude: lat, longitude: lon).distance(from: userLoc)
        guard distMeters <= maxStationDistance else { return nil }

        let miles = distMeters / 1609.344
        let distStr = String(format: "%.1f mi", miles)

        let now = Date()
        var combined: [WTFTClient.Arrival] = station.N
        combined.append(contentsOf: station.S)
        let future = combined.filter { $0.time > now }
        let sorted = future.sorted { $0.time < $1.time }
        let upcoming = Array(sorted.prefix(3))

        if upcoming.isEmpty {
            return "Transit: \(station.name) (\(distStr)) · no arrivals"
        }
        let parts = upcoming.map { arr -> String in
            let mins = max(0, Int(arr.time.timeIntervalSince(now) / 60))
            return "\(arr.route) \(mins)m"
        }
        return "Transit: \(station.name) (\(distStr)) · \(parts.joined(separator: ", "))"
    }
}
