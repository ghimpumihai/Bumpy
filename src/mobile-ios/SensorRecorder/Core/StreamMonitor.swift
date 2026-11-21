import Foundation

/// Logical data streams shown on the dashboard.
enum StreamID: String, CaseIterable, Sendable, Codable {
    case deviceMotion, accel, gyro, mag, gps, heading, barometer, absAltitude, activity, audioLevel, device

    var displayName: String {
        switch self {
        case .deviceMotion: return "DeviceMotion"
        case .accel: return "Accel raw"
        case .gyro: return "Gyro raw"
        case .mag: return "Magnetometer"
        case .gps: return "GPS"
        case .heading: return "Heading"
        case .barometer: return "Barometer"
        case .absAltitude: return "Abs. altitude"
        case .activity: return "Activity"
        case .audioLevel: return "Audio level"
        case .device: return "Device health"
        }
    }

    /// Nominal rate used for drop estimation and rate warnings. `nil` = event-driven.
    var expectedHz: Double? {
        switch self {
        case .deviceMotion, .accel, .gyro: return 100
        case .mag: return 50
        case .gps: return 1
        case .audioLevel: return 10
        case .device: return 0.2
        case .heading, .barometer, .absAltitude, .activity: return nil
        }
    }

    var isMotion: Bool { self == .deviceMotion || self == .accel || self == .gyro || self == .mag }

    /// A gap longer than this means lost data (summary row turns red). Spec: "> 1 s"; for 1 Hz GPS
    /// every gap is ~1 s, so it uses 3 s; event-driven / slow streams never count as gaps.
    var significantGap: TimeInterval {
        switch self {
        case .deviceMotion, .accel, .gyro, .mag, .audioLevel: return 1
        case .gps: return 3
        case .device: return 3 / (StreamID.device.expectedHz ?? 0.2) // 3 missed polls
        case .heading, .barometer, .absAltitude, .activity: return .infinity
        }
    }

    /// Window over which the "current" rate is measured (spec: 2 s for motion).
    var rateWindow: TimeInterval { isMotion || self == .audioLevel ? 2 : 10 }

    var file: StreamFile {
        switch self {
        case .deviceMotion: return .deviceMotion
        case .accel: return .accelRaw
        case .gyro: return .gyroRaw
        case .mag: return .magRaw
        case .gps: return .location
        case .heading: return .heading
        case .barometer: return .altimeter
        case .absAltitude: return .absAltitude
        case .activity: return .activity
        case .audioLevel: return .audioLevel
        case .device: return .device
        }
    }
}

/// Incremental gap statistics over a sequence of sample timestamps.
struct GapTracker: Equatable {
    let expectedHz: Double?
    private(set) var count: Int64 = 0
    private(set) var first: Double?
    private(set) var last: Double?
    private(set) var maxGap: Double = 0
    private(set) var gapsOver1s = 0
    private(set) var droppedEstimate: Int64 = 0
    private(set) var nonMonotonic = 0

    init(expectedHz: Double?) { self.expectedHz = expectedHz }

    mutating func add(_ t: Double) {
        count += 1
        if first == nil { first = t }
        if let prev = last {
            let dt = t - prev
            if dt <= 0 {
                nonMonotonic += 1
            } else {
                maxGap = max(maxGap, dt)
                if dt > 1 { gapsOver1s += 1 }
                if let hz = expectedHz, dt * hz > 1.5 {
                    droppedEstimate += Int64((dt * hz).rounded()) - 1
                }
            }
        }
        if let l = last { if t > l { last = t } } else { last = t }
    }

    var meanRateHz: Double {
        guard count > 1, let f = first, let l = last, l > f else { return 0 }
        return Double(count - 1) / (l - f)
    }

    var spanSec: Double {
        guard let f = first, let l = last else { return 0 }
        return l - f
    }
}

struct StreamSnapshot: Equatable, Sendable {
    let id: StreamID
    let count: Int64
    /// Rate over the stream's window ending now; 0 if fewer than 2 samples in the window.
    let rateHz: Double
    /// Seconds since the last sample arrived; nil if nothing arrived yet.
    let age: TimeInterval?
    let meanRateHz: Double
    let maxGap: Double
    let gapsOver1s: Int
    let droppedEstimate: Int64
    let available: Bool
}

/// Thread-safe live statistics for one stream. `record` is called from sensor queues.
final class StreamMonitor: @unchecked Sendable {
    let id: StreamID
    private struct State {
        var gaps: GapTracker
        var recent: RingBuffer<Double>
        var lastArrival: TimeInterval?
        var available = true
    }
    private let state: Locked<State>

    init(id: StreamID) {
        self.id = id
        let cap = min(2048, Int(id.rateWindow * (id.expectedHz ?? 10) * 2) + 16)
        state = Locked(State(gaps: GapTracker(expectedHz: id.expectedHz), recent: RingBuffer(capacity: cap)))
    }

    /// - Parameters:
    ///   - t: sample timestamp (seconds since boot)
    ///   - arrival: uptime when we received it
    func record(t: TimeInterval, arrival: TimeInterval) {
        state.withLock {
            $0.gaps.add(t)
            $0.recent.append(t)
            $0.lastArrival = arrival
        }
    }

    func setAvailable(_ available: Bool) {
        state.withLock { $0.available = available }
    }

    var tracker: GapTracker { state.withLock { $0.gaps } }

