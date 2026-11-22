import Foundation

enum HealthLevel: Int, Comparable, Sendable {
    case ok = 0, warn = 1, problem = 2
    static func < (a: HealthLevel, b: HealthLevel) -> Bool { a.rawValue < b.rawValue }

    var label: String {
        switch self {
        case .ok: return "OK"
        case .warn: return "WARN"
        case .problem: return "PROBLEM"
        }
    }
}

struct HealthIssue: Hashable, Sendable {
    let level: HealthLevel
    /// Stable identity (e.g. `rate.gyro`) used to detect *new* problems for alerting/logging.
    let key: String
    let message: String
}

enum ThermalLevel: String, Sendable, Codable {
    case nominal, fair, serious, critical

    init(_ s: ProcessInfo.ThermalState) {
        switch s {
        case .nominal: self = .nominal
        case .fair: self = .fair
        case .serious: self = .serious
        case .critical: self = .critical
        @unknown default: self = .serious
        }
    }
}

/// Everything the warning rules look at, captured at one instant.
struct HealthInputs: Sendable {
    var now: TimeInterval
    var recordingStartUp: TimeInterval
    var streams: [StreamID: StreamSnapshot] = [:]
    /// Last GPS fix arrival (uptime) and its accuracy.
    var gpsLastFixUp: TimeInterval?
    var gpsHorizontalAccuracy: Double?
    /// Location authorization currently lacks Precise Location (or was revoked) during recording.
    var locationDegraded: String?
    /// Uptime of the most recent disk write/flush failure.
    var lastWriteErrorUp: TimeInterval?
    var lastWriteError: String?
    var freeDiskBytes: Int64?
    var thermal: ThermalLevel = .nominal
    var lowPowerMode = false
    var batteryLevel: Float = 1 // -1 = unknown
    var batteryCharging = true
    var inBackground = false
    var returnedFromBackgroundUp: TimeInterval?
    var uploadEnabled = false
    var uploadQueueCount = 0
    var uploadLastSuccessUp: TimeInterval?
    var uploadEnabledSinceUp: TimeInterval?
    var uploadLastError: String?
}

/// Spec §7 "Warning rules". Pure function of `HealthInputs` so every rule is unit-tested.
enum HealthEvaluator {
    static let motionWarnFraction = 0.9     // 90 Hz of 100
    static let motionProblemFraction = 0.5  // 50 Hz of 100
    static let motionMaxAge: TimeInterval = 0.5
    static let gpsWarnAge: TimeInterval = 5
    static let gpsProblemAge: TimeInterval = 15
    static let gpsWarnAccuracy = 20.0
    static let diskWarnBytes: Int64 = 1_000_000_000
    static let diskProblemBytes: Int64 = 300_000_000
    static let batteryWarn: Float = 0.20
    static let uploadQueueWarn = 30
    static let uploadStaleSec: TimeInterval = 60
    static let writeErrorStickySec: TimeInterval = 30
    static let backgroundStickySec: TimeInterval = 10
    static let barometerWarnAge: TimeInterval = 30
    /// A motion stream with no sample at all this long after start is a PROBLEM.
    static let motionNoDataGrace: TimeInterval = 1.5
    /// Extra settle time after the first full rate window before rates are judged.
    static let rateWindowSettle: TimeInterval = 0.5

