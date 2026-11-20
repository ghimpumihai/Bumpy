import Foundation

/// `session.json` (spec §3.8). Written at start, rewritten at stop (with stats) and on recovery.
struct SessionMetadata: Codable, Equatable {
    struct Device: Codable, Equatable {
        var model: String
        var name: String
        var iosVersion: String
    }

    struct Vehicle: Codable, Equatable {
        var type: String = "car"
        var makeModel: String = ""
        var notes: String = ""
    }

    struct Mount: Codable, Equatable {
        var location: String = "taped flat on center console"
        var phoneOrientation: String = "screen up, top of phone pointing to vehicle front"
        var rigid: Bool = true
        var photoFile: String? = nil
    }

    struct People: Codable, Equatable {
        var operatorSeat: String = "front passenger"
        var raterSeat: String = "rear left"
        var passengerCount: Int = 2
        var raterName: String = ""
    }

    struct Conditions: Codable, Equatable {
        var weather: String = "dry"
        var notes: String = ""
    }

    struct StreamStats: Codable, Equatable {
        var samples: Int64
        var meanRateHz: Double
        var maxGapSec: Double
        var gapsOver1s: Int
        var droppedEstimate: Int64
        var fileBytes: Int64?
    }

    struct Stats: Codable, Equatable {
        var durationSec: Double
        var streams: [String: StreamStats]
        var labelsCount: Int
        var sicknessRatings: Int
        var sicknessMissed: Int
        var audioFiles: [String]
        var fileSizes: [String: Int64]
        var totalBytes: Int64
        var writeErrors: Int
        var uploadBatchesCreated: Int
    }

    struct PreflightCheckResult: Codable, Equatable {
        var id: String
        var title: String
        var status: String   // pass | fail | warn
        var detail: String
        var required: Bool
    }

    struct Preflight: Codable, Equatable {
        var completedAtUtc: String
        var overridden: Bool
        var checks: [PreflightCheckResult]
        /// Mean raw accelerometer vector during the stillness test (g, device frame). Points "up" (reaction).
        var stillAccelMeanG: [Double]?
        /// Mean CoreMotion gravity vector during the stillness test (g, device frame). Points "down".
        var stillGravityG: [Double]?
        var stillAccelStdG: [Double]?
        var measuredRatesHz: [String: Double]?
    }

    var sessionId: String
    var appVersion: String
    var device: Device
    var timezone: String
    var startedAtUtc: String
    var startUptimeSec: Double
    var endedAtUtc: String?
    var vehicle: Vehicle
    var mount: Mount
    var people: People
    var conditions: Conditions
    var requestedRatesHz: [String: Double]
    var recovered: Bool
    var recoveredAtUtc: String?
    var syntheticSensors: Bool
    var folderName: String
    var deviceId: String
    var preflight: Preflight?
    var stats: Stats?

    // Explicit encoding so that `endedAtUtc` is written as `null` (spec shows it) instead of omitted.
    enum CodingKeys: String, CodingKey {
        case sessionId, appVersion, device, timezone, startedAtUtc, startUptimeSec, endedAtUtc
        case vehicle, mount, people, conditions, requestedRatesHz, recovered, recoveredAtUtc
        case syntheticSensors, folderName, deviceId, preflight, stats
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(sessionId, forKey: .sessionId)
        try c.encode(appVersion, forKey: .appVersion)
        try c.encode(device, forKey: .device)
        try c.encode(timezone, forKey: .timezone)
        try c.encode(startedAtUtc, forKey: .startedAtUtc)
        try c.encode(startUptimeSec, forKey: .startUptimeSec)
        try c.encode(endedAtUtc, forKey: .endedAtUtc) // Optional -> null
        try c.encode(vehicle, forKey: .vehicle)
        try c.encode(mount, forKey: .mount)
        try c.encode(people, forKey: .people)
        try c.encode(conditions, forKey: .conditions)
        try c.encode(requestedRatesHz, forKey: .requestedRatesHz)
        try c.encode(recovered, forKey: .recovered)
        try c.encodeIfPresent(recoveredAtUtc, forKey: .recoveredAtUtc)
        try c.encode(syntheticSensors, forKey: .syntheticSensors)
        try c.encode(folderName, forKey: .folderName)
        try c.encode(deviceId, forKey: .deviceId)
        try c.encodeIfPresent(preflight, forKey: .preflight)
        try c.encode(stats, forKey: .stats) // Optional -> null until the end
    }

    static let requestedRates: [String: Double] = [
        "deviceMotion": 100, "accel": 100, "gyro": 100, "mag": 50, "audioLevel": 10,
    ]

    func jsonData() throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try enc.encode(self)
    }

    static func load(from url: URL) throws -> SessionMetadata {
        try JSONDecoder().decode(SessionMetadata.self, from: Data(contentsOf: url))
    }

    /// Atomic write (temp file + rename) so a crash never leaves a half-written session.json.
    func write(to url: URL) throws {
        try jsonData().write(to: url, options: [.atomic])
    }
}

/// The parts of the metadata the operator fills in on the setup screen.
struct SessionSetup: Equatable {
    var vehicle = SessionMetadata.Vehicle()
    var mount = SessionMetadata.Mount()
    var people = SessionMetadata.People()
    var conditions = SessionMetadata.Conditions()
    var mountPhotoJPEG: Data?
}
