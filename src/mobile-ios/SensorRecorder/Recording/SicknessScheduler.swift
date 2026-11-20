import Foundation

/// Spec §3.7 H1: prompt for a MISC rating every 2 minutes; auto-dismiss after 30 s as `missed`.
/// Pure state machine driven by `tick(now:)` so it is unit-tested without timers.
struct SicknessScheduler: Equatable {
    enum Event: Equatable { case prompt, missed }

    let interval: TimeInterval
    let timeout: TimeInterval
    private(set) var nextPromptAt: TimeInterval
    private(set) var activePromptAt: TimeInterval?

    init(start: TimeInterval, interval: TimeInterval = 120, timeout: TimeInterval = 30) {
        self.interval = interval
        self.timeout = timeout
        nextPromptAt = start + interval
    }

    var isPromptActive: Bool { activePromptAt != nil }

    func remaining(now: TimeInterval) -> TimeInterval? {
        activePromptAt.map { max(0, timeout - (now - $0)) }
    }

    mutating func tick(now: TimeInterval) -> Event? {
        if let started = activePromptAt {
            if now - started >= timeout {
                activePromptAt = nil
                return .missed
            }
            return nil
        }
        if now >= nextPromptAt {
            activePromptAt = now
            // Keep a fixed cadence; if we were suspended for a long time, don't fire a burst.
            nextPromptAt += interval
            if nextPromptAt <= now { nextPromptAt = now + interval }
            return .prompt
        }
        return nil
    }

    /// A rating was given (prompted or manual). Closes any open prompt.
    mutating func answered() {
        activePromptAt = nil
    }
}
