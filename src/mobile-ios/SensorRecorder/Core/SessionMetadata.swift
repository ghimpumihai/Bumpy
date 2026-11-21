import Foundation

/// `session.json` (spec §3.8). Written at start, rewritten at stop (with stats) and on recovery.
struct SessionMetadata: Codable, Equatable {
    struct Device: Codable, Equatable {
        var model: String
        var name: String
        var iosVersion: String
    }

    // Nested types decode with defaults for every key, so session.json files written by older app
    // versions (without the public-transport fields) still load (list, detail, recovery).

    struct Vehicle: Codable, Equatable {
        var type: String = "car"
        var makeModel: String = ""
        /// Bus/tram line number; `null` for other vehicles (spec §3.8).
        var line: String? = nil
        var notes: String = ""

        init() {}

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            type = try c.decodeIfPresent(String.self, forKey: .type) ?? "car"
            makeModel = try c.decodeIfPresent(String.self, forKey: .makeModel) ?? ""
            line = try c.decodeIfPresent(String.self, forKey: .line)
            notes = try c.decodeIfPresent(String.self, forKey: .notes) ?? ""
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(type, forKey: .type)
            try c.encode(makeModel, forKey: .makeModel)
            try c.encode(line, forKey: .line) // explicit null
            try c.encode(notes, forKey: .notes)
        }

        enum CodingKeys: String, CodingKey { case type, makeModel, line, notes }

