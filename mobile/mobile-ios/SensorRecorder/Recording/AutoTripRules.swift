import Foundation

/// When a trip starts and stops by itself (D59, 01 §7 "Automatic trips"). Pure: the monitor feeds it
/// GPS speeds and motion activity with their uptime and asks; unit-tested.
struct AutoTripRules {
    /// Above a sprint, so running never starts a trip.
    static let startSpeedMs = 20 / 3.6
    /// Fast time needed within the window: city buses and stop-and-go traffic rarely hold 20 km/h
    /// for 30 s in one go.
    static let startFastSeconds: TimeInterval = 30
    static let startWindowSeconds: TimeInterval = 90
    /// A gap between fixes counts at most this long (a GPS outage is not fast driving).
    static let maxFixGapSeconds: TimeInterval = 3
    /// Running or cycling this recently rules a candidate out.
    static let activityWindowSeconds: TimeInterval = 60
    /// Bus layovers and traffic jams are shorter than this.
    static let stopSlowSpeedMs = 1.5
    static let stopSlowSeconds: TimeInterval = 600
    /// Standing tram passengers read as walking, hence the speed limit.
    static let stopWalkSpeedMs = 2.0
    static let stopWalkSeconds: TimeInterval = 60
    /// The slow rule needs a fix this recent: no GPS (a tunnel, a garage) is not "stopped".
    static let stopFixMaxAgeSeconds: TimeInterval = 60

    struct Fix: Equatable { var t: TimeInterval; var speed: Double }
    struct Activity: Equatable { var t: TimeInterval; var sample: ActivitySample }

    private(set) var fixes: [Fix] = []
    private(set) var activities: [Activity] = []
    /// Uptime of the last fix at or above `stopSlowSpeedMs`.
    private(set) var lastMovingAt: TimeInterval?

    /// Fixes with an invalid speed (< 0) are ignored.
    mutating func addFix(t: TimeInterval, speed: Double) {
        guard speed >= 0 else { return }
        fixes.append(Fix(t: t, speed: speed))
        if speed >= Self.stopSlowSpeedMs { lastMovingAt = t }
        fixes.removeAll { $0.t < t - Self.startWindowSeconds - Self.maxFixGapSeconds }
    }

    /// `t` is when the activity began (its start date on the uptime clock).
    mutating func addActivity(t: TimeInterval, _ sample: ActivitySample) {
        activities.append(Activity(t: t, sample: sample))
        activities.sort { $0.t < $1.t }
        // Keep the newest activity older than the window: it is still the current one.
        let cutoff = t - Self.activityWindowSeconds - Self.stopWalkSeconds
        if let lastOld = activities.lastIndex(where: { $0.t < cutoff }), lastOld > 0 {
            activities.removeFirst(lastOld)
        }
    }

    /// A new trip: forget the evidence of the last one.
    mutating func resetForTrip(startedAt t: TimeInterval) {
        lastMovingAt = t
    }

    private func current(at now: TimeInterval) -> ActivitySample? {
        activities.last { $0.t <= now }?.sample
    }

    /// In a vehicle by the motion activity, with no running or cycling lately.
    func isCandidate(now: TimeInterval) -> Bool {
        guard let a = current(at: now), a.automotive, a.confidence >= 1 else { return false }
        let recent = activities.filter { $0.t >= now - Self.activityWindowSeconds }
        return !recent.contains { $0.sample.running || $0.sample.cycling }
    }

    /// Seconds at or above `startSpeedMs` within the last `startWindowSeconds`.
    func fastSeconds(now: TimeInterval) -> TimeInterval {
        let from = now - Self.startWindowSeconds
        var total: TimeInterval = 0
        for (i, f) in fixes.enumerated() where f.speed >= Self.startSpeedMs {
            let end = i + 1 < fixes.count ? fixes[i + 1].t : now
            let lo = max(f.t, from), hi = min(end, f.t + Self.maxFixGapSeconds, now)
            if hi > lo { total += hi - lo }
        }
        return total
    }

    func shouldStart(now: TimeInterval) -> Bool {
        isCandidate(now: now) && fastSeconds(now: now) >= Self.startFastSeconds
    }

    func shouldStop(now: TimeInterval) -> Bool {
        if let last = fixes.last, now - last.t <= Self.stopFixMaxAgeSeconds, last.speed < Self.stopSlowSpeedMs,
           let moving = lastMovingAt, now - moving >= Self.stopSlowSeconds {
            return true
        }
        return isWalkingAway(now: now)
    }

    /// Walking (medium or high confidence) for a minute, slowly, with no driving in that minute.
    private func isWalkingAway(now: TimeInterval) -> Bool {
        let from = now - Self.stopWalkSeconds
        guard let a = current(at: from), a.walking, !a.automotive, a.confidence >= 1 else { return false }
        let inWindow = activities.filter { $0.t > from && $0.t <= now }
        guard inWindow.allSatisfy({ $0.sample.walking && !$0.sample.automotive }) else { return false }
        let recentFixes = fixes.filter { $0.t >= from }
        return !recentFixes.isEmpty && recentFixes.allSatisfy { $0.speed < Self.stopWalkSpeedMs }
    }
}
