import CoreMotion
import Foundation

/// Apple: "An app should create only a single instance of CMMotionManager."
enum SharedMotion {
    static let manager = CMMotionManager()
    static let altimeter = CMAltimeter()
    static let activity = CMMotionActivityManager()
}

/// Real CoreMotion streams M1–M4 at the highest practical rate (spec §3.1).
final class CoreMotionSource: MotionSource {
    private let manager = SharedMotion.manager
    private let queue: OperationQueue = {
        let q = OperationQueue()
        q.name = "sensorrecorder.motion"
        q.maxConcurrentOperationCount = 1
        q.qualityOfService = .userInitiated
        return q
    }()

    static let motionInterval = 0.01 // 100 Hz requested; iOS caps around 100 Hz
    static let magInterval = 0.02    // 50 Hz

    var isSynthetic: Bool { false }

    var availability: MotionAvailability {
        MotionAvailability(
            deviceMotion: manager.isDeviceMotionAvailable
                && CMMotionManager.availableAttitudeReferenceFrames().contains(.xArbitraryZVertical),
            accel: manager.isAccelerometerAvailable,
            gyro: manager.isGyroAvailable,
            mag: manager.isMagnetometerAvailable
        )
    }

    func start(_ cb: MotionCallbacks) {
        let a = availability
        if a.deviceMotion {
            manager.deviceMotionUpdateInterval = Self.motionInterval
            // Not a magnetometer-based frame: car metal makes magnetic yaw correction unreliable.
            manager.startDeviceMotionUpdates(using: .xArbitraryZVertical, to: queue) { m, err in
                if let err { cb.error("deviceMotion: \(err.localizedDescription)") }
                guard let m else { return }
                let q = m.attitude.quaternion
                cb.deviceMotion(DeviceMotionSample(
                    t: m.timestamp,
                    userAccel: Vec3(x: m.userAcceleration.x, y: m.userAcceleration.y, z: m.userAcceleration.z),
                    gravity: Vec3(x: m.gravity.x, y: m.gravity.y, z: m.gravity.z),
                    rotationRate: Vec3(x: m.rotationRate.x, y: m.rotationRate.y, z: m.rotationRate.z),
                    quaternion: Quaternion(w: q.w, x: q.x, y: q.y, z: q.z),
                    roll: m.attitude.roll, pitch: m.attitude.pitch, yaw: m.attitude.yaw))
            }
        }
        if a.accel {
            manager.accelerometerUpdateInterval = Self.motionInterval
            manager.startAccelerometerUpdates(to: queue) { d, err in
                if let err { cb.error("accel: \(err.localizedDescription)") }
                guard let d else { return }
                cb.accel(Vec3Sample(t: d.timestamp, v: Vec3(x: d.acceleration.x, y: d.acceleration.y, z: d.acceleration.z)))
            }
        }
        if a.gyro {
            manager.gyroUpdateInterval = Self.motionInterval
            manager.startGyroUpdates(to: queue) { d, err in
                if let err { cb.error("gyro: \(err.localizedDescription)") }
                guard let d else { return }
                cb.gyro(Vec3Sample(t: d.timestamp, v: Vec3(x: d.rotationRate.x, y: d.rotationRate.y, z: d.rotationRate.z)))
            }
        }
        if a.mag {
            manager.magnetometerUpdateInterval = Self.magInterval
            manager.startMagnetometerUpdates(to: queue) { d, err in
                if let err { cb.error("mag: \(err.localizedDescription)") }
                guard let d else { return }
                cb.mag(Vec3Sample(t: d.timestamp, v: Vec3(x: d.magneticField.x, y: d.magneticField.y, z: d.magneticField.z)))
            }
        }
    }

    func stop() {
        manager.stopDeviceMotionUpdates()
        manager.stopAccelerometerUpdates()
        manager.stopGyroUpdates()
        manager.stopMagnetometerUpdates()
        queue.waitUntilAllOperationsAreFinished()
    }
}

/// CMAltimeter: relative altitude + pressure (B1) and absolute altitude (B2).
final class CoreAltimeterSource: AltimeterSource {
    private let altimeter = SharedMotion.altimeter
    private let queue: OperationQueue = {
        let q = OperationQueue()
        q.name = "sensorrecorder.altimeter"
        q.maxConcurrentOperationCount = 1
        return q
    }()

    var isRelativeAvailable: Bool { CMAltimeter.isRelativeAltitudeAvailable() }
    var isAbsoluteAvailable: Bool { CMAltimeter.isAbsoluteAltitudeAvailable() }

