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
        // Additive (02 D32: batches carry the full dataset): attitude angles as in device_motion.csv.
        var roll: [Double] = [], pitch: [Double] = [], yaw: [Double] = []
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
        // Additive (full dataset, same as location.csv): ellipsoidal altitude, accuracies.
        var ellAlt: Double = 0, vAcc: Double = 0, courseAcc: Double = 0

        enum CodingKeys: String, CodingKey {
            case tUtcMs, lat, lon, alt, hAcc, speed, speedAcc, course, isSimulated, ellAlt, vAcc, courseAcc
        }
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(tUtcMs, forKey: .tUtcMs)
            try c.encode(lat, forKey: .lat); try c.encode(lon, forKey: .lon); try c.encode(alt, forKey: .alt)
            try c.encode(hAcc, forKey: .hAcc); try c.encode(speed, forKey: .speed)
            try c.encode(speedAcc, forKey: .speedAcc); try c.encode(course, forKey: .course)
            try c.encode(isSimulated, forKey: .isSimulated) // explicit null
            try c.encode(ellAlt, forKey: .ellAlt); try c.encode(vAcc, forKey: .vAcc)
            try c.encode(courseAcc, forKey: .courseAcc)
        }
    }

    /// Compass heading (L2), Date-based like location.
    struct Heading: Encodable, Equatable {
        var tUtcMs: Int64
        var magHeading: Double, trueHeading: Double, headingAcc: Double
        var x: Double, y: Double, z: Double
    }

    struct AbsAltitude: Encodable, Equatable {
        var t: [Double] = []
        var altitudeM: [Double] = [], accuracyM: [Double] = [], precisionM: [Double] = []
    }

    /// CMMotionActivity changes (A1): the backend's bus/stop segmentation uses these.
    struct Activity: Encodable, Equatable {
        var t: Double
        var stationary: Bool, walking: Bool, running: Bool, automotive: Bool, cycling: Bool, unknown: Bool
        var confidence: Int
        var startUtcMs: Int64
    }

    struct Altimeter: Encodable, Equatable {
        var t: [Double] = []
        var relAltM: [Double] = []
        var pressureKpa: [Double] = []
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
        // Additive (full dataset, same as device.csv).
        var batteryState: String = "unknown"
        var freeDiskBytes: Int64 = -1
        var netStatus: String = "unknown"
        var netType: String = "none"
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
        "device.battery": "fraction 0-1 (-1 = unknown)", "device.freeDiskBytes": "bytes",
        "deviceMotion.roll": "rad", "deviceMotion.pitch": "rad", "deviceMotion.yaw": "rad",
        "magRaw": "µT", "heading.magHeading": "deg", "heading.trueHeading": "deg (-1 = invalid)",
        "heading.headingAcc": "deg (-1 = invalid)", "heading.xyz": "µT", "heading.tUtcMs": "ms since Unix epoch (UTC)",
        "absAltitude.altitudeM": "m", "absAltitude.accuracyM": "m", "absAltitude.precisionM": "m",
        "activity.t": "s (relative to t0Up)", "activity.confidence": "0 low, 1 medium, 2 high",
        "activity.startUtcMs": "ms since Unix epoch (UTC)",
        "location.ellAlt": "m", "location.vAcc": "m (-1 = invalid)", "location.courseAcc": "deg (-1 = invalid)",
    ]
    var deviceMotion = DeviceMotion()
    var accelRaw = XYZ()
    var gyroRaw = XYZ()
    var location: [Location] = []
    var altimeter = Altimeter()
    var labels: [Label] = []
    var device: Device
    // Additive streams (02 D32: "each batch holds every sensor at full rate"). No audio (D48).
    var magRaw = XYZ()
    var heading: [Heading] = []
    var absAltitude = AbsAltitude()
    var activity: [Activity] = []

    var sampleCount: Int {
        deviceMotion.t.count + accelRaw.t.count + gyroRaw.t.count + location.count
            + altimeter.t.count + labels.count
    }

    func jsonData() throws -> Data {
        let enc = JSONEncoder()
        // sortedKeys: deterministic bytes (dictionary order is otherwise unspecified), so a re-sent
        // batch is byte-identical and payloads diff cleanly.
        enc.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]
        return try enc.encode(self)
    }
}

