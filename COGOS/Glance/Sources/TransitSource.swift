import Foundation
import MapKit

struct TransitSource: GlanceSource {
    let name = "transit"
    var enabled = true
    var cacheDuration: TimeInterval = 120

    func fetch() async -> String? {
        guard CLLocationManager.locationServicesEnabled() else { return nil }
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = "transit station"
        request.resultTypes = .pointOfInterest
        return await withCheckedContinuation { cont in
            MKLocalSearch(request: request).start { response, error in
                guard let resp = response, error == nil else { cont.resume(returning: nil); return }
                let names = resp.mapItems.prefix(3).map { $0.name ?? "Unknown" }
                cont.resume(returning: names.isEmpty ? nil : "Transit: \(names.joined(separator: ", "))")
            }
        }
    }
}