    static func evaluate(_ i: HealthInputs) -> [HealthIssue] {
        var out: [HealthIssue] = []
        let elapsed = i.now - i.recordingStartUp

        // Motion streams
        for id in [StreamID.deviceMotion, .accel, .gyro, .mag] {
            guard let s = i.streams[id], s.available, let expected = id.expectedHz else { continue }
            let name = id.displayName
            if let age = s.age {
                if age > motionMaxAge {
                    out.append(.init(level: .problem, key: "stale.\(id.rawValue)",
                                     message: "\(name): no sample for \(fmt1(age)) s"))
                    continue
                }
            } else {
                if elapsed > motionNoDataGrace {
                    out.append(.init(level: .problem, key: "stale.\(id.rawValue)", message: "\(name): no data"))
                }
                continue
            }
            // Only judge the rate once a full window has elapsed.
            guard elapsed >= id.rateWindow + rateWindowSettle else { continue }
            if s.rateHz < expected * motionProblemFraction {
                out.append(.init(level: .problem, key: "rate.\(id.rawValue)",
                                 message: "\(name) \(fmt1(s.rateHz)) Hz (< \(Int(expected * motionProblemFraction)))"))
            } else if s.rateHz < expected * motionWarnFraction {
                out.append(.init(level: .warn, key: "rate.\(id.rawValue)",
                                 message: "\(name) \(fmt1(s.rateHz)) Hz (< \(Int(expected * motionWarnFraction)))"))
            }
        }

        // GPS
        let gpsAge = i.now - (i.gpsLastFixUp ?? i.recordingStartUp)
        if gpsAge > gpsProblemAge {
            out.append(.init(level: .problem, key: "gps.nofix", message: "GPS: no fix for \(Int(gpsAge)) s"))
        } else if gpsAge > gpsWarnAge {
            out.append(.init(level: .warn, key: "gps.nofix", message: "GPS: no fix for \(Int(gpsAge)) s"))
        }
        if let acc = i.gpsHorizontalAccuracy, i.gpsLastFixUp != nil, acc > gpsWarnAccuracy {
            out.append(.init(level: .warn, key: "gps.accuracy", message: "GPS accuracy \(Int(acc)) m (> \(Int(gpsWarnAccuracy)))"))
        }

        // Barometer (not in the spec table; a long silence is worth an amber hint)
        if let b = i.streams[.barometer], b.available {
            let age = b.age ?? elapsed
            if age > barometerWarnAge {
                out.append(.init(level: .warn, key: "baro.stale", message: "Barometer: no data for \(Int(age)) s"))
            }
        }

        // Location permission changed mid-drive
        if let why = i.locationDegraded {
            out.append(.init(level: .problem, key: "gps.permission", message: why))
        }

        // Disk writes
        if let errUp = i.lastWriteErrorUp, i.now - errUp < writeErrorStickySec {
            out.append(.init(level: .problem, key: "disk.write",
                             message: "Disk write error: \(i.lastWriteError ?? "unknown")"))
        }
        if let free = i.freeDiskBytes, free >= 0 {
            if free < diskProblemBytes {
                out.append(.init(level: .problem, key: "disk.free", message: "Free disk \(ByteFormat.string(free)) (< \(ByteFormat.string(diskProblemBytes)))"))
            } else if free < diskWarnBytes {
                out.append(.init(level: .warn, key: "disk.free", message: "Free disk \(ByteFormat.string(free)) (< \(ByteFormat.string(diskWarnBytes)))"))
            }
        }

        // Device
        switch i.thermal {
        case .critical: out.append(.init(level: .problem, key: "thermal", message: "Thermal CRITICAL: phone is throttling"))
        case .serious: out.append(.init(level: .warn, key: "thermal", message: "Thermal serious: cool the phone"))
        default: break
        }
        if i.lowPowerMode {
            out.append(.init(level: .problem, key: "lowpower", message: "Low Power Mode is ON: turn it off"))
        }
        if i.batteryLevel >= 0, i.batteryLevel < batteryWarn, !i.batteryCharging {
            out.append(.init(level: .warn, key: "battery", message: "Battery \(Int(i.batteryLevel * 100)) % and not charging"))
        }

        // App lifecycle
        if i.inBackground {
            out.append(.init(level: .warn, key: "background", message: "App is in background (still recording)"))
        } else if let back = i.returnedFromBackgroundUp, i.now - back < backgroundStickySec {
            out.append(.init(level: .warn, key: "background", message: "App was in background (recording continued)"))
        }

        // Upload: never PROBLEM — data is safe on disk.
        if i.uploadEnabled {
            if i.uploadQueueCount > uploadQueueWarn {
                out.append(.init(level: .warn, key: "upload.queue", message: "Upload queue \(i.uploadQueueCount) batches"))
            }
            let reference = i.uploadLastSuccessUp ?? i.uploadEnabledSinceUp ?? i.recordingStartUp
            if i.now - reference > uploadStaleSec {
                let what = i.uploadLastSuccessUp == nil ? "no successful upload yet" : "last upload OK \(Int(i.now - reference)) s ago"
                let err = i.uploadLastError.map { " (\($0))" } ?? ""
                out.append(.init(level: .warn, key: "upload.stale", message: "Upload: \(what)\(err)"))
            }
        }

        return out.sorted { a, b in a.level != b.level ? a.level > b.level : a.key < b.key }
    }

    static func overall(_ issues: [HealthIssue]) -> HealthLevel {
        issues.map(\.level).max() ?? .ok
    }

    /// Per-stream dot color for the dashboard table.
    static func level(for id: StreamID, in issues: [HealthIssue]) -> HealthLevel {
        let keys: [String]
        switch id {
        case .gps: keys = ["gps."]
        case .barometer: keys = ["baro."]
        default: keys = ["stale.\(id.rawValue)", "rate.\(id.rawValue)"]
        }
        return issues.filter { issue in keys.contains { issue.key.hasPrefix($0) } }.map(\.level).max() ?? .ok
    }

    private static func fmt1(_ v: Double) -> String { String(format: "%.1f", v) }
}

