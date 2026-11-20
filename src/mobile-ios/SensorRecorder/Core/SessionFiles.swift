import Foundation

/// Every CSV in a session folder, with its exact header (spec §4). This is the single source of
/// truth for the on-disk schema; the backend parses by header name.
enum StreamFile: String, CaseIterable, Sendable {
    case deviceMotion = "device_motion"
    case accelRaw = "accel_raw"
    case gyroRaw = "gyro_raw"
    case magRaw = "mag_raw"
    case location
    case heading
    case altimeter
    case absAltitude = "abs_altitude"
    case activity
    case audioLevel = "audio_level"
    case audioSegments = "audio_segments"
    case device
    case labels
    case clock

    var fileName: String { rawValue + ".csv" }

    static let commonColumns = ["t_up", "t_utc_ms"]

    var columns: [String] {
        switch self {
        case .deviceMotion:
            return ["ua_x", "ua_y", "ua_z", "g_x", "g_y", "g_z", "rr_x", "rr_y", "rr_z",
                    "q_w", "q_x", "q_y", "q_z", "roll", "pitch", "yaw"]
        case .accelRaw, .gyroRaw, .magRaw:
            return ["x", "y", "z"]
        case .location:
            return ["lat", "lon", "alt", "ell_alt", "h_acc", "v_acc", "speed", "speed_acc",
                    "course", "course_acc", "is_simulated"]
        case .heading:
            return ["mag_heading", "true_heading", "heading_acc", "x", "y", "z"]
        case .altimeter:
            return ["rel_alt_m", "pressure_kpa"]
        case .absAltitude:
            return ["altitude_m", "accuracy_m", "precision_m"]
        case .activity:
            // `start_utc_ms` (CMMotionActivity.startDate) is appended after the spec columns.
            return ["stationary", "walking", "running", "automotive", "cycling", "unknown",
                    "confidence", "start_utc_ms"]
        case .audioLevel:
            return ["avg_dbfs", "peak_dbfs"]
        case .audioSegments:
            // One row per audio file event; `file` is relative to the session folder.
            return ["event", "file"]
        case .device:
            return ["battery_level", "battery_state", "thermal_state", "low_power",
                    "free_disk_bytes", "net_status", "net_type"]
        case .labels:
            return ["type", "value", "note"]
        case .clock:
            return ["source"]
        }
    }

    var header: String { (Self.commonColumns + columns).joined(separator: ",") }
}

enum SessionFileName {
    static let metadata = "session.json"
    static let appLog = "app_log.txt"
    static let mountPhoto = "mount.jpg"
    static func audioSegment(_ index: Int) -> String { String(format: "audio_%03d.m4a", index) }
}

/// Append-only, buffered text file. `append` is cheap and thread-safe (called from sensor queues);
/// `flush` must only be called from the owner's serial writer queue.
final class BufferedFileWriter: @unchecked Sendable {
    let url: URL
    private let handle: FileHandle
    private let pending = Locked(String())
    /// Bytes that failed to write last time (e.g. disk full). Retried first on the next flush.
    private var retryData = Data()
    private let stats = Locked((bytes: Int64(0), lines: Int64(0)))
    private var closed = false

    /// Hard cap for data held in memory per file while the disk refuses writes (prevents OOM:
    /// ~15 writers × 4 MB worst case).
    static let maxRetryBytes = 4 * 1024 * 1024
    /// Whether the bytes on disk end with a complete line.
    private var diskEndsWithNewline = true

    /// Creates the file (must not exist) and writes `header` synchronously.
    init(url: URL, header: String?) throws {
        self.url = url
        let fm = FileManager.default
        guard !fm.fileExists(atPath: url.path) else {
            throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: url.path])
        }
        let initial = header.map { Data(($0 + "\n").utf8) } ?? Data()
        guard fm.createFile(atPath: url.path, contents: initial) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
        }
        handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        stats.withLock { $0.bytes = Int64(initial.count) }
    }

    func append(line: String) {
        pending.withLock {
            $0.append(line)
            $0.append("\n")
        }
        stats.withLock { $0.lines += 1 }
    }

    /// Bytes on disk so far (excluding what is still buffered).
    var bytesWritten: Int64 { stats.current.bytes }
    var linesAppended: Int64 { stats.current.lines }

    /// Writes everything buffered so far. Throws on I/O errors; the unwritten data is kept for retry.
    func flush() throws {
        guard !closed else { return }
        let chunk = pending.withLock { buf -> String in
            let out = buf
            buf = String()
            buf.reserveCapacity(out.utf8.count)
            return out
        }
        var data = retryData
        data.append(contentsOf: chunk.utf8)
        guard !data.isEmpty else { return }
        let before = (try? handle.offset()) ?? 0
        do {
            try handle.write(contentsOf: data)
            retryData.removeAll(keepingCapacity: true)
            diskEndsWithNewline = data.last == UInt8(ascii: "\n")
            stats.withLock { $0.bytes += Int64(data.count) }
        } catch {
            // A failed write may still have written a prefix: never write those bytes twice.
            let after = (try? handle.offset()) ?? before
            let written = after > before ? Int(min(UInt64(data.count), after - before)) : 0
            if written > 0 {
                diskEndsWithNewline = data[data.startIndex + written - 1] == UInt8(ascii: "\n")
                stats.withLock { $0.bytes += Int64(written) }
            }
            var rest = Data(data.dropFirst(written))
            if rest.count > Self.maxRetryBytes {
                // Drop the oldest *whole lines* only, so the retained data starts at a row boundary.
                let cut = rest.count - Self.maxRetryBytes
                if let nl = rest[(rest.startIndex + cut)...].firstIndex(of: UInt8(ascii: "\n")) {
                    rest = Data(rest[(nl + 1)...])
                } else {
                    rest = Data()
                }
                // If the disk currently ends mid-row, terminate that row before the retained rows.
                if !diskEndsWithNewline { rest.insert(UInt8(ascii: "\n"), at: 0) }
            }
            retryData = rest
            throw error
        }
    }

    /// fsync — pushes the kernel page cache to flash. Costly; call rarely.
    func synchronize() throws {
        guard !closed else { return }
        try handle.synchronize()
    }

    func close() throws {
        guard !closed else { return }
        defer { closed = true; try? handle.close() }
        try flush()
        try handle.synchronize()
    }
}

