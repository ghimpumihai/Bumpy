import CoreLocation
import CoreMotion
import Foundation
import Observation

/// Pure analysis of the preflight motion capture (rates + mount stillness), unit-tested.
enum MotionTestAnalysis {
    struct Result: Equatable {
        var rates: [StreamID: Double]
        var accelMean: Vec3
        var accelStd: Vec3
        var gravityMean: Vec3?
        var maxStd: Double { max(accelStd.x, accelStd.y, accelStd.z) }
    }

    static func rate(_ t: [Double]) -> Double {
        guard t.count >= 2, let f = t.first, let l = t.last, l > f else { return 0 }
        return Double(t.count - 1) / (l - f)
    }

    static func analyze(dmTimes: [Double], gravity: [Vec3], accel: [Vec3Sample], gyroTimes: [Double], magTimes: [Double]) -> Result {
        let n = Double(max(1, accel.count))
        let mean = accel.reduce(Vec3.zero) { $0 + $1.v } * (1 / n)
        var varSum = Vec3.zero
        for s in accel {
            let d = s.v - mean
            varSum = varSum + Vec3(x: d.x * d.x, y: d.y * d.y, z: d.z * d.z)
        }
        let std = Vec3(x: (varSum.x / n).squareRoot(), y: (varSum.y / n).squareRoot(), z: (varSum.z / n).squareRoot())
        let gMean = gravity.isEmpty ? nil : gravity.reduce(Vec3.zero, +) * (1 / Double(gravity.count))
        return Result(rates: [.deviceMotion: rate(dmTimes), .accel: rate(accel.map(\.t)), .gyro: rate(gyroTimes), .mag: rate(magTimes)],
                      accelMean: mean, accelStd: std, gravityMean: gMean)
    }
}

/// Screen 3 logic: the preflight checklist (spec §7). Blocks Start until required checks pass,
/// with an explicit override for emergencies.
@MainActor
@Observable
final class PreflightModel {
    enum Status: String { case pending, running, pass, warn, fail, info }

    struct Check: Identifiable, Equatable {
        let id: String
        let title: String
        var status: Status = .pending
        var detail: String = ""
        let required: Bool
    }

    nonisolated static let minMotionRate = 90.0
    // 0.03 g: an idling engine or a stopped bus shakes more than 0.01 g, and a loose mount is far above
    // either (the spec gave 0.01 only as an example).
    nonisolated static let stillnessMaxStdG = 0.03
    nonisolated static let gpsMaxAccuracyM = 10.0
    nonisolated static let gpsKeepAccuracyM = 20.0
    nonisolated static let minBattery: Float = 0.5
    nonisolated static let minFreeDisk: Int64 = 2_000_000_000
    nonisolated static let motionTestDuration: TimeInterval = 5

    private(set) var checks: [Check]
    private(set) var motionTestProgress: Double = 0
    private(set) var motionTestRunning = false
    private(set) var motionResult: MotionTestAnalysis.Result?
    private(set) var running = false

    @ObservationIgnored private let app: AppModel
    @ObservationIgnored private var gpsTimer: Timer?
    @ObservationIgnored private var runTask: Task<Void, Never>?
    @ObservationIgnored private var motionTask: Task<Void, Never>?
    /// Uptime when GPS last met ≤ 10 m; the check then stays green unless the fix degrades a lot,
    /// so START and Override don't swap under the operator's finger on marginal accuracy.
    @ObservationIgnored private var gpsPassedAtUp: TimeInterval?

    /// True while any check is still running — Start/Override must wait.
    var busy: Bool { running || motionTestRunning }

    init(app: AppModel) {
        self.app = app
        checks = [
            Check(id: "perm.motion", title: "Motion permission", required: true),
            Check(id: "perm.location", title: "Location: authorized + precise", required: true),
            Check(id: "avail.motion", title: "Device motion / accel / gyro", required: true),
            Check(id: "avail.baro", title: "Barometer available", required: true),
            Check(id: "gps.fix", title: "GPS fix ≤ 10 m", required: true),
            Check(id: "motion.rate", title: "Motion rate ≥ 90 Hz", required: true),
            // A hand-held phone can't pass a stillness test; the backend excludes such sessions anyway.
            Check(id: "motion.still", title: "Mount stillness (5 s, vehicle stopped)", required: !app.setup.mount.handheld),
            Check(id: "dev.lpm", title: "Low Power Mode off", required: true),
            Check(id: "dev.battery", title: "Battery ≥ 50 % or charging", required: true),
            Check(id: "dev.thermal", title: "Thermal nominal / fair", required: true),
            Check(id: "dev.disk", title: "Free disk ≥ 2 GB", required: true),
            Check(id: "upload", title: "Upload test (warning only)", required: false),
        ]
    }

    var allRequiredPass: Bool { checks.filter(\.required).allSatisfy { $0.status == .pass } }
    var failingRequired: [Check] { checks.filter { $0.required && $0.status != .pass } }

    private func set(_ id: String, _ status: Status, _ detail: String) {
        guard let i = checks.firstIndex(where: { $0.id == id }) else { return }
        checks[i].status = status
        checks[i].detail = detail
    }