// The 0 for a non-finite value is only a last resort (JSONEncoder throws on NaN, which would block the
// queue): `drain` never passes one in. See `BatchAccumulator.drain` for what it does instead.
@inline(__always) func round6(_ v: Double) -> Double { v.isFinite ? (v * 1e6).rounded() / 1e6 : 0 }
@inline(__always) func round8(_ v: Double) -> Double { v.isFinite ? (v * 1e8).rounded() / 1e8 : 0 }
/// For the fields where iOS itself uses -1 for "invalid" (speed, course, accuracies, battery).
@inline(__always) func round6OrInvalid(_ v: Double) -> Double { v.isFinite ? round6(v) : -1 }
@inline(__always) func allFinite(_ values: Double...) -> Bool { values.allSatisfy(\.isFinite) }

/// Collects the samples of the current 2 s window (an in-memory copy; disk files remain the
/// source of truth). Thread-safe: `add*` is called from sensor queues, `drain` from the batch timer.
final class BatchAccumulator: @unchecked Sendable {
    private struct Pending {
        var dm: [DeviceMotionSample] = []
        var accel: [Vec3Sample] = []
        var gyro: [Vec3Sample] = []
        var location: [LocationSample] = []
        var alt: [AltimeterSample] = []
        var labels: [(t: Double, type: String, value: String?, note: String?)] = []
        var mag: [Vec3Sample] = []
        var heading: [HeadingSample] = []
        var absAlt: [AbsoluteAltitudeSample] = []
        var activity: [ActivitySample] = []
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
    func addMag(_ s: Vec3Sample) { pending.withLock { $0.mag.append(s) } }
    func add(_ s: HeadingSample) { pending.withLock { $0.heading.append(s) } }
    func add(_ s: AbsoluteAltitudeSample) { pending.withLock { $0.absAlt.append(s) } }
    func add(_ s: ActivitySample) { pending.withLock { $0.activity.append(s) } }
    func addLabel(t: Double, type: String, value: String?, note: String?) {
        pending.withLock { $0.labels.append((t, type, value, note)) }
    }

    /// Batches durably queued so far (= the §6.1 `batchCount`): sequence numbers `0..<batchesCreated`.
    var batchesCreated: Int { seq.current }

    /// The sequence number the next queued batch gets.
    var nextSeq: Int { seq.current }

    /// Call once batch `seq` is durably in the upload queue: only then is its number used. A batch
    /// that could not be queued (disk full, encode error) leaves no hole, so `batchCount` is exact
    /// (spec §6.2). Batches are queued from one place at a time (batch timer, then stop()).
    func markQueued(seq queued: Int) {
        seq.withLock { if $0 == queued { $0 += 1 } }
    }

    /// Drops the current window without building a batch or consuming a sequence number (upload
    /// OFF): batchSeq stays contiguous over the batches actually queued, so the §6.1 `batchCount`
    /// tells the backend exactly which batches to expect.
    func discard() {
        pending.withLock { $0 = Pending() }
    }

