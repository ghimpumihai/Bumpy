import Foundation

/// `POST /api/ingest` body (spec §6), schemaVersion 1. Columnar arrays keep payloads small;
/// every `t` array is seconds relative to `t0Up`.
struct IngestBatch: Encodable, Equatable {
    struct DeviceMotion: Encodable, Equatable {
        var t: [Double] = []
        var ua_x: [Double] = [], ua_y: [Double] = [], ua_z: [Double] = []
        var g_x: [Double] = [], g_y: [Double] = [], g_z: [Double] = []
        var rr_x: [Double] = [], rr_y: [Double] = [], rr_z: [Double] = []
        var q_w: [Double] = [], q_x: [Double] = [], q_y: [Double] = [], q_z: [Double] = []
    }

    struct XYZ: Encodable, Equatable {
        var t: [Double] = []
        var x: [Double] = [], y: [Double] = [], z: [Double] = []
    }

    struct Location: Encodable, Equatable {
        var tUtcMs: Int64
        var lat: Double, lon: Double, alt: Double
        var hAcc: Double, speed: Double, speedAcc: Double, course: Double
        /// iOS `sourceInformation.isSimulatedBySoftware`; null when iOS doesn't say.
        var isSimulated: Bool?

        enum CodingKeys: String, CodingKey { case tUtcMs, lat, lon, alt, hAcc, speed, speedAcc, course, isSimulated }
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(tUtcMs, forKey: .tUtcMs)
            try c.encode(lat, forKey: .lat); try c.encode(lon, forKey: .lon); try c.encode(alt, forKey: .alt)
            try c.encode(hAcc, forKey: .hAcc); try c.encode(speed, forKey: .speed)
            try c.encode(speedAcc, forKey: .speedAcc); try c.encode(course, forKey: .course)
            try c.encode(isSimulated, forKey: .isSimulated) // explicit null
        }
    }

    struct Altimeter: Encodable, Equatable {
        var t: [Double] = []
        var relAltM: [Double] = []
        var pressureKpa: [Double] = []
    }

    struct AudioLevel: Encodable, Equatable {
        var t: [Double] = []
        var avgDbfs: [Double] = []
        var peakDbfs: [Double] = []
    }

    struct Label: Encodable, Equatable {
        var t: Double
        var type: String
        var value: String?
        var note: String?

        enum CodingKeys: String, CodingKey { case t, type, value, note }
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(t, forKey: .t)
            try c.encode(type, forKey: .type)
            try c.encode(value, forKey: .value) // explicit null
            try c.encode(note, forKey: .note)
        }
    }

    struct Device: Encodable, Equatable {
        var battery: Double
        var thermal: String
        var lowPower: Bool
    }

    var schemaVersion = 1
    /// Hackathon rule: "JSON payload with device ID, event type, value, unit, and UTC timestamp".
    /// Additive fields (schemaVersion stays 1; the §6 keys are unchanged).
    var eventType = "sensor_batch"
    var source = "live"
    var sessionId: String
    var deviceId: String
    var batchSeq: Int
    var t0Utc: String
    var t0Up: Double
    /// UTC of `t0Up` in ms: sample UTC = t0UtcMs + t[i] × 1000.
    var t0UtcMs: Int64
    var units: [String: String] = ["accel": "g", "gyro": "rad/s", "speed": "m/s", "pressure": "kPa"]
    /// Unit of every field (the §6 `units` map above is kept as-is for compatibility).
    var fieldUnits: [String: String] = IngestBatch.allFieldUnits

    static let allFieldUnits: [String: String] = [
        "t": "s (relative to t0Up)", "t0Up": "s since boot", "t0UtcMs": "ms since Unix epoch (UTC)",
        "deviceMotion.ua": "g", "deviceMotion.g": "g", "deviceMotion.rr": "rad/s", "deviceMotion.q": "unitless quaternion",
        "accelRaw": "g", "gyroRaw": "rad/s",
        "location.tUtcMs": "ms since Unix epoch (UTC)", "location.lat": "deg", "location.lon": "deg",
        "location.alt": "m", "location.hAcc": "m", "location.speed": "m/s (-1 = invalid)",
        "location.speedAcc": "m/s", "location.course": "deg (-1 = invalid)",
        "altimeter.relAltM": "m", "altimeter.pressureKpa": "kPa",
        "audioLevel.avgDbfs": "dBFS", "audioLevel.peakDbfs": "dBFS",
        "device.battery": "fraction 0-1 (-1 = unknown)",
    ]
    var deviceMotion = DeviceMotion()
    var accelRaw = XYZ()
    var gyroRaw = XYZ()
    var location: [Location] = []
    var altimeter = Altimeter()
    var audioLevel = AudioLevel()
    var labels: [Label] = []
    var device: Device

    var sampleCount: Int {
        deviceMotion.t.count + accelRaw.t.count + gyroRaw.t.count + location.count
            + altimeter.t.count + audioLevel.t.count + labels.count
    }

    func jsonData() throws -> Data {
        let enc = JSONEncoder()
        // sortedKeys: deterministic bytes (dictionary order is otherwise unspecified), so a re-sent
        // batch is byte-identical and payloads diff cleanly.
        enc.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]
        return try enc.encode(self)
    }
}

