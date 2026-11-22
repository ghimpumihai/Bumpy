import Foundation

/// What the recap shows about a finished trip, derived from its `session.json` stats.
struct TripSummary: Equatable {
    /// Share of the trip for which motion and GPS both delivered data, 0–100; nil without stats.
    let qualityPercent: Int?
    /// Why quality is poor (red on the recap); nil when the data is good.
    let problem: String?
    let durationSec: Double

    /// Below this the recap shows the number in red with the reason.
    static let goodQuality = 90

    init(metadata: SessionMetadata) {
        let stats = metadata.stats
        durationSec = stats?.durationSec ?? 0
        guard let stats, stats.durationSec > 0 else {
            qualityPercent = nil
            problem = nil
            return
        }
        // Coverage = samples received / samples expected at the nominal rate. Gaps lower it;
        // a stream missing entirely gives 0.
        var worst: (id: StreamID, coverage: Double)?
        for id in [StreamID.deviceMotion, .gps] {
            guard let hz = id.expectedHz else { continue }
            let samples = Double(stats.streams[id.rawValue]?.samples ?? 0)
            let coverage = min(1, samples / (stats.durationSec * hz))
            if worst == nil || coverage < worst!.coverage { worst = (id, coverage) }
        }
        let percent = Int(((worst?.coverage ?? 0) * 100).rounded())
        qualityPercent = percent

        let verdict = SessionVerdict(metadata: metadata)
        if stats.writeErrors > 0 {
            problem = "\(stats.writeErrors) write errors on the phone."
        } else if let worst, percent < Self.goodQuality {
            let missing = (1 - worst.coverage) * stats.durationSec
            let name = worst.id == .gps ? "GPS" : "Motion"
            let other = worst.id == .gps ? "Motion data is complete." : "GPS is complete."
            problem = "\(name) dropped for \(TripFormat.gap(missing)). \(other)"
        } else if !verdict.ok {
            problem = verdict.text.prefix(1).uppercased() + String(verdict.text.dropFirst()) + "."
        } else {
            problem = nil
        }
    }

    var isPoor: Bool { problem != nil }

    /// Track length from the (≥ 5 m thinned) live track; the on-screen estimate, not the backend's.
    static func distanceMeters(_ points: [TrackBuffer.Point]) -> Double {
        zip(points, points.dropFirst()).reduce(0) { $0 + TrackBuffer.distanceM($1.0, $1.1) }
    }
}

enum TripFormat {
    /// `12 s`, `1 min 40 s`, `12 min`.
    static func gap(_ seconds: Double) -> String {
        let s = max(0, Int(seconds.rounded()))
        if s < 60 { return "\(s) s" }
        let m = s / 60, r = s % 60
        if m >= 10 || r == 0 { return "\(m) min" }
        return "\(m) min \(r) s"
    }

    /// `42 min`, `1 h 05 min`, `40 s`.
    static func duration(_ seconds: Double) -> String {
        let s = max(0, Int(seconds.rounded()))
        if s < 60 { return "\(s) s" }
        let m = s / 60
        if m < 60 { return "\(m) min" }
        return String(format: "%d h %02d min", m / 60, m % 60)
    }

    /// `18.6 km`, `850 m`.
    static func distance(_ meters: Double) -> String {
        meters < 1000 ? "\(Int(meters.rounded())) m" : String(format: "%.1f km", meters / 1000)
    }

    /// `42:17` or `1:02:17`.
    static func timer(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds.rounded(.down)))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
                         : String(format: "%02d:%02d", s / 60, s % 60)
    }
}