    func snapshot(now: TimeInterval) -> StreamSnapshot {
        state.withLock { s in
            let windowStart = now - id.rateWindow
            let inWindow = s.recent.elements.filter { $0 > windowStart }
            var rate = 0.0
            if inWindow.count >= 2, let f = inWindow.first, let l = inWindow.last, l > f {
                rate = Double(inWindow.count - 1) / (l - f)
            }
            return StreamSnapshot(
                id: id,
                count: s.gaps.count,
                rateHz: rate,
                age: s.lastArrival.map { max(0, now - $0) },
                meanRateHz: s.gaps.meanRateHz,
                maxGap: s.gaps.maxGap,
                gapsOver1s: s.gaps.gapsOver1s,
                droppedEstimate: s.gaps.droppedEstimate,
                available: s.available
            )
        }
    }
}

/// Offline analysis of a session folder from its CSV files (used for recovered sessions and the
/// detail screen). Reads only the first column (`t_up`) of each file.
enum SessionAnalyzer {
    struct Result {
        var streams: [StreamID: GapTracker] = [:]
        var labelsCount = 0
        var fileSizes: [String: Int64] = [:]
        var audioFiles: [String] = []
        var totalBytes: Int64 = 0

        /// Latest sample timestamp (t_up) over all streams.
        var lastSampleUp: Double? { streams.values.compactMap(\.last).max() }

        var durationSec: Double {
            let spans = streams.values.compactMap { t -> (Double, Double)? in
                guard let f = t.first, let l = t.last else { return nil }
                return (f, l)
            }
            guard let start = spans.map(\.0).min(), let end = spans.map(\.1).max() else { return 0 }
            return end - start
        }

        func asStats() -> SessionMetadata.Stats {
            var s: [String: SessionMetadata.StreamStats] = [:]
            for (id, t) in streams {
                s[id.rawValue] = .init(samples: t.count, meanRateHz: t.meanRateHz, maxGapSec: t.maxGap,
                                       gapsOver1s: t.gapsOver1s, droppedEstimate: t.droppedEstimate,
                                       fileBytes: fileSizes[id.file.fileName])
            }
            return .init(durationSec: durationSec, streams: s, labelsCount: labelsCount,
                         audioFiles: audioFiles, fileSizes: fileSizes, totalBytes: totalBytes,
                         writeErrors: 0, uploadBatchesCreated: 0)
        }
    }

    /// MP4/M4A files whose top-level boxes contain no `moov` (index). AVAudioRecorder writes it on
    /// stop(), so the segment being recorded when the app died is unplayable. Pure Foundation.
    static func unplayableAudioFiles(in folder: URL) -> [String] {
        let fm = FileManager.default
        let names = ((try? fm.contentsOfDirectory(atPath: folder.path)) ?? []).filter { $0.hasSuffix(".m4a") }.sorted()
        return names.filter { !hasMoovBox(folder.appendingPathComponent($0)) }
    }

    static func hasMoovBox(_ url: URL) -> Bool {
        guard let h = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? h.close() }
        guard let end = try? h.seekToEnd() else { return false }
        var offset: UInt64 = 0
        while offset + 8 <= end {
            guard (try? h.seek(toOffset: offset)) != nil, let hdr = try? h.read(upToCount: 16), hdr.count >= 8 else { return false }
            let b = [UInt8](hdr)
            var size = UInt64(b[0]) << 24 | UInt64(b[1]) << 16 | UInt64(b[2]) << 8 | UInt64(b[3])
            let type = String(decoding: b[4..<8], as: UTF8.self)
            if type == "moov" { return true }
            if size == 1, b.count >= 16 { // 64-bit largesize
                size = b[8..<16].reduce(0) { $0 << 8 | UInt64($1) }
            } else if size == 0 { // box extends to end of file
                return false
            }
            guard size >= 8 else { return false }
            offset += size
        }
        return false
    }

    static func analyze(folder: URL) -> Result {
        var r = Result()
        let fm = FileManager.default
        if let files = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) {
            for f in files {
                let size = fm.fileSize(f)
                r.fileSizes[f.lastPathComponent] = size
                r.totalBytes += size
                if f.pathExtension == "m4a" { r.audioFiles.append(f.lastPathComponent) }
            }
            r.audioFiles.sort()
        }
        for id in StreamID.allCases {
            let url = folder.appendingPathComponent(id.file.fileName)
            guard fm.fileExists(atPath: url.path) else { continue }
            var tracker = GapTracker(expectedHz: id.expectedHz)
            forEachFirstColumn(url) { tracker.add($0) }
            r.streams[id] = tracker
        }
        let labelsURL = folder.appendingPathComponent(StreamFile.labels.fileName)
        if let text = try? String(contentsOf: labelsURL, encoding: .utf8) {
            r.labelsCount = text.split(separator: "\n").dropFirst().count
        }
        return r
    }

    /// Streams the file (memory-mapped) and parses the first comma-separated field of every data row.
    static func forEachFirstColumn(_ url: URL, _ body: (Double) -> Void) {
        guard let data = try? Data(contentsOf: url, options: .alwaysMapped) else { return }
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            let n = raw.count
            var i = 0
            // skip header line
            while i < n && base[i] != UInt8(ascii: "\n") { i += 1 }
            i += 1
            while i < n {
                let start = i
                while i < n && base[i] != UInt8(ascii: ",") && base[i] != UInt8(ascii: "\n") { i += 1 }
                if i > start, let v = parseDouble(base + start, count: i - start) { body(v) }
                while i < n && base[i] != UInt8(ascii: "\n") { i += 1 }
                i += 1
            }
        }
    }

    private static func parseDouble(_ p: UnsafePointer<UInt8>, count: Int) -> Double? {
        // Swift's Double(String) is locale-independent (unlike strtod).
        guard count < 64 else { return nil }
        let s = String(decoding: UnsafeBufferPointer(start: p, count: count), as: UTF8.self)
        guard let v = Double(s), v.isFinite else { return nil }
        return v
    }
}