@inline(__always) func round6(_ v: Double) -> Double { v.isFinite ? (v * 1e6).rounded() / 1e6 : 0 }
@inline(__always) func round8(_ v: Double) -> Double { v.isFinite ? (v * 1e8).rounded() / 1e8 : 0 }

/// Collects the samples of the current 2 s window (an in-memory copy; disk files remain the
/// source of truth). Thread-safe: `add*` is called from sensor queues, `drain` from the batch timer.
final class BatchAccumulator: @unchecked Sendable {
    private struct Pending {
        var dm: [DeviceMotionSample] = []
        var accel: [Vec3Sample] = []
        var gyro: [Vec3Sample] = []
        var location: [LocationSample] = []
        var alt: [AltimeterSample] = []
        var audio: [AudioLevelSample] = []
        var labels: [(t: Double, type: String, value: String?, note: String?)] = []
    }

    private let pending = Locked(Pending())
    private let seq = Locked(0)
    let sessionId: String
    let deviceId: String

    init(sessionId: String, deviceId: String) {
        self.sessionId = sessionId
        self.deviceId = deviceId
    }

    func add(_ s: DeviceMotionSample) { pending.withLock { $0.dm.append(s) } }
    func addAccel(_ s: Vec3Sample) { pending.withLock { $0.accel.append(s) } }
    func addGyro(_ s: Vec3Sample) { pending.withLock { $0.gyro.append(s) } }
    func add(_ s: LocationSample) { pending.withLock { $0.location.append(s) } }
    func add(_ s: AltimeterSample) { pending.withLock { $0.alt.append(s) } }
    func add(_ s: AudioLevelSample) { pending.withLock { $0.audio.append(s) } }
    func addLabel(t: Double, type: String, value: String?, note: String?) {
        pending.withLock { $0.labels.append((t, type, value, note)) }
    }

    var batchesCreated: Int { seq.current }

    /// Takes everything collected since the previous drain and builds batch `batchSeq` (0-based,
    /// strictly increasing). `t0Up` is the window start.
    func drain(t0Up: Double, t0UtcMs: Double, device: DeviceStatus) -> IngestBatch {
        let p = pending.withLock { p -> Pending in
            let out = p
            p = Pending()
            return out
        }
        let n = seq.withLock { s -> Int in
            let v = s
            s += 1
            return v
        }
        let rel = { (t: Double) in round6(t - t0Up) }

        var b = IngestBatch(sessionId: sessionId, deviceId: deviceId, batchSeq: n,
                            t0Utc: ISO8601.string(Date(timeIntervalSince1970: t0UtcMs / 1000)),
                            t0Up: round6(t0Up), t0UtcMs: t0UtcMs.isFinite ? Int64(t0UtcMs.rounded()) : 0,
                            device: .init(battery: Double(device.batteryLevel),
                                          thermal: device.thermal.rawValue, lowPower: device.lowPowerMode))
        var dm = IngestBatch.DeviceMotion()
        dm.t.reserveCapacity(p.dm.count)
        for s in p.dm {
            dm.t.append(rel(s.t))
            dm.ua_x.append(round6(s.userAccel.x)); dm.ua_y.append(round6(s.userAccel.y)); dm.ua_z.append(round6(s.userAccel.z))
            dm.g_x.append(round6(s.gravity.x)); dm.g_y.append(round6(s.gravity.y)); dm.g_z.append(round6(s.gravity.z))
            dm.rr_x.append(round6(s.rotationRate.x)); dm.rr_y.append(round6(s.rotationRate.y)); dm.rr_z.append(round6(s.rotationRate.z))
            dm.q_w.append(round6(s.quaternion.w)); dm.q_x.append(round6(s.quaternion.x))
            dm.q_y.append(round6(s.quaternion.y)); dm.q_z.append(round6(s.quaternion.z))
        }
        b.deviceMotion = dm
        b.accelRaw = Self.xyz(p.accel, rel)
        b.gyroRaw = Self.xyz(p.gyro, rel)
        b.location = p.location.map {
            .init(tUtcMs: Int64($0.utcMs.rounded()), lat: round8($0.lat), lon: round8($0.lon), alt: round6($0.alt),
                  hAcc: round6($0.hAcc), speed: round6($0.speed), speedAcc: round6($0.speedAcc), course: round6($0.course),
                  isSimulated: $0.isSimulated)
        }
        var alt = IngestBatch.Altimeter()
        for s in p.alt {
            alt.t.append(rel(s.t)); alt.relAltM.append(round6(s.relativeAltitudeM)); alt.pressureKpa.append(round6(s.pressureKPa))
        }
        b.altimeter = alt
        var al = IngestBatch.AudioLevel()
        for s in p.audio {
            al.t.append(rel(s.t)); al.avgDbfs.append(round6(s.avgDbfs)); al.peakDbfs.append(round6(s.peakDbfs))
        }
        b.audioLevel = al
        b.labels = p.labels.map { .init(t: rel($0.t), type: $0.type, value: $0.value, note: $0.note) }
        return b
    }

    private static func xyz(_ samples: [Vec3Sample], _ rel: (Double) -> Double) -> IngestBatch.XYZ {
        var o = IngestBatch.XYZ()
        o.t.reserveCapacity(samples.count)
        for s in samples {
            o.t.append(rel(s.t)); o.x.append(round6(s.v.x)); o.y.append(round6(s.v.y)); o.z.append(round6(s.v.z))
        }
        return o
    }
}