    // MARK: Run

    func onAppear() {
        app.location.startPreview()
        gpsTimer?.invalidate()
        let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.updateGPS()
                self?.updateDeviceChecks()
            }
        }
        RunLoop.main.add(t, forMode: .common)
        gpsTimer = t
        if !running && checks.allSatisfy({ $0.status == .pending }) {
            runTask = Task { await runAll() }
        }
    }

    func onDisappear() {
        gpsTimer?.invalidate()
        gpsTimer = nil
        if app.recording == nil { app.location.stopPreview() } // battery/heat between sessions
        runTask?.cancel() // stops permission waits and an in-flight motion test (sleeps throw on cancel)
        motionTask?.cancel()
    }

    func runAll() async {
        guard !running else { return }
        running = true
        defer { running = false }
        await checkPermissions()
        checkAvailability()
        updateDeviceChecks()
        updateGPS()
        async let upload: Void = checkUpload()
        await runMotionTest()
        await upload
    }

    private func checkPermissions() async {
        // Motion & Fitness
        do {
            set("perm.motion", .running, "requesting…")
            let status = await withCheckedContinuation { c in MotionPermission.request { c.resume(returning: $0) } }
            switch status {
            case .authorized: set("perm.motion", .pass, "authorized")
            case .notDetermined: set("perm.motion", .fail, "not determined: tap Re-run")
            default: set("perm.motion", .fail, "denied: Settings → Privacy → Motion & Fitness")
            }
        }

        // Location
        set("perm.location", .running, "requesting…")
        app.location.requestPermission()
        for _ in 0..<120 where app.location.authorization == .notDetermined {
            do { try await Task.sleep(nanoseconds: 250_000_000) } catch { return } // screen left
        }
        if app.location.isAuthorized && !app.location.isFullAccuracy {
            app.location.requestPermission() // asks for temporary full accuracy
            for _ in 0..<40 where !app.location.isFullAccuracy {
                do { try await Task.sleep(nanoseconds: 250_000_000) } catch { return }
            }
        }
        guard !Task.isCancelled else { return }
        updateLocationPermission()
        if app.location.isAuthorized { app.location.startPreview() }
    }

    private func updateLocationPermission() {
        let loc = app.location
        if !loc.isAuthorized {
            set("perm.location", .fail, loc.authorization == .notDetermined ? "not determined" : "denied: Settings → Privacy → Location")
        } else if !loc.isFullAccuracy {
            set("perm.location", .fail, "Precise Location is OFF: Settings → Bumpy → Location → Precise")
        } else {
            set("perm.location", .pass, loc.authorization == .authorizedAlways ? "always, precise" : "when in use, precise")
        }
    }

    private func checkAvailability() {
        let source = app.makeMotionSource()
        let a = source.availability
        let core = a.deviceMotion && a.accel && a.gyro
        let detail = "dm \(a.deviceMotion ? "✓" : "✗") · accel \(a.accel ? "✓" : "✗") · gyro \(a.gyro ? "✓" : "✗") · mag \(a.mag ? "✓" : "✗")"
        set("avail.motion", core ? .pass : .fail, detail)
        if CMAltimeter.isRelativeAltitudeAvailable() {
            set("avail.baro", .pass, CMAltimeter.isAbsoluteAltitudeAvailable() ? "relative + absolute" : "relative")
        } else {
            set("avail.baro", .fail, "not available on this device")
        }
    }

    private func updateGPS() {
        // Keep the permission row live (user may flip Precise Location in Settings and come back).
        let permStatus = checks.first { $0.id == "perm.location" }?.status
        if permStatus != .pending && permStatus != .running { updateLocationPermission() }
        guard app.location.isAuthorized else {
            set("gps.fix", .fail, "no location permission")
            return
        }
        guard let fix = app.location.latest, let at = app.location.latestFixUptime else {
            set("gps.fix", .running, "waiting for fix…")
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        let age = now - at
        let acc = fix.hAcc
        let detail = String(format: "hAcc %.1f m · %.0f s ago", acc, age)
        let good = acc >= 0 && acc <= Self.gpsMaxAccuracyM && age < 5
        if good { gpsPassedAtUp = now }
        // Hysteresis: once passed, stay green while the fix is still reasonable (≤ 20 m, < 30 s old).
        let stillOK = gpsPassedAtUp != nil && acc >= 0 && acc <= Self.gpsKeepAccuracyM && age < 30
        if good || stillOK {
            set("gps.fix", .pass, detail)
        } else {
            gpsPassedAtUp = nil
            set("gps.fix", .running, detail + " (need ≤ 10 m; go outside / wait)")
        }
    }

    func updateDeviceChecks() {
        let d = app.deviceMonitor.currentStatus()
        set("dev.lpm", d.lowPowerMode ? .fail : .pass, d.lowPowerMode ? "ON: Settings → Battery" : "off")
        if d.batteryLevel < 0 {
            set("dev.battery", .warn, "unknown (\(d.batteryState))")
        } else {
            let pct = Int(d.batteryLevel * 100)
            let ok = d.batteryLevel >= Self.minBattery || d.isCharging
            set("dev.battery", ok ? .pass : .fail, "\(pct) % · \(d.batteryState)")
        }
        let thermalOK = d.thermal == .nominal || d.thermal == .fair
        set("dev.thermal", thermalOK ? .pass : .fail, d.thermal.rawValue)
        let freeOK = d.freeDiskBytes >= Self.minFreeDisk
        set("dev.disk", freeOK ? .pass : .fail, d.freeDiskBytes >= 0 ? "\(ByteFormat.string(d.freeDiskBytes)) free" : "unknown")
    }

    private func checkUpload() async {
        let cfg = AppSettings.uploadConfig
        guard cfg.isEnabled else {
            set("upload", .info, "OFF – local only")
            return
        }
        set("upload", .running, "probing \(cfg.ingestURL?.absoluteString ?? "")…")
        let r = await UploadQueue.testConnection(config: cfg)
        set("upload", r.ok ? .pass : .warn, r.detail + (r.ok ? "" : " (data stays queued on disk)"))
    }

    /// Captures 5 s of motion: the first 3 s+ give the rate check, all 5 s the stillness check.
    func runMotionTest() async {
        // CMMotionManager is shared app-wide: starting the test would replace a live recording's handlers.
        guard !motionTestRunning, app.recording == nil, !Task.isCancelled else { return }
        motionTestRunning = true
        motionTestProgress = 0
        set("motion.rate", .running, "measuring…")
        set("motion.still", .running, "keep the vehicle stopped and the phone untouched…")
        defer { motionTestRunning = false }

        let source = app.makeMotionSource()
        let buf = Locked((dm: [Double](), grav: [Vec3](), accel: [Vec3Sample](), gyro: [Double](), mag: [Double]()))
        var cb = MotionCallbacks()
        cb.deviceMotion = { s in buf.withLock { $0.dm.append(s.t); $0.grav.append(s.gravity) } }
        cb.accel = { s in buf.withLock { $0.accel.append(s) } }
        cb.gyro = { s in buf.withLock { $0.gyro.append(s.t) } }
        cb.mag = { s in buf.withLock { $0.mag.append(s.t) } }
        source.start(cb)
        let steps = 25
        for i in 1...steps {
            do { try await Task.sleep(nanoseconds: UInt64(Self.motionTestDuration / Double(steps) * 1e9)) } catch { break }
            motionTestProgress = Double(i) / Double(steps)
        }
        source.stop()
        let b = buf.current
        let r = MotionTestAnalysis.analyze(dmTimes: b.dm, gravity: b.grav, accel: b.accel, gyroTimes: b.gyro, magTimes: b.mag)
        motionResult = r

        let core: [StreamID] = [.deviceMotion, .accel, .gyro]
        let rateText = core.map { String(format: "%@ %.1f", short($0), r.rates[$0] ?? 0) }.joined(separator: " · ")
            + String(format: " · mag %.1f Hz", r.rates[.mag] ?? 0)
        let ratesOK = core.allSatisfy { (r.rates[$0] ?? 0) >= Self.minMotionRate }
        set("motion.rate", ratesOK ? .pass : .fail, rateText)
        let stdText = String(format: "max σ %.4f g (need < %.2f)", r.maxStd, Self.stillnessMaxStdG)
        set("motion.still", r.maxStd < Self.stillnessMaxStdG && !b.accel.isEmpty ? .pass : .fail,
            b.accel.isEmpty ? "no accelerometer data" : stdText)
    }

    private func short(_ id: StreamID) -> String {
        switch id {
        case .deviceMotion: return "dm"
        case .accel: return "acc"
        case .gyro: return "gyr"
        default: return id.rawValue
        }
    }

    /// Re-run only the motion test (tracked so leaving the screen cancels it).
    func rerunMotionTest() {
        guard !busy else { return }
        motionTask = Task { await runMotionTest() }
    }

    /// Some permission was denied: the only fix is in the Settings app.
    var needsSettings: Bool {
        checks.contains { $0.id.hasPrefix("perm.") && $0.status == .fail && $0.detail.contains("Settings") }
            || (app.location.isAuthorized && !app.location.isFullAccuracy)
    }

    func rerun() {
        for i in checks.indices { checks[i].status = .pending; checks[i].detail = "" }
        gpsPassedAtUp = nil
        runTask?.cancel()
        runTask = Task { await runAll() }
    }

    func result(overridden: Bool) -> SessionMetadata.Preflight {
        let r = motionResult
        return .init(
            completedAtUtc: ISO8601.string(Date()),
            overridden: overridden,
            checks: checks.map { .init(id: $0.id, title: $0.title, status: $0.status.rawValue, detail: $0.detail, required: $0.required) },
            stillAccelMeanG: r.map { [$0.accelMean.x, $0.accelMean.y, $0.accelMean.z] },
            stillGravityG: r?.gravityMean.map { [$0.x, $0.y, $0.z] },
            stillAccelStdG: r.map { [$0.accelStd.x, $0.accelStd.y, $0.accelStd.z] },
            measuredRatesHz: r.map { Dictionary(uniqueKeysWithValues: $0.rates.map { ($0.key.rawValue, $0.value) }) })
    }
}
