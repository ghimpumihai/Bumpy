import Foundation
import os

/// Minimal lock-protected box. Sensor callbacks arrive on background queues while the UI reads
/// snapshots on the main thread, so every piece of shared mutable state goes through one of these.
final class Locked<Value>: @unchecked Sendable {
    private var value: Value
    private let lock = NSLock()

    init(_ value: Value) { self.value = value }

    @discardableResult
    func withLock<R>(_ body: (inout Value) throws -> R) rethrows -> R {
        lock.lock()
        defer { lock.unlock() }
        return try body(&value)
    }

    var current: Value { withLock { $0 } }
}

/// Fixed-capacity ring buffer (overwrites the oldest element). Not thread-safe by itself.
struct RingBuffer<Element> {
    private var storage: [Element?]
    private var head = 0          // index of the next write
    private(set) var count = 0
    let capacity: Int

    init(capacity: Int) {
        precondition(capacity > 0)
        self.capacity = capacity
        storage = Array(repeating: nil, count: capacity)
    }

    mutating func append(_ element: Element) {
        storage[head] = element
        head = (head + 1) % capacity
        count = Swift.min(count + 1, capacity)
    }

    mutating func removeAll() {
        storage = Array(repeating: nil, count: capacity)
        head = 0
        count = 0
    }

    /// Elements from oldest to newest.
    var elements: [Element] {
        var out: [Element] = []
        out.reserveCapacity(count)
        let start = (head - count + capacity) % capacity
        for i in 0..<count {
            if let e = storage[(start + i) % capacity] { out.append(e) }
        }
        return out
    }

    var last: Element? {
        guard count > 0 else { return nil }
        return storage[(head - 1 + capacity) % capacity]
    }
}

struct Vec3: Equatable, Codable, Sendable {
    var x: Double
    var y: Double
    var z: Double

    static let zero = Vec3(x: 0, y: 0, z: 0)

    func dot(_ o: Vec3) -> Double { x * o.x + y * o.y + z * o.z }
    var norm: Double { (x * x + y * y + z * z).squareRoot() }
    static func - (a: Vec3, b: Vec3) -> Vec3 { Vec3(x: a.x - b.x, y: a.y - b.y, z: a.z - b.z) }
    static func + (a: Vec3, b: Vec3) -> Vec3 { Vec3(x: a.x + b.x, y: a.y + b.y, z: a.z + b.z) }
    static func * (a: Vec3, s: Double) -> Vec3 { Vec3(x: a.x * s, y: a.y * s, z: a.z * s) }
    var normalized: Vec3 { let n = norm; return n > 0 ? self * (1 / n) : self }
}

enum ISO8601 {
    /// `2026-11-21T09:12:03.512Z`
    static func string(_ date: Date) -> String {
        formatter.string(from: date)
    }

    static func date(_ string: String) -> Date? {
        formatter.date(from: string) ?? plainFormatter.date(from: string)
    }

    /// Folder-safe timestamp: `2026-11-21T09-12-03Z`
    static func folderStamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd'T'HH-mm-ss'Z'"
        return f.string(from: date)
    }

    private static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    private static let plainFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
}

enum ByteFormat {
    static func string(_ bytes: Int64) -> String {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowedUnits = [.useKB, .useMB, .useGB]
        return f.string(fromByteCount: bytes)
    }
}

enum DurationFormat {
    /// `01:23:41` (or `23:41` when under one hour if `compact`)
    static func hms(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds.rounded(.down)))
        return String(format: "%02d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
    }
}

extension FileManager {
    /// Total size of all regular files below `url` (recursive).
    func allocatedSize(ofDirectory url: URL) -> Int64 {
        guard let en = enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in en {
            let v = try? file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            if v?.isRegularFile == true { total += Int64(v?.fileSize ?? 0) }
        }
        return total
    }

    func fileSize(_ url: URL) -> Int64 {
        (try? attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
    }

    /// Free space usable for "important" data (what the system would free up for us).
    func freeDiskBytes() -> Int64 {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        if let v = try? home.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
           let cap = v.volumeAvailableCapacityForImportantUsage {
            return cap
        }
        if let attrs = try? attributesOfFileSystem(forPath: NSHomeDirectory()),
           let free = attrs[.systemFreeSize] as? NSNumber {
            return free.int64Value
        }
        return -1
    }
}

let appLogger = Logger(subsystem: "com.chuds.sensorrecorder", category: "app")