/// Owns every CSV writer of one session plus `app_log.txt`, and flushes them on one serial queue
/// every 0.5 s (spec: at least every 1 s, so a crash loses < 1 s).
final class SessionWriter: @unchecked Sendable {
    let folder: URL
    private var writers: [StreamFile: BufferedFileWriter] = [:]
    private let logWriter: BufferedFileWriter
    let queue = DispatchQueue(label: "sensorrecorder.writer", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var flushCount = 0
    private let errorState = Locked<(count: Int, last: String?, lastAtUp: TimeInterval?)>((0, nil, nil))
    private let uptime: () -> TimeInterval
    /// Called (on the writer queue) whenever a flush fails.
    var onWriteError: ((String) -> Void)?

    static let flushInterval: TimeInterval = 0.5
    static let fsyncEveryNFlushes = 20 // ~10 s

    init(folder: URL, files: [StreamFile] = StreamFile.allCases,
         uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) throws {
        self.folder = folder
        self.uptime = uptime
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for f in files {
            writers[f] = try BufferedFileWriter(url: folder.appendingPathComponent(f.fileName), header: f.header)
        }
        logWriter = try BufferedFileWriter(url: folder.appendingPathComponent(SessionFileName.appLog), header: nil)
    }

    func start() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + Self.flushInterval, repeating: Self.flushInterval, leeway: .milliseconds(50))
        t.setEventHandler { [weak self] in self?.flushAll(sync: false) }
        timer = t
        t.resume()
    }

    func append(_ file: StreamFile, _ line: String) {
        writers[file]?.append(line: line)
    }

    /// Timestamped line in `app_log.txt`, mirrored to the unified log.
    func log(_ level: LogLevel, _ message: String) {
        let up = uptime()
        let line = "\(ISO8601.string(Date())) t_up=\(CSV.f6(up)) [\(level.rawValue)] \(message)"
        logWriter.append(line: line)
        switch level {
        case .error, .problem: appLogger.error("\(message, privacy: .public)")
        case .warn: appLogger.warning("\(message, privacy: .public)")
        default: appLogger.info("\(message, privacy: .public)")
        }
    }

    var writeErrors: (count: Int, last: String?, lastAtUp: TimeInterval?) { errorState.current }

    func bytesWritten(_ file: StreamFile) -> Int64 { writers[file]?.bytesWritten ?? 0 }
    var totalCSVBytes: Int64 { writers.values.reduce(0) { $0 + $1.bytesWritten } + logWriter.bytesWritten }
    func fileBytes() -> [String: Int64] {
        var out: [String: Int64] = [:]
        for (k, w) in writers { out[k.fileName] = w.bytesWritten }
        out[SessionFileName.appLog] = logWriter.bytesWritten
        return out
    }

    private func flushAll(sync: Bool) {
        dispatchPrecondition(condition: .onQueue(queue))
        flushCount += 1
        let doSync = sync || flushCount % Self.fsyncEveryNFlushes == 0
        for (file, w) in writers {
            do {
                try w.flush()
                if doSync { try w.synchronize() }
            } catch {
                recordError("flush \(file.fileName) failed: \(error.localizedDescription)")
            }
        }
        do { try logWriter.flush() } catch { recordError("flush app_log.txt failed: \(error.localizedDescription)") }
    }

    private func recordError(_ msg: String) {
        let now = uptime()
        errorState.withLock { $0.count += 1; $0.last = msg; $0.lastAtUp = now }
        onWriteError?(msg)
    }

    /// Synchronous flush of everything buffered so far (used before rewriting session.json etc.).
    func flushNow() {
        queue.sync { flushAll(sync: true) }
    }

    /// Final flush + fsync + close. Idempotent.
    func close() {
        queue.sync {
            timer?.cancel()
            timer = nil
            for (file, w) in writers {
                do { try w.close() } catch { recordError("close \(file.fileName) failed: \(error.localizedDescription)") }
            }
            try? logWriter.close()
        }
    }
}

enum LogLevel: String, Sendable {
    case info = "INFO"
    case warn = "WARN"
    case problem = "PROBLEM"
    case error = "ERROR"
}
