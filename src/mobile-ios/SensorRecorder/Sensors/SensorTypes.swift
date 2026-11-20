import Foundation

// Plain value types for every sensor sample. Hardware adapters convert framework objects into
// these immediately, so everything downstream (CSV, stats, upload, plots) is testable without
// CoreMotion / CoreLocation. Units are the native iOS units (spec §3) — no conversions here.

struct Quaternion: Equatable, Sendable { var w, x, y, z: Double }

struct DeviceMotionSample: Equatable, Sendable {
    var t: TimeInterval          // seconds since boot
    var userAccel: Vec3          // g
    var gravity: Vec3            // g
    var rotationRate: Vec3       // rad/s
    var quaternion: Quaternion
    var roll: Double, pitch: Double, yaw: Double // rad
}

struct Vec3Sample: Equatable, Sendable {
    var t: TimeInterval
    var v: Vec3
}

struct LocationSample: Equatable, Sendable {
    var utcMs: Double
    var lat: Double, lon: Double
    var alt: Double, ellAlt: Double
    var hAcc: Double, vAcc: Double
    var speed: Double, speedAcc: Double
    var course: Double, courseAcc: Double
    var isSimulated: Bool?
}

struct HeadingSample: Equatable, Sendable {
    var utcMs: Double
    var magneticHeading: Double, trueHeading: Double, accuracy: Double
    var raw: Vec3 // µT
}

struct AltimeterSample: Equatable, Sendable {
    var t: TimeInterval
    var relativeAltitudeM: Double
    var pressureKPa: Double
}

struct AbsoluteAltitudeSample: Equatable, Sendable {
    var t: TimeInterval
    var altitudeM: Double, accuracyM: Double, precisionM: Double
}

struct ActivitySample: Equatable, Sendable {
    var t: TimeInterval
    var stationary, walking, running, automotive, cycling, unknown: Bool
    var confidence: Int // 0 low, 1 medium, 2 high
    var startUtcMs: Double

    var summary: String {
        var kinds: [String] = []
        if automotive { kinds.append("automotive") }
        if stationary { kinds.append("stationary") }
        if walking { kinds.append("walking") }
        if running { kinds.append("running") }
        if cycling { kinds.append("cycling") }
        if kinds.isEmpty { kinds.append(unknown ? "unknown" : "none") }
        let conf = ["lo", "med", "hi"][max(0, min(2, confidence))]
        return "\(kinds.joined(separator: "+")) (\(conf))"
    }
}

struct AudioLevelSample: Equatable, Sendable {
    var t: TimeInterval
    var avgDbfs: Double, peakDbfs: Double
}

struct DeviceStatus: Equatable, Sendable {
    var batteryLevel: Float          // 0...1, -1 unknown
    var batteryState: String         // unknown | unplugged | charging | full
    var thermal: ThermalLevel
    var lowPowerMode: Bool
    var freeDiskBytes: Int64
    var networkStatus: String        // satisfied | unsatisfied | requiresConnection | unknown
    var networkType: String          // wifi | cellular | wired | other | none

    var isCharging: Bool { batteryState == "charging" || batteryState == "full" }

    static let unknown = DeviceStatus(batteryLevel: -1, batteryState: "unknown", thermal: .nominal,
                                      lowPowerMode: false, freeDiskBytes: -1, networkStatus: "unknown",
                                      networkType: "none")
}

// MARK: - Source protocols

struct MotionAvailability: Equatable, Sendable {
    var deviceMotion: Bool
    var accel: Bool
    var gyro: Bool
    var mag: Bool
}

struct MotionCallbacks {
    var deviceMotion: (DeviceMotionSample) -> Void = { _ in }
    var accel: (Vec3Sample) -> Void = { _ in }
    var gyro: (Vec3Sample) -> Void = { _ in }
    var mag: (Vec3Sample) -> Void = { _ in }
    var error: (String) -> Void = { _ in }
}

protocol MotionSource: AnyObject {
    var availability: MotionAvailability { get }
    var isSynthetic: Bool { get }
    /// Starts all available motion streams. Callbacks arrive on a background queue.
    func start(_ callbacks: MotionCallbacks)
    func stop()
}

struct LocationCallbacks {
    var location: (LocationSample) -> Void = { _ in }
    var heading: (HeadingSample) -> Void = { _ in }
    var error: (String) -> Void = { _ in }
}

protocol LocationSource: AnyObject {
    /// Starts continuous high-accuracy updates for recording (in addition to any preflight observers).
    func startRecording(_ callbacks: LocationCallbacks)
    func stopRecording()
}

struct AltimeterCallbacks {
    var relative: (AltimeterSample) -> Void = { _ in }
    var absolute: (AbsoluteAltitudeSample) -> Void = { _ in }
    var error: (String) -> Void = { _ in }
}

protocol AltimeterSource: AnyObject {
    var isRelativeAvailable: Bool { get }
    var isAbsoluteAvailable: Bool { get }
    func start(_ callbacks: AltimeterCallbacks)
    func stop()
}

protocol ActivitySource: AnyObject {
    var isAvailable: Bool { get }
    func start(_ handler: @escaping (ActivitySample) -> Void)
    func stop()
}

struct AudioCallbacks {
    var level: (AudioLevelSample) -> Void = { _ in }
    /// (event, file) — e.g. ("start", "audio_000.m4a"); `t` is the uptime of the event.
    var segmentEvent: (_ t: TimeInterval, _ event: String, _ file: String) -> Void = { _, _, _ in }
    var log: (LogLevel, String) -> Void = { _, _ in }
}

protocol AudioSource: AnyObject {
    /// Starts recording segment files into `folder`. Returns false if recording could not start.
    @discardableResult
    func start(folder: URL, _ callbacks: AudioCallbacks) -> Bool
    func stop()
    var isRecording: Bool { get }
    /// Total bytes of all audio files written so far.
    var bytesWritten: Int64 { get }
    var latestLevel: AudioLevelSample? { get }
    var formatDescription: String { get }
    /// True if this source writes microphone audio to files (S2); false for the level-meter-only
    /// source used when audio recording is off (public transport).
    var recordsAudio: Bool { get }
}

protocol DeviceStatusSource: AnyObject {
    func currentStatus() -> DeviceStatus
}
