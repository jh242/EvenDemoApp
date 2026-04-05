import Flutter
import CoreLocation

/// Provides location and reverse-geocoding via CoreLocation, exposed to
/// Flutter through a MethodChannel.
class LocationChannel: NSObject, CLLocationManagerDelegate {
    static let shared = LocationChannel()

    private let locationManager = CLLocationManager()
    private var pendingResults: [FlutterResult] = []

    override init() {
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    func register(with messenger: FlutterBinaryMessenger) {
        let channel = FlutterMethodChannel(
            name: "method.location",
            binaryMessenger: messenger
        )

        channel.setMethodCallHandler { [weak self] call, result in
            guard let self = self else { return }

            switch call.method {
            case "getCurrentPosition":
                self.getCurrentPosition(result: result)
            case "getLastKnownPosition":
                self.getLastKnownPosition(result: result)
            case "reverseGeocode":
                if let args = call.arguments as? [String: Any],
                   let lat = args["latitude"] as? Double,
                   let lon = args["longitude"] as? Double {
                    self.reverseGeocode(latitude: lat, longitude: lon, result: result)
                } else {
                    result(FlutterError(code: "INVALID_ARGS", message: "latitude and longitude required", details: nil))
                }
            case "requestPermission":
                self.requestPermission(result: result)
            case "checkPermission":
                self.checkPermission(result: result)
            default:
                result(FlutterMethodNotImplemented)
            }
        }
    }

    // MARK: - Methods

    private func getCurrentPosition(result: @escaping FlutterResult) {
        let status = locationManager.authorizationStatus
        guard status == .authorizedWhenInUse || status == .authorizedAlways else {
            result(FlutterError(code: "PERMISSION_DENIED", message: "Location permission not granted", details: nil))
            return
        }

        pendingResults.append(result)
        locationManager.requestLocation()
    }

    private func getLastKnownPosition(result: @escaping FlutterResult) {
        if let location = locationManager.location {
            result([
                "latitude": location.coordinate.latitude,
                "longitude": location.coordinate.longitude,
            ])
        } else {
            result(nil)
        }
    }

    private func reverseGeocode(latitude: Double, longitude: Double, result: @escaping FlutterResult) {
        let location = CLLocation(latitude: latitude, longitude: longitude)
        let geocoder = CLGeocoder()

        geocoder.reverseGeocodeLocation(location) { placemarks, error in
            guard let placemark = placemarks?.first, error == nil else {
                result(nil)
                return
            }

            var parts: [String] = []
            if let subLocality = placemark.subLocality, !subLocality.isEmpty {
                parts.append(subLocality)
            }
            if let locality = placemark.locality, !locality.isEmpty {
                parts.append(locality)
            }
            if let admin = placemark.administrativeArea, !admin.isEmpty {
                parts.append(admin)
            }

            result([
                "placeName": parts.joined(separator: ", "),
                "locality": placemark.locality ?? "",
                "administrativeArea": placemark.administrativeArea ?? "",
                "subLocality": placemark.subLocality ?? "",
            ])
        }
    }

    private func requestPermission(result: @escaping FlutterResult) {
        locationManager.requestWhenInUseAuthorization()
        result(nil)
    }

    private func checkPermission(result: @escaping FlutterResult) {
        let status = locationManager.authorizationStatus
        switch status {
        case .authorizedWhenInUse, .authorizedAlways:
            result("granted")
        case .denied, .restricted:
            result("denied")
        case .notDetermined:
            result("notDetermined")
        @unknown default:
            result("unknown")
        }
    }

    // MARK: - CLLocationManagerDelegate

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        let value: [String: Double] = [
            "latitude": location.coordinate.latitude,
            "longitude": location.coordinate.longitude,
        ]
        for pending in pendingResults {
            pending(value)
        }
        pendingResults.removeAll()
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        let flutterError = FlutterError(code: "LOCATION_ERROR", message: error.localizedDescription, details: nil)
        for pending in pendingResults {
            pending(flutterError)
        }
        pendingResults.removeAll()
    }
}
