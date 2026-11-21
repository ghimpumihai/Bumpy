import AudioToolbox
import Foundation
import Observation
import UIKit

/// One row of the dashboard stream table.
struct StreamRowModel: Identifiable, Equatable {
    enum Dot: Equatable { case level(HealthLevel), neutral }
    let id: String
    let name: String
    let rate: String
    let samples: String
    let age: String
    let dot: Dot
    let detail: String?
}

struct DashboardSnapshot: Equatable {
    var elapsed: TimeInterval = 0
    var rows: [StreamRowModel] = []
    var deviceLine = ""
    var deviceLevel: HealthLevel = .ok
    var vertical: [Double] = []
    var lateral: [Double] = []
    var roughness: Double = 0
    var msdv: Double = 0
}

/// Main-thread view model for the recording dashboard. Refreshes at 8 Hz (spec: 5–10 Hz, never
/// per sample), evaluates the warning rules, alerts on new problems.
@MainActor
@Observable
final class RecordingController {
    let session: RecordingSession
    private(set) var snapshot = DashboardSnapshot()
    private(set) var issues: [HealthIssue] = []
    private(set) var overall: HealthLevel = .ok
    private(set) var finished: SessionMetadata?
    private(set) var trackPoints: [TrackBuffer.Point] = []
    /// "GPS back · 12 s gap", shown for a few seconds after GPS recovers.
    private(set) var recoveryNote: String?

    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var issueTracker = IssueTracker()
    @ObservationIgnored private var trackVersion = -1
    @ObservationIgnored private var tickCount = 0
    @ObservationIgnored private let alerter: Alerter
    @ObservationIgnored private var recoveryExpiry: Date?
    /// Uptime of the last GPS fix before the current outage; nil while GPS is fine.
    @ObservationIgnored private var gpsLostSinceUp: TimeInterval?

    static let refreshHz = 8.0
    static let recoveryNoteSeconds: TimeInterval = 5

    init(session: RecordingSession, alerter: Alerter? = nil) {
        self.session = session
        self.alerter = alerter ?? SystemAlerter()
    }

    // MARK: Lifecycle