        var isPublicTransport: Bool { type == "bus" || type == "tram" }
    }

    struct Mount: Codable, Equatable {
        var location: String = "taped flat on center console"
        var phoneOrientation: String = "screen up, top of phone pointing to vehicle front"
        var rigid: Bool = true
        /// Phone held in the hand (no mount). The backend excludes these from roughness (02 §10).
        var handheld: Bool = false
        var seatOverAxle: Bool = false
        var photoFile: String? = nil

        init() {}

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let d = Mount()
            location = try c.decodeIfPresent(String.self, forKey: .location) ?? d.location
            phoneOrientation = try c.decodeIfPresent(String.self, forKey: .phoneOrientation) ?? d.phoneOrientation
            rigid = try c.decodeIfPresent(Bool.self, forKey: .rigid) ?? d.rigid
            handheld = try c.decodeIfPresent(Bool.self, forKey: .handheld) ?? false
            seatOverAxle = try c.decodeIfPresent(Bool.self, forKey: .seatOverAxle) ?? false
            photoFile = try c.decodeIfPresent(String.self, forKey: .photoFile)
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(location, forKey: .location)
            try c.encode(phoneOrientation, forKey: .phoneOrientation)
            try c.encode(rigid, forKey: .rigid)
            try c.encode(handheld, forKey: .handheld)
            try c.encode(seatOverAxle, forKey: .seatOverAxle)
            try c.encode(photoFile, forKey: .photoFile) // explicit null (spec shows the key)
        }

        enum CodingKeys: String, CodingKey { case location, phoneOrientation, rigid, handheld, seatOverAxle, photoFile }
    }

    struct People: Codable, Equatable {
        static let postures = ["seated", "standing"]

        var operatorSeat: String = "front passenger"
        var raterSeat: String = "rear left"
        /// "seated" | "standing" (spec §3.8)
        var raterPosture: String = "seated"
        var passengerCount: Int = 2
        var raterName: String = ""

        init() {}

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let d = People()
            operatorSeat = try c.decodeIfPresent(String.self, forKey: .operatorSeat) ?? d.operatorSeat
            raterSeat = try c.decodeIfPresent(String.self, forKey: .raterSeat) ?? d.raterSeat
            raterPosture = try c.decodeIfPresent(String.self, forKey: .raterPosture) ?? d.raterPosture
            passengerCount = try c.decodeIfPresent(Int.self, forKey: .passengerCount) ?? d.passengerCount
            raterName = try c.decodeIfPresent(String.self, forKey: .raterName) ?? ""
        }

        enum CodingKeys: String, CodingKey { case operatorSeat, raterSeat, raterPosture, passengerCount, raterName }
    }

    struct Conditions: Codable, Equatable {
        var weather: String = "dry"
        var notes: String = ""

        init() {}

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            weather = try c.decodeIfPresent(String.self, forKey: .weather) ?? "dry"
            notes = try c.decodeIfPresent(String.self, forKey: .notes) ?? ""
        }

        enum CodingKeys: String, CodingKey { case weather, notes }
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
        /// Always 0 since MISC ratings were removed (D47); still written because the committed
        /// Stop-copy fixture (tools/fixtures/session_meta_stop_v1.json.gz) has them.
        var sicknessRatings: Int = 0
        var sicknessMissed: Int = 0
        // `audioFiles` / `audioFilesIncomplete` are no longer written (D48, no audio); stats from
        // older builds still decode (unknown keys are ignored).
        var fileSizes: [String: Int64]
        var totalBytes: Int64
        var writeErrors: Int
        /// Batches queued for live upload (0 when upload was off). Key name kept for compatibility.
        var uploadBatchesCreated: Int
        /// 2 s windows that never entered the upload queue (upload off for part of the trip, a full
        /// disk): the cloud copy has gaps there, so the trip needs the laptop upload (D55). Omitted when
        /// 0, and kept out of the Stop copy (local only, no contract change).
        var uploadWindowsNotQueued: Int? = nil
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
    // `audioEnabled` is no longer written (D48, no audio); older files still decode (key ignored).
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

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sessionId = try c.decode(String.self, forKey: .sessionId)
        appVersion = try c.decodeIfPresent(String.self, forKey: .appVersion) ?? "unknown"
        device = try c.decodeIfPresent(Device.self, forKey: .device) ?? Device(model: "unknown", name: "unknown", iosVersion: "unknown")
        timezone = try c.decodeIfPresent(String.self, forKey: .timezone) ?? "UTC"
        startedAtUtc = try c.decode(String.self, forKey: .startedAtUtc)
        startUptimeSec = try c.decodeIfPresent(Double.self, forKey: .startUptimeSec) ?? 0
        endedAtUtc = try c.decodeIfPresent(String.self, forKey: .endedAtUtc)
        vehicle = try c.decodeIfPresent(Vehicle.self, forKey: .vehicle) ?? Vehicle()
        mount = try c.decodeIfPresent(Mount.self, forKey: .mount) ?? Mount()
        people = try c.decodeIfPresent(People.self, forKey: .people) ?? People()
        conditions = try c.decodeIfPresent(Conditions.self, forKey: .conditions) ?? Conditions()
        requestedRatesHz = try c.decodeIfPresent([String: Double].self, forKey: .requestedRatesHz) ?? Self.requestedRates
        recovered = try c.decodeIfPresent(Bool.self, forKey: .recovered) ?? false
        recoveredAtUtc = try c.decodeIfPresent(String.self, forKey: .recoveredAtUtc)
        syntheticSensors = try c.decodeIfPresent(Bool.self, forKey: .syntheticSensors) ?? false
        folderName = try c.decodeIfPresent(String.self, forKey: .folderName) ?? ""
        deviceId = try c.decodeIfPresent(String.self, forKey: .deviceId) ?? ""
        preflight = try? c.decodeIfPresent(Preflight.self, forKey: .preflight)
        stats = try? c.decodeIfPresent(Stats.self, forKey: .stats)
    }

    init(sessionId: String, appVersion: String, device: Device, timezone: String, startedAtUtc: String,
         startUptimeSec: Double, endedAtUtc: String?, vehicle: Vehicle, mount: Mount, people: People,
         conditions: Conditions, requestedRatesHz: [String: Double], recovered: Bool,
         recoveredAtUtc: String?, syntheticSensors: Bool, folderName: String, deviceId: String,
         preflight: Preflight?, stats: Stats?) {
        self.sessionId = sessionId; self.appVersion = appVersion; self.device = device; self.timezone = timezone
        self.startedAtUtc = startedAtUtc; self.startUptimeSec = startUptimeSec; self.endedAtUtc = endedAtUtc
        self.vehicle = vehicle; self.mount = mount; self.people = people; self.conditions = conditions
        self.requestedRatesHz = requestedRatesHz; self.recovered = recovered
        self.recoveredAtUtc = recoveredAtUtc; self.syntheticSensors = syntheticSensors; self.folderName = folderName
        self.deviceId = deviceId; self.preflight = preflight; self.stats = stats
    }

    static let requestedRates: [String: Double] = [
        "deviceMotion": 100, "accel": 100, "gyro": 100, "mag": 50,
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

    /// The line number only applies to bus/tram (spec §3.8). Called when the vehicle type changes.
    mutating func applyVehicleTypeDefaults() {
        if !vehicle.isPublicTransport { vehicle.line = nil }
    }
}
