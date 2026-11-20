import Foundation

/// Abstracts the two clocks we care about so the time logic can be unit-tested.
protocol ClockSource: Sendable {
    /// Seconds since boot — the same monotonic clock as `CMLogItem.timestamp`.
    func uptime() -> TimeInterval
    /// Wall clock, Unix epoch milliseconds (UTC).
    func nowUtcMs() -> Double
}

struct SystemClock: ClockSource {
    func uptime() -> TimeInterval { ProcessInfo.processInfo.systemUptime }
    func nowUtcMs() -> Double { Date().timeIntervalSince1970 * 1000 }
}

/// A pair of (uptime, UTC) readings taken back-to-back. See spec §5.
struct ClockAnchor: Equatable, Sendable {
    let up: TimeInterval
    let utcMs: Double
}

/// Converts between the sensor clock (seconds since boot) and UTC using the most recent anchor.
///
/// `utc_ms = anchor_utc_ms + (t_up - anchor_up) * 1000`
///
/// Anchors are refreshed every 10 s by the recording session and written to `clock.csv`,
/// so the backend can redo this conversion (and detect wall-clock jumps from NTP corrections).
final class TimeBase: @unchecked Sendable {
    private let clock: ClockSource
    private let anchor: Locked<ClockAnchor>

    init(clock: ClockSource = SystemClock()) {
        self.clock = clock
        anchor = Locked(Self.sample(clock))
    }

    /// Reads uptime, wall clock, uptime again and uses the midpoint, which halves the read jitter.
    static func sample(_ clock: ClockSource) -> ClockAnchor {
        let u1 = clock.uptime()
        let w = clock.nowUtcMs()
        let u2 = clock.uptime()
        return ClockAnchor(up: (u1 + u2) / 2, utcMs: w)
    }

    @discardableResult
    func refreshAnchor() -> ClockAnchor {
        let a = Self.sample(clock)
        anchor.withLock { $0 = a }
        return a
    }

    var currentAnchor: ClockAnchor { anchor.current }

    func uptimeNow() -> TimeInterval { clock.uptime() }
    func nowUtcMs() -> Double { clock.nowUtcMs() }

    func utcMs(fromUptime up: TimeInterval) -> Double {
        let a = anchor.current
        return a.utcMs + (up - a.up) * 1000
    }

    func uptime(fromUtcMs ms: Double) -> TimeInterval {
        let a = anchor.current
        return a.up + (ms - a.utcMs) / 1000
    }

    func uptime(from date: Date) -> TimeInterval {
        uptime(fromUtcMs: date.timeIntervalSince1970 * 1000)
    }

    func date(fromUptime up: TimeInterval) -> Date {
        Date(timeIntervalSince1970: utcMs(fromUptime: up) / 1000)
    }
}