    func start() {
        UIApplication.shared.isIdleTimerDisabled = true // screen never auto-locks while recording
        session.start()
        alerter.prepare()
        let t = Timer(timeInterval: 1 / Self.refreshHz, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        RunLoop.main.add(t, forMode: .common) // keeps ticking while scrolling
        timer = t
        refresh()
    }

    func stop() {
        guard finished == nil else { return }
        timer?.invalidate()
        timer = nil
        finished = session.stop()
        UIApplication.shared.isIdleTimerDisabled = false
        alerter.stopped()
    }

    var isFinished: Bool { finished != nil }

    // MARK: Refresh (8 Hz)

    /// Internal (not private) so tests can drive refresh ticks deterministically.
    func refresh() {
        tickCount += 1
        let now = session.timeBase.uptimeNow()

        // Health
        let inputs = session.healthInputs(now: now)
        let newIssues = HealthEvaluator.evaluate(inputs)
        handleIssueTransitions(newIssues)
        issues = newIssues
        overall = HealthEvaluator.overall(newIssues)

        if let exp = recoveryExpiry, Date() > exp { recoveryNote = nil; recoveryExpiry = nil }

        snapshot = buildSnapshot(now: now, inputs: inputs)

        // Track for the mini map: at most 1 Hz
        if tickCount % Int(Self.refreshHz) == 1 {
            let cur = session.track.current
            if cur.version != trackVersion {
                trackVersion = cur.version
                trackPoints = cur.points
            }
        }
    }

    private func handleIssueTransitions(_ new: [HealthIssue]) {
        let t = issueTracker.update(new)
        for i in t.appeared { session.log(i.level == .problem ? .problem : .warn, i.message) }
        for key in t.resolved { session.log(.info, "resolved: \(key)") }
        if t.alert { alerter.newProblem() } // spec: strong haptic + sound on PROBLEM

        let gpsLost = new.contains { $0.key == "gps.nofix" }
        if gpsLost, gpsLostSinceUp == nil {
            gpsLostSinceUp = session.latest.gpsFixUp ?? session.startUp
        } else if !gpsLost, let since = gpsLostSinceUp {
            gpsLostSinceUp = nil
            if let back = session.latest.gpsFixUp, back > since {
                recoveryNote = "GPS back · \(TripFormat.gap(back - since)) gap"
                recoveryExpiry = Date().addingTimeInterval(Self.recoveryNoteSeconds)
            }
        }
    }

    /// The one status line above "Hold to end trip": the worst current issue, else the recovery
    /// note, else "All saved".
    var statusLine: (text: String, level: HealthLevel) {
        if let worst = issues.max(by: { $0.level < $1.level }) {
            var text = worst.message
            if worst.key == "gps.nofix" {
                text = text.replacingOccurrences(of: "GPS: no fix for", with: "GPS lost for") + " · motion still saving"
            }
            if issues.count > 1 { text += " · +\(issues.count - 1) more" }
            return (text, worst.level)
        }
        return (recoveryNote ?? "All saved", .ok)
    }

    private func buildSnapshot(now: TimeInterval, inputs: HealthInputs) -> DashboardSnapshot {
        var s = DashboardSnapshot()
        s.elapsed = now - session.startUp
        let st = inputs.streams

        func fmtRate(_ r: Double) -> String { r >= 10 ? String(format: "%.1f Hz", r) : String(format: "%.2f Hz", r) }
        func fmtAge(_ a: TimeInterval?) -> String { a.map { String(format: "%.1fs", $0) } ?? "–" }
        func fmtCount(_ n: Int64) -> String { n.formatted(.number.grouping(.automatic).locale(Locale(identifier: "en_US"))) }
        func dot(_ id: StreamID) -> StreamRowModel.Dot {
            guard let snap = st[id], snap.available else { return .neutral }
            return .level(HealthEvaluator.level(for: id, in: issues))
        }

        var rows: [StreamRowModel] = []
        for id in [StreamID.deviceMotion, .accel, .gyro, .mag] {
            guard let snap = st[id] else { continue }
            if !snap.available {
                rows.append(.init(id: id.rawValue, name: id.displayName, rate: "n/a", samples: "", age: "", dot: .neutral, detail: nil))
                continue
            }
            rows.append(.init(id: id.rawValue, name: id.displayName, rate: fmtRate(snap.rateHz), samples: fmtCount(snap.count),
                              age: fmtAge(snap.age), dot: dot(id), detail: nil))
        }
        if let g = st[.gps] {
            let latest = session.latest
            var detail: String?
            if let fix = latest.gps {
                let kmh = fix.speed >= 0 ? String(format: "%.0f km/h", fix.speed * 3.6) : "– km/h"
                detail = String(format: "hAcc %.1f m · ", fix.hAcc) + kmh
            }
            let age = latest.gpsFixUp.map { now - $0 }
            rows.append(.init(id: "gps", name: "GPS", rate: g.available ? fmtRate(g.rateHz) : "n/a", samples: fmtCount(g.count),
                              age: fmtAge(age), dot: g.available ? .level(HealthEvaluator.level(for: .gps, in: issues)) : .neutral,
                              detail: detail))
        }
        if let b = st[.barometer] {
            var detail: String?
            if let a = session.latest.altimeter {
                detail = String(format: "%.2f kPa · rel %.1f m", a.pressureKPa, a.relativeAltitudeM)
            }
            rows.append(.init(id: "baro", name: "Barometer", rate: b.available ? fmtRate(b.rateHz) : "n/a",
                              samples: b.available ? fmtCount(b.count) : "", age: b.available ? fmtAge(b.age) : "",
                              dot: b.available ? .level(HealthEvaluator.level(for: .barometer, in: issues)) : .neutral, detail: detail))
        }
        if let a = st[.activity] {
            let act = session.latest.activity?.summary ?? (a.available ? "waiting…" : "n/a")
            rows.append(.init(id: "activity", name: "Activity", rate: a.available ? "auto" : "n/a", samples: act, age: "",
                              dot: .neutral, detail: nil))
        }
        // Disk
        let written = session.writer.totalCSVBytes
        let free = inputs.freeDiskBytes ?? -1
        let diskLevel = max(issues.first { $0.key.hasPrefix("disk.") }?.level ?? .ok, .ok)
        rows.append(.init(id: "disk", name: "Disk written", rate: ByteFormat.string(written),
                          samples: free >= 0 ? "free \(ByteFormat.string(free))" : "", age: "", dot: .level(diskLevel), detail: nil))
        // Upload
        if let up = session.uploadStatus, up.enabled {
            let last = up.lastSuccessUp.map { String(format: "last OK %.1fs", now - $0) } ?? "no upload yet"
            let lvl = issues.first { $0.key.hasPrefix("upload") }?.level ?? .ok
            rows.append(.init(id: "upload", name: "Upload", rate: "queue \(up.queueCount)", samples: last, age: "",
                              dot: .level(lvl), detail: up.lastError))
        } else {
            rows.append(.init(id: "upload", name: "Upload", rate: "OFF", samples: "local only", age: "", dot: .neutral, detail: nil))
        }
        s.rows = rows

        // Device line
        let d = session.deviceStatus
        let batt = d.batteryLevel >= 0 ? "\(Int(d.batteryLevel * 100))%" : "?%"
        s.deviceLine = "Battery \(batt)\(d.isCharging ? " ⚡" : "") · Thermal \(d.thermal.rawValue) · LPM \(d.lowPowerMode ? "ON" : "off")"
        s.deviceLevel = issues.filter { ["thermal", "lowpower", "battery"].contains($0.key) }.map(\.level).max() ?? .ok

        let live = session.live.snapshot()
        s.vertical = live.vertical
        s.lateral = live.lateral
        s.roughness = live.roughnessRms
        s.msdv = live.msdv
        return s
    }
}

/// Operator feedback channel (haptics + sounds). Injected so tests can assert *when* the
/// operator is alerted; the system implementation is used in the app.
@MainActor
protocol Alerter {
    func prepare()
    func newProblem()
    func stopped()
}

@MainActor
final class SystemAlerter: Alerter {
    private let haptics = UINotificationFeedbackGenerator()

    func prepare() { haptics.prepare() }
    func newProblem() {
        // spec: strong haptic + sound on PROBLEM
        haptics.notificationOccurred(.error)
        AudioServicesPlayAlertSound(1005)
    }
    func stopped() { haptics.notificationOccurred(.success) }
}

/// Which health issues are new, changed or resolved between two evaluations, and whether the
/// operator must be alerted. Pure (no timers, no I/O) so the alert policy is tested exactly.
struct IssueTracker {
    struct Transition: Equatable {
        /// Issues that are new or changed level (logged).
        var appeared: [HealthIssue] = []
        /// Keys that disappeared (logged as resolved).
        var resolved: [String] = []
        /// A PROBLEM appeared or an issue escalated to PROBLEM: strong haptic + sound.
        var alert = false
    }

    private(set) var known: [String: HealthLevel] = [:]

    mutating func update(_ issues: [HealthIssue]) -> Transition {
        var t = Transition()
        var current: [String: HealthLevel] = [:]
        for i in issues {
            current[i.key] = i.level
            if known[i.key] != i.level {
                t.appeared.append(i)
                if i.level == .problem { t.alert = true }
            }
        }
        t.resolved = known.keys.filter { current[$0] == nil }.sorted()
        known = current
        return t
    }
}
