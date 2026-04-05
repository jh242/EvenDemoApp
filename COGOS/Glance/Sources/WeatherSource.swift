import Foundation

struct WeatherSource: GlanceSource {
    let name = "weather"
    var enabled = true
    var cacheDuration: TimeInterval = 900

    let settings: Settings
    let location: NativeLocation

    func fetch() async -> String? {
        let apiKey = await MainActor.run { settings.resolvedOpenweatherKey }
        guard !apiKey.isEmpty else { return nil }

        var loc = location.lastKnownLocation()
        if loc == nil { loc = await location.requestLocation() }
        guard let loc = loc else { return nil }

        let lat = loc.coordinate.latitude
        let lon = loc.coordinate.longitude
        guard let url = URL(string: "https://api.openweathermap.org/data/2.5/weather?lat=\(lat)&lon=\(lon)&appid=\(apiKey)&units=imperial") else { return nil }

        var req = URLRequest(url: url)
        req.timeoutInterval = 5
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }

        let temp = ((obj["main"] as? [String: Any])?["temp"] as? NSNumber)?.intValue
        let weather = (obj["weather"] as? [[String: Any]])?.first
        let condition = (weather?["main"] as? String) ?? ""
        let tempStr = temp.map(String.init) ?? "?"
        return "Weather: \(tempStr)F \(condition)"
    }
}
