import Foundation

/// Settings for automatic trips and the vehicle type of every trip (D59). UserDefaults.
enum AutoStartSettings {
    static let vehicleTypes = ["car", "bus", "tram"]

    private static let enabledKey = "autoStart.enabled"
    private static let vehicleKey = "trip.vehicleType"
    private static let mountedKey = "autoStart.mounted"

    static var enabled: Bool {
        get { UserDefaults.standard.bool(forKey: enabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    /// car, bus or tram; every trip, manual ones too. The backend's vehicle fit (D45) and the tram
    /// rail-joint labels (D42) depend on it.
    static var vehicleType: String {
        get {
            let v = UserDefaults.standard.string(forKey: vehicleKey) ?? "car"
            return vehicleTypes.contains(v) ? v : "car"
        }
        set { UserDefaults.standard.set(vehicleTypes.contains(newValue) ? newValue : "car", forKey: vehicleKey) }
    }

    /// An auto trip's `mount.rigid`: only firmly mounted trips count for roughness and potholes (D41).
    static var mounted: Bool {
        get { UserDefaults.standard.bool(forKey: mountedKey) }
        set { UserDefaults.standard.set(newValue, forKey: mountedKey) }
    }

    static var vehicle: SessionMetadata.Vehicle {
        var v = SessionMetadata.Vehicle()
        v.type = vehicleType
        return v
    }
}