    /// Takes everything collected since the previous drain and builds a batch numbered `nextSeq`
    /// (0-based). The number is consumed only by `markQueued(seq:)`. `t0Up` is the window start.
    ///
    /// Non-finite values: the CSV writes an empty field, but the contract (spec §6, ingest
    /// `validate_batch`) accepts only finite numbers, never null, and one bad value rejects the whole
    /// batch. So a value iOS marks invalid with -1 anyway (speed, course, accuracies, battery) gets -1
    /// (a non-finite altitude also sets `vAcc` to -1, iOS's "altitude invalid"); any other sample with
    /// a non-finite value, or a fix outside lat ±90 / lon ±180, is left out of the batch rather than
    /// sent as a made-up 0. Arrays stay aligned, and the session folder keeps the row.
    func drain(t0Up: Double, t0UtcMs: Double, device: DeviceStatus) -> IngestBatch {
        let p = pending.withLock { p -> Pending in
            let out = p
            p = Pending()
            return out
        }
        let n = nextSeq
        let battery = Double(device.batteryLevel)
        let rel = { (t: Double) in round6(t - t0Up) }

        var b = IngestBatch(sessionId: sessionId, deviceId: deviceId, batchSeq: n,
                            t0Utc: ISO8601.string(Date(timeIntervalSince1970: t0UtcMs / 1000)),
                            t0Up: round6(t0Up), t0UtcMs: t0UtcMs.isFinite ? Int64(t0UtcMs.rounded()) : 0,
                            device: .init(battery: battery.isFinite ? battery : -1,
                                          thermal: device.thermal.rawValue, lowPower: device.lowPowerMode,
                                          batteryState: device.batteryState, freeDiskBytes: device.freeDiskBytes,
                                          netStatus: device.networkStatus, netType: device.networkType))
        var dm = IngestBatch.DeviceMotion()
        dm.t.reserveCapacity(p.dm.count)
        for s in p.dm {
            let ua = s.userAccel, g = s.gravity, rr = s.rotationRate, q = s.quaternion
            guard allFinite(s.t, ua.x, ua.y, ua.z, g.x, g.y, g.z, rr.x, rr.y, rr.z, q.w, q.x, q.y, q.z,
                            s.roll, s.pitch, s.yaw) else { continue }
            dm.t.append(rel(s.t))
            dm.ua_x.append(round6(s.userAccel.x)); dm.ua_y.append(round6(s.userAccel.y)); dm.ua_z.append(round6(s.userAccel.z))
            dm.g_x.append(round6(s.gravity.x)); dm.g_y.append(round6(s.gravity.y)); dm.g_z.append(round6(s.gravity.z))
            dm.rr_x.append(round6(s.rotationRate.x)); dm.rr_y.append(round6(s.rotationRate.y)); dm.rr_z.append(round6(s.rotationRate.z))
            dm.q_w.append(round6(s.quaternion.w)); dm.q_x.append(round6(s.quaternion.x))
            dm.q_y.append(round6(s.quaternion.y)); dm.q_z.append(round6(s.quaternion.z))
            dm.roll.append(round6(s.roll)); dm.pitch.append(round6(s.pitch)); dm.yaw.append(round6(s.yaw))
        }
        b.deviceMotion = dm
        b.accelRaw = Self.xyz(p.accel, rel)
        b.gyroRaw = Self.xyz(p.gyro, rel)
        b.location = p.location.compactMap {
            guard $0.utcMs.isFinite, (-90...90).contains($0.lat), (-180...180).contains($0.lon) else { return nil }
            let altValid = allFinite($0.alt, $0.ellAlt)
            return .init(tUtcMs: Int64($0.utcMs.rounded()), lat: round8($0.lat), lon: round8($0.lon), alt: round6($0.alt),
                         hAcc: round6OrInvalid($0.hAcc), speed: round6OrInvalid($0.speed),
                         speedAcc: round6OrInvalid($0.speedAcc), course: round6OrInvalid($0.course),
                         isSimulated: $0.isSimulated, ellAlt: round6($0.ellAlt), vAcc: altValid ? round6OrInvalid($0.vAcc) : -1,
                         courseAcc: round6OrInvalid($0.courseAcc))
        }
        b.magRaw = Self.xyz(p.mag, rel)
        b.heading = p.heading.compactMap {
            guard allFinite($0.utcMs, $0.magneticHeading, $0.raw.x, $0.raw.y, $0.raw.z) else { return nil }
            return .init(tUtcMs: Int64($0.utcMs.rounded()), magHeading: round6($0.magneticHeading),
                         trueHeading: round6OrInvalid($0.trueHeading), headingAcc: round6OrInvalid($0.accuracy),
                         x: round6($0.raw.x), y: round6($0.raw.y), z: round6($0.raw.z))
        }
        var abs = IngestBatch.AbsAltitude()
        for s in p.absAlt where allFinite(s.t, s.altitudeM, s.accuracyM, s.precisionM) {
            abs.t.append(rel(s.t)); abs.altitudeM.append(round6(s.altitudeM))
            abs.accuracyM.append(round6(s.accuracyM)); abs.precisionM.append(round6(s.precisionM))
        }
        b.absAltitude = abs
        b.activity = p.activity.filter { $0.t.isFinite }.map {
            .init(t: rel($0.t), stationary: $0.stationary, walking: $0.walking, running: $0.running, automotive: $0.automotive,
                  cycling: $0.cycling, unknown: $0.unknown, confidence: $0.confidence,
                  startUtcMs: $0.startUtcMs.isFinite ? Int64($0.startUtcMs.rounded()) : 0)
        }
        var alt = IngestBatch.Altimeter()
        for s in p.alt where allFinite(s.t, s.relativeAltitudeM, s.pressureKPa) {
            alt.t.append(rel(s.t)); alt.relAltM.append(round6(s.relativeAltitudeM)); alt.pressureKpa.append(round6(s.pressureKPa))
        }
        b.altimeter = alt
        b.labels = p.labels.map { .init(t: rel($0.t), type: $0.type, value: $0.value, note: $0.note) }
        return b
    }

    private static func xyz(_ samples: [Vec3Sample], _ rel: (Double) -> Double) -> IngestBatch.XYZ {
        var o = IngestBatch.XYZ()
        o.t.reserveCapacity(samples.count)
        for s in samples where allFinite(s.t, s.v.x, s.v.y, s.v.z) {
            o.t.append(rel(s.t)); o.x.append(round6(s.v.x)); o.y.append(round6(s.v.y)); o.z.append(round6(s.v.z))
        }
        return o
    }
}
