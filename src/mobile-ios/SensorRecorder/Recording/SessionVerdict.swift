import Foundation

/// "Did we get good data?" for one session (spec §7 Screen 5), as a pure, tested model.
struct SessionVerdict: Equatable {
    /// Streams the drive is pointless without (spec P0 motion + GPS).
    static let coreStreams: [StreamID] = [.deviceMotion, .accel, .gyro, .gps]

    let gaps: [String]       // display names of streams with a significant gap
    let missing: [String]    // core streams with no samples
    let writeErrors: Int

    init(metadata: SessionMetadata) {
        let streams = metadata.stats?.streams ?? [:]
        gaps = streams.compactMap { key, s -> String? in
            guard let id = StreamID(rawValue: key), s.maxGapSec > id.significantGap else { return nil }
            return id.displayName
        }.sorted()
        missing = Self.coreStreams.filter { (streams[$0.rawValue]?.samples ?? 0) == 0 }.map(\.displayName)
        writeErrors = metadata.stats?.writeErrors ?? 0
    }

    var ok: Bool { gaps.isEmpty && missing.isEmpty && writeErrors == 0 }

    var text: String {
        if ok { return "All streams OK" }
        var parts: [String] = []
        if !missing.isEmpty { parts.append("no data: " + missing.joined(separator: ", ")) }
        if !gaps.isEmpty { parts.append("gaps: " + gaps.joined(separator: ", ")) }
        if writeErrors > 0 { parts.append("\(writeErrors) write errors") }
        return parts.joined(separator: " · ")
    }
}