    func start(_ cb: AltimeterCallbacks) {
        if isRelativeAvailable {
            altimeter.startRelativeAltitudeUpdates(to: queue) { d, err in
                if let err { cb.error("altimeter: \(err.localizedDescription)") }
                guard let d else { return }
                cb.relative(AltimeterSample(t: d.timestamp, relativeAltitudeM: d.relativeAltitude.doubleValue,
                                            pressureKPa: d.pressure.doubleValue))
            }
        }
        if isAbsoluteAvailable {
            altimeter.startAbsoluteAltitudeUpdates(to: queue) { d, err in
                if let err { cb.error("absAltitude: \(err.localizedDescription)") }
                guard let d else { return }
                cb.absolute(AbsoluteAltitudeSample(t: d.timestamp, altitudeM: d.altitude,
                                                   accuracyM: d.accuracy, precisionM: d.precision))
            }
        }
    }

    func stop() {
        altimeter.stopRelativeAltitudeUpdates()
        altimeter.stopAbsoluteAltitudeUpdates()
        queue.waitUntilAllOperationsAreFinished() // no callback after the writers close
    }
}

/// The one owner of `CMMotionActivityManager` updates. The recorder and the auto-start monitor (D59)
/// both subscribe; updates run while anyone is subscribed, so a recording's stop no longer turns off
/// the monitor's driving detection (`startActivityUpdates` keeps only the last handler).
final class ActivityHub {
    static let shared = ActivityHub()

    private let manager = SharedMotion.activity
    private let queue: OperationQueue = {
        let q = OperationQueue()
        q.name = "sensorrecorder.activity"
        q.maxConcurrentOperationCount = 1
        return q
    }()
    private let subscribers = Locked<[UUID: (ActivitySample) -> Void]>([:])

    var isAvailable: Bool { CMMotionActivityManager.isActivityAvailable() }

    func subscribe(_ handler: @escaping (ActivitySample) -> Void) -> UUID? {
        guard isAvailable else { return nil }
        let id = UUID()
        let first = subscribers.withLock { s -> Bool in
            s[id] = handler
            return s.count == 1
        }
        if first {
            manager.startActivityUpdates(to: queue) { [subscribers] a in
                guard let a else { return }
                let sample = ActivitySample(t: a.timestamp, stationary: a.stationary, walking: a.walking, running: a.running,
                                            automotive: a.automotive, cycling: a.cycling, unknown: a.unknown,
                                            confidence: a.confidence.rawValue,
                                            startUtcMs: a.startDate.timeIntervalSince1970 * 1000)
                for h in subscribers.current.values { h(sample) }
            }
        }
        return id
    }

    /// No callback for `id` after this returns.
    func unsubscribe(_ id: UUID) {
        let last = subscribers.withLock { s -> Bool in
            s[id] = nil
            return s.isEmpty
        }
        if last { manager.stopActivityUpdates() }
        if OperationQueue.current != queue { queue.waitUntilAllOperationsAreFinished() }
    }

    /// Activity of the last `seconds` (for a relaunch: what happened before the app was woken).
    func recent(seconds: TimeInterval, completion: @escaping ([ActivitySample]) -> Void) {
        guard isAvailable else { completion([]); return }
        let now = Date()
        manager.queryActivityStarting(from: now.addingTimeInterval(-seconds), to: now, to: queue) { list, _ in
            completion((list ?? []).map { a in
                ActivitySample(t: a.timestamp, stationary: a.stationary, walking: a.walking, running: a.running,
                               automotive: a.automotive, cycling: a.cycling, unknown: a.unknown,
                               confidence: a.confidence.rawValue,
                               startUtcMs: a.startDate.timeIntervalSince1970 * 1000)
            })
        }
    }
}

/// CMMotionActivityManager (A1): free "driving vs stopped" segmentation, through `ActivityHub`.
final class CoreActivitySource: ActivitySource {
    private var subscription: UUID?

    var isAvailable: Bool { ActivityHub.shared.isAvailable }

    func start(_ handler: @escaping (ActivitySample) -> Void) {
        subscription = ActivityHub.shared.subscribe(handler)
    }

    func stop() {
        if let id = subscription { ActivityHub.shared.unsubscribe(id) }
        subscription = nil
    }
}

/// Motion & Fitness permission (needed for activity + altimeter).
enum MotionPermission {
    static var status: CMAuthorizationStatus { CMMotionActivityManager.authorizationStatus() }

    /// Triggers the system prompt (a tiny historical query) and reports the result.
    static func request(completion: @escaping (CMAuthorizationStatus) -> Void) {
        guard CMMotionActivityManager.isActivityAvailable() else {
            completion(status)
            return
        }
        let now = Date()
        SharedMotion.activity.queryActivityStarting(from: now.addingTimeInterval(-60), to: now, to: .main) { _, _ in
            completion(CMMotionActivityManager.authorizationStatus())
        }
    }
}
