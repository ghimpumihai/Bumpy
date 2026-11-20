import Foundation

/// Lists, creates and recovers session folders under `Documents/sessions/`.
struct SessionStore: Sendable {
    let root: URL

    static var documentsDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    static var `default`: SessionStore {
        SessionStore(root: documentsDirectory.appendingPathComponent("sessions", isDirectory: true))
    }

    static func shortId(_ id: UUID) -> String {
        String(id.uuidString.lowercased().prefix(4))
    }

    static func folderName(start: Date, id: UUID) -> String {
        "\(ISO8601.folderStamp(start))_\(shortId(id))"
    }

    func ensureRoot() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func makeSessionFolder(start: Date, id: UUID) throws -> URL {
        try ensureRoot()
        let url = root.appendingPathComponent(Self.folderName(start: start, id: id), isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    struct Entry: Identifiable, Equatable {
        var id: String { folder.lastPathComponent }
        let folder: URL
        let metadata: SessionMetadata?
        let sizeBytes: Int64
        let lastModified: Date?

        var startedAt: Date? { metadata.flatMap { ISO8601.date($0.startedAtUtc) } }
        var endedAt: Date? { metadata?.endedAtUtc.flatMap { ISO8601.date($0) } }
        var isRecovered: Bool { metadata?.recovered ?? false }
        var isUnreadable: Bool { metadata == nil }

        var durationSec: TimeInterval? {
            if let s = metadata?.stats?.durationSec { return s }
            guard let start = startedAt else { return nil }
            if let end = endedAt { return end.timeIntervalSince(start) }
            if let mod = lastModified { return max(0, mod.timeIntervalSince(start)) }
            return nil
        }
    }

    func list() -> [Entry] {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey]) else { return [] }
        return items
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .map { entry(for: $0) }
            .sorted { $0.folder.lastPathComponent > $1.folder.lastPathComponent } // newest first (name starts with UTC stamp)
    }

    func entry(for folder: URL) -> Entry {
        let fm = FileManager.default
        let meta = try? SessionMetadata.load(from: folder.appendingPathComponent(SessionFileName.metadata))
        let size = fm.allocatedSize(ofDirectory: folder)
        let lastMod = latestModification(in: folder)
        return Entry(folder: folder, metadata: meta, sizeBytes: size, lastModified: lastMod)
    }

    private func latestModification(in folder: URL) -> Date? {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey]) else { return nil }
        return files.compactMap { try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }.max()
    }

    /// Spec §4: on launch, any session folder whose `session.json` lacks `endedAtUtc` was interrupted
    /// (crash, kill, battery). Mark it `recovered: true`, repair torn last lines in CSVs, fill stats from
    /// the files, and keep it. `excluding` protects a session that is currently recording.
    @discardableResult
    func recoverUnfinishedSessions(excluding active: URL? = nil, now: Date = Date()) -> [URL] {
        var recovered: [URL] = []
        for e in list() {
            guard e.folder.standardizedFileURL != active?.standardizedFileURL,
                  var meta = e.metadata,
                  meta.endedAtUtc == nil,
                  !meta.recovered else { continue }
            let repairs = CSVRepair.repairTornLines(in: e.folder)
            meta.recovered = true
            meta.recoveredAtUtc = ISO8601.string(now)
            let analysis = SessionAnalyzer.analyze(folder: e.folder)
            meta.stats = analysis.asStats()
            do {
                try meta.write(to: e.folder.appendingPathComponent(SessionFileName.metadata))
                appendRecoveryNote(folder: e.folder, repairs: repairs, now: now)
                recovered.append(e.folder)
            } catch {
                appLogger.error("recovery of \(e.folder.lastPathComponent, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        return recovered
    }

    private func appendRecoveryNote(folder: URL, repairs: [String: Int], now: Date) {
        let url = folder.appendingPathComponent(SessionFileName.appLog)
        var text = "\(ISO8601.string(now)) [WARN] session recovered on next launch (app was terminated while recording)\n"
        for (file, bytes) in repairs.sorted(by: { $0.key < $1.key }) {
            text += "\(ISO8601.string(now)) [WARN] recovery: trimmed \(bytes) bytes of incomplete last line from \(file)\n"
        }
        if let h = try? FileHandle(forWritingTo: url) {
            _ = try? h.seekToEnd()
            try? h.write(contentsOf: Data(text.utf8))
            try? h.close()
        } else {
            try? Data(text.utf8).write(to: url)
        }
    }
}

enum CSVRepair {
    /// If a CSV does not end with a newline (process died mid-write), truncate the incomplete last
    /// line so every parser can read the file. Returns trimmed byte counts per file.
    @discardableResult
    static func repairTornLines(in folder: URL) -> [String: Int] {
        var out: [String: Int] = [:]
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { return out }
        for url in files where url.pathExtension == "csv" {
            if let trimmed = try? repairTornLine(url), trimmed > 0 { out[url.lastPathComponent] = trimmed }
        }
        return out
    }

    /// Returns the number of bytes trimmed (0 if the file was fine).
    static func repairTornLine(_ url: URL) throws -> Int {
        let h = try FileHandle(forUpdating: url)
        defer { try? h.close() }
        let size = try h.seekToEnd()
        guard size > 0 else { return 0 }
        // Scan backwards in chunks for the last '\n'.
        let chunk: UInt64 = 64 * 1024
        var pos = size
        var lastNewline: UInt64?
        var first = true
        while pos > 0, lastNewline == nil {
            let start = pos > chunk ? pos - chunk : 0
            try h.seek(toOffset: start)
            let data = try h.read(upToCount: Int(pos - start)) ?? Data()
            if first {
                if data.last == UInt8(ascii: "\n") { return 0 }
                first = false
            }
            if let idx = data.lastIndex(of: UInt8(ascii: "\n")) {
                lastNewline = start + UInt64(idx - data.startIndex)
            }
            pos = start
        }
        let newSize = lastNewline.map { $0 + 1 } ?? 0
        try h.truncate(atOffset: newSize)
        return Int(size - newSize)
    }
}
