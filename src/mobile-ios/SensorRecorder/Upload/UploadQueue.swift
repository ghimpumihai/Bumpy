import Foundation
import UIKit

protocol HTTPTransport: Sendable {
    /// Returns the HTTP status code. Throws on transport errors (no connectivity, timeout, TLS…).
    func send(_ request: URLRequest) async throws -> Int
}

struct URLSessionTransport: HTTPTransport {
    let session: URLSession

    init() {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 15
        cfg.timeoutIntervalForResource = 30
        cfg.waitsForConnectivity = false
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.httpShouldSetCookies = false
        session = URLSession(configuration: cfg, delegate: NoRedirects.shared, delegateQueue: nil)
    }

    /// Never follow redirects: a 307/308 would re-send the body *and the x-device-key header*
    /// to another host. The redirect response is returned as-is (3xx → retried, logged).
    final class NoRedirects: NSObject, URLSessionTaskDelegate {
        static let shared = NoRedirects()
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }

    func send(_ request: URLRequest) async throws -> Int {
        let (_, response) = try await session.data(for: request)
        return (response as? HTTPURLResponse)?.statusCode ?? -1
    }
}

struct UploadStatus: Equatable, Sendable {
    var enabled = false
    var queueCount = 0
    var failedCount = 0
    var uploadedCount = 0
    var lastSuccessUp: TimeInterval?
    var lastAttemptUp: TimeInterval?
    var lastError: String?
    var currentBackoff: TimeInterval = 0
    var enabledSinceUp: TimeInterval?
}

/// Disk-backed upload queue (spec §6).
///
/// - Each batch is a `.json.gz` file in `Documents/upload_queue/`, named
///   `<createdUtcMs>_<sessionId>_<batchSeq>.json.gz` so lexical order = oldest first. The `createdMs`
///   in a name is strictly increasing per queue (a wall clock that steps back can't reorder files).
/// - One request at a time, oldest first, never re-ordered. Exponential backoff 1 s → 30 s on failure.
/// - 2xx and 409 (duplicate) → delete. 408/429/5xx/network → retry the same file (the backend answers
///   503 only for its own outages, never for a bad payload, so an outage must not park or re-order
///   anything). 401/403 and batch 404 → retry (a config error must not dump the queue into
///   `upload_failed/`). Session metadata 404/405 (no PUT route) → retried for a while, then set aside.
///   Other 4xx → move to `upload_failed/`.
/// - A file that can't be sent at all (a name we didn't write, e.g. a Files-app copy, or unreadable)
///   is moved to `upload_failed/` so it never blocks the queue.
/// - Idempotency key = `sessionId:batchSeq` (also inside the body).
/// - Every 2xx/409 is recorded in `upload_acked/<sessionId>.txt` before the queue file is deleted,
///   so the app knows which parts of a trip reached the cloud (Recap, delete guard; D56).
final class UploadQueue: Sendable {
    enum Outcome: Equatable {
        case uploaded(status: Int)
        case duplicate
        case permanentFailure(status: Int)
        case retry(reason: String)
        /// No request was made for the head file: it vanished, or it could not be read and was moved
        /// to `upload_failed/`. The next file goes next.
        case skipped(reason: String)
        case disabled
        case empty
    }

    let directory: URL
    let failedDirectory: URL
    let ackedDirectory: URL
    private let transport: HTTPTransport
    private let configProvider: @Sendable () -> UploadConfig
    private let uptime: @Sendable () -> TimeInterval
    private let statusBox = Locked(UploadStatus())
    private let kickFlag = Locked(false)
    private let loopTask = Locked<Task<Void, Never>?>(nil)

    /// Session metadata answered 404/405 (backend without the PUT route, or a redeploy in progress)
    /// this many times in a row is set aside in `upload_failed/`, so it never blocks the batches for
    /// good. With the 1 → 30 s backoff that is about two minutes of retries.
    static let maxMetadataNotFoundAttempts = 8
    private let notFoundAttempts = Locked<(name: String, count: Int)>(("", 0))

    /// Files that were sent (or rejected) but could not be deleted (or moved to `upload_failed/`).
    /// They are skipped instead of re-sent in a tight loop, and the delete/move is retried on every
    /// pass. In memory only: after a relaunch such a file is sent once more (harmless, idempotent).
    private enum Leftover { case delete, moveToFailed }
    private let leftovers = Locked<[String: Leftover]>([:])

    /// Last `createdMs` used in a file name; names are strictly increasing so send order = enqueue
    /// order even when the wall clock steps back between two enqueues (spec §6.1 ordering).
    private let lastNamedMs: Locked<Int64>

    /// Keeps the app running in the background after Stop until the queue is empty (the sensors no
    /// longer keep it alive, so the Stop copy and the backlog would otherwise wait for the next launch).
    private let backgroundTime: BackgroundTimeProvider?
    private let backgroundHeld = Locked(false)

    /// Writes one queue file. Atomic (temp + rename) so a half-written file is never uploaded;
    /// injectable so tests can make an enqueue fail deterministically (full disk).
    typealias FileWriter = @Sendable (Data, URL) throws -> Void
    static let atomicWrite: FileWriter = { data, url in try data.write(to: url, options: .atomic) }
    private let writeFile: FileWriter

    static let minBackoff: TimeInterval = 1
    static let maxBackoff: TimeInterval = 30

    typealias EventHandler = @Sendable (LogLevel, String) -> Void
    private let eventHandler = Locked<EventHandler?>(nil)
    /// Set by the app after init; read from the upload loop's thread.
    var onEvent: EventHandler? {
        get { eventHandler.current }
        set { eventHandler.withLock { $0 = newValue } }
    }

    init(directory: URL, transport: HTTPTransport = URLSessionTransport(),
         uptime: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         backgroundTime: BackgroundTimeProvider? = UIKitBackgroundTime(),
         writeFile: @escaping FileWriter = UploadQueue.atomicWrite,
         config: @escaping @Sendable () -> UploadConfig) {
        self.directory = directory
        failedDirectory = directory.deletingLastPathComponent().appendingPathComponent("upload_failed", isDirectory: true)
        ackedDirectory = directory.deletingLastPathComponent().appendingPathComponent("upload_acked", isDirectory: true)
        self.transport = transport
        self.configProvider = config
        self.uptime = uptime
        self.backgroundTime = backgroundTime
        self.writeFile = writeFile
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: failedDirectory, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: ackedDirectory, withIntermediateDirectories: true)
        let existing = Self.queueFileNames(in: directory).compactMap { Self.parseItem(fileName: $0)?.createdMs }
        lastNamedMs = Locked(existing.max() ?? 0)
        refreshCounts()
    }

    static var defaultDirectory: URL {
        SessionStore.documentsDirectory.appendingPathComponent("upload_queue", isDirectory: true)
    }

    var status: UploadStatus { statusBox.current }

    /// Upload configured right now (API URL set).
    var isEnabled: Bool { configProvider().isEnabled }

    // MARK: Enqueue

    /// What a queue file carries (spec §6 batches, §6.1 session metadata).
    enum Item: Equatable {
        case batch(seq: Int)
        case sessionMeta(phase: MetaPhase)
    }

    enum MetaPhase: String, Equatable { case start, stop }

    struct QueueFile: Equatable {
        let createdMs: Int64
        let sessionId: String
        let item: Item
        var idempotencyKey: String {
            switch item {
            case .batch(let seq): return "\(sessionId):\(seq)"
            case .sessionMeta(let phase): return "\(sessionId):meta-\(phase.rawValue)"
            }
        }
    }

    /// `<createdMs:13>_<sessionId>_<seq:7>.json.gz` for batches, `<createdMs:13>_<sessionId>_meta-<phase>.json.gz`
    /// for session metadata. Lexical order = send order: created time first (strictly increasing per
    /// queue, see `nextCreatedMs`); at an equal millisecond a batch (digits) sorts before metadata ("m").
    static func fileName(createdUtcMs: Int64, sessionId: String, item: Item) -> String {
        let suffix: String
        switch item {
        case .batch(let seq): suffix = String(format: "%07d", seq)
        case .sessionMeta(let phase): suffix = "meta-" + phase.rawValue
        }
        return String(format: "%013lld", createdUtcMs) + "_" + sessionId + "_" + suffix + ".json.gz"
    }

    static func fileName(createdUtcMs: Int64, sessionId: String, seq: Int) -> String {
        fileName(createdUtcMs: createdUtcMs, sessionId: sessionId, item: .batch(seq: seq))
    }

    static func parseItem(fileName: String) -> QueueFile? {
        guard fileName.hasSuffix(".json.gz") else { return nil }
        let stem = fileName.dropLast(".json.gz".count)
        let parts = stem.split(separator: "_")
        guard parts.count == 3, let ms = Int64(parts[0]) else { return nil }
        let tail = String(parts[2])
        if let seq = Int(tail) { return QueueFile(createdMs: ms, sessionId: String(parts[1]), item: .batch(seq: seq)) }
        if tail.hasPrefix("meta-"), let phase = MetaPhase(rawValue: String(tail.dropFirst("meta-".count))) {
            return QueueFile(createdMs: ms, sessionId: String(parts[1]), item: .sessionMeta(phase: phase))
        }
        return nil
    }

    /// Batch files only (nil for metadata files).
    static func parse(fileName: String) -> (createdMs: Int64, sessionId: String, seq: Int)? {
        guard let f = parseItem(fileName: fileName), case .batch(let seq) = f.item else { return nil }
        return (f.createdMs, f.sessionId, seq)
    }

    /// The millisecond for the next file name: the requested wall-clock time, but always after the
    /// previous name, so a clock step back can't sort the Stop copy before the last batch (or batch 0
    /// before the Start copy).
    private func nextCreatedMs(_ requested: Int64) -> Int64 {
        lastNamedMs.withLock { last in
            last = max(requested, last + 1)
            return last
        }
    }

    /// Queues the session metadata (§6.1): `PUT /api/ingest/sessions/{id}` with the gzipped JSON body.
    /// The Stop copy also asks iOS for background time until the queue is empty, and wakes the loop.
    func enqueueSessionMetadata(json: Data, sessionId: String, phase: MetaPhase, createdUtcMs: Int64) throws {
        let name = Self.fileName(createdUtcMs: nextCreatedMs(createdUtcMs), sessionId: sessionId, item: .sessionMeta(phase: phase))
        try writeFile(Gzip.compress(json), directory.appendingPathComponent(name))
        statusBox.withLock { $0.queueCount += 1 }
        if phase == .stop {
            holdBackgroundTimeUntilDrained()
            kick()
        }
    }

    /// Writes the gzipped batch atomically (temp + rename): a half-written file is never uploaded.
    func enqueue(gzippedBody: Data, sessionId: String, seq: Int, createdUtcMs: Int64) throws {
        let name = Self.fileName(createdUtcMs: nextCreatedMs(createdUtcMs), sessionId: sessionId, seq: seq)
        try writeFile(gzippedBody, directory.appendingPathComponent(name))
        statusBox.withLock { $0.queueCount += 1 }
    }

    func enqueue(batch: IngestBatch, createdUtcMs: Int64) throws {
        let gz = try Gzip.compress(try batch.jsonData())
        try enqueue(gzippedBody: gz, sessionId: batch.sessionId, seq: batch.batchSeq, createdUtcMs: createdUtcMs)
    }

    private static func queueFileNames(in dir: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.hasSuffix(".json.gz") }
    }

    /// Files waiting to be sent, in send order. Only names this queue wrote (a Files-app copy such as
    /// `…_0000042 2.json.gz` is not ours and never becomes the head) and not already sent.
    func pendingFiles() -> [URL] {
        let skip = leftovers.current
        return Self.queueFileNames(in: directory)
            .filter { Self.parseItem(fileName: $0) != nil && skip[$0] == nil }
            .sorted().map { directory.appendingPathComponent($0) }
    }

    func failedCount(sessionId: String) -> Int {
        failedFiles().filter { Self.parseItem(fileName: $0.lastPathComponent)?.sessionId == sessionId }.count
    }

    /// Trips with anything still queued (batches or metadata), for Settings' "2 trips waiting".
    func waitingTripCount() -> Int {
        Set(pendingFiles().compactMap { Self.parseItem(fileName: $0.lastPathComponent)?.sessionId }).count
    }

    func failedFiles() -> [URL] {
        Self.queueFileNames(in: failedDirectory).sorted().map { failedDirectory.appendingPathComponent($0) }
    }

    func refreshCounts() {
        let q = pendingFiles().count
        let f = failedFiles().count
        statusBox.withLock { $0.queueCount = q; $0.failedCount = f }
    }

    /// Moves everything in `upload_failed/` back into the queue (operator action).
    func requeueFailed() {
        for f in failedFiles() {
            try? FileManager.default.moveItem(at: f, to: directory.appendingPathComponent(f.lastPathComponent))
        }
        refreshCounts()
        kick()
    }

    // MARK: Acknowledged parts (D56)

    /// Where one trip stands in the upload, from the queue, `upload_failed/` and the ack record.
    struct TripState: Equatable, Sendable {
        var pendingBatches = 0
        var failedBatches = 0
        var acknowledgedBatches: Set<Int> = []
        var stopPending = false
        var stopFailed = false
        var stopAcknowledged = false
        /// Anything of this trip still queued or in `upload_failed/` (batches or metadata).
        var pendingItems = 0
        var failedItems = 0
    }

    func tripState(sessionId: String) -> TripState {
        var s = TripState()
        for f in pendingFiles() {
            guard let q = Self.parseItem(fileName: f.lastPathComponent), q.sessionId == sessionId else { continue }
            s.pendingItems += 1
            switch q.item {
            case .batch: s.pendingBatches += 1
            case .sessionMeta(let phase): if phase == .stop { s.stopPending = true }
            }
        }
        for f in failedFiles() {
            guard let q = Self.parseItem(fileName: f.lastPathComponent), q.sessionId == sessionId else { continue }
            s.failedItems += 1
            switch q.item {
            case .batch: s.failedBatches += 1
            case .sessionMeta(let phase): if phase == .stop { s.stopFailed = true }
            }
        }
        let acked = acknowledged(sessionId: sessionId)
        s.acknowledgedBatches = acked.batches
        s.stopAcknowledged = acked.stop
        return s
    }

    private func ackFile(_ sessionId: String) -> URL {
        ackedDirectory.appendingPathComponent(sessionId + ".txt")
    }

    /// One line per acknowledged item (`<batchSeq>` or `meta-start|stop`). Appending the same item
    /// again (a re-send after a relaunch) is harmless.
    private func recordAcknowledged(_ file: QueueFile) {
        let line: String
        switch file.item {
        case .batch(let seq): line = "\(seq)\n"
        case .sessionMeta(let phase): line = "meta-\(phase.rawValue)\n"
        }
        let url = ackFile(file.sessionId)
        do {
            if !FileManager.default.fileExists(atPath: url.path) {
                try Data().write(to: url)
            }
            let h = try FileHandle(forWritingTo: url)
            defer { try? h.close() }
            try h.seekToEnd()
            try h.write(contentsOf: Data(line.utf8))
        } catch {
            // Safe direction: the trip just can't be shown as complete or deleted in the app.
            onEvent?(.warn, "upload: could not record that \(file.idempotencyKey) was accepted: \(error.localizedDescription)")
        }
    }

    func acknowledged(sessionId: String) -> (batches: Set<Int>, stop: Bool) {
        guard let text = try? String(contentsOf: ackFile(sessionId), encoding: .utf8) else { return ([], false) }
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        lines.removeLast() // empty after the final newline, or a line still being written
        return (Set(lines.compactMap { Int($0) }), lines.contains("meta-stop"))
    }

    /// After the trip's folder was deleted.
    func forgetAcknowledged(sessionId: String) {
        try? FileManager.default.removeItem(at: ackFile(sessionId))
    }

    // MARK: Processing

    func makeRequest(for file: QueueFile, body: Data, config: UploadConfig) throws -> URLRequest {
        let url: URL?
        let method: String
        switch file.item {
        case .batch: url = config.ingestURL; method = "POST"
        case .sessionMeta: url = config.sessionURL(file.sessionId); method = "PUT"
        }
        guard let url else { throw URLError(.badURL) }
        var r = URLRequest(url: url)
        r.httpMethod = method
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.setValue("gzip", forHTTPHeaderField: "Content-Encoding")
        r.setValue(config.deviceKey, forHTTPHeaderField: "x-device-key")
        r.setValue(file.idempotencyKey, forHTTPHeaderField: "x-idempotency-key")
        r.httpBody = body
        r.timeoutInterval = 15
        return r
    }

    /// Uploads the oldest queued file once. Deterministic and unit-tested; the loop calls it.
    func processOnce() async -> Outcome {
        let config = configProvider()
        let now = uptime()
        statusBox.withLock {
            if config.isEnabled && !$0.enabled { $0.enabledSinceUp = now }
            if !config.isEnabled { $0.enabledSinceUp = nil }
            $0.enabled = config.isEnabled
        }
        guard config.isEnabled else {
            releaseBackgroundTime()
            return .disabled
        }
        finishLeftovers()
        setAsideForeignFiles()
        guard let file = pendingFiles().first, let item = Self.parseItem(fileName: file.lastPathComponent) else {
            statusBox.withLock { $0.queueCount = 0 }
            releaseBackgroundTime()
            return .empty
        }
        let name = file.lastPathComponent
        statusBox.withLock { $0.lastAttemptUp = now }

        let body: Data
        do {
            body = try Data(contentsOf: file)
        } catch {
            // Gone (cleared while we looked) → nothing to do. Unreadable → never let it block the queue.
            guard FileManager.default.fileExists(atPath: file.path) else {
                refreshCounts()
                return .skipped(reason: "\(name) is gone")
            }
            let reason = "could not read \(name): \(error.localizedDescription)"
            if moveToFailed(name) {
                onEvent?(.warn, "upload: \(reason), moved to upload_failed/")
            } else {
                leftovers.withLock { $0[name] = .moveToFailed }
                onEvent?(.warn, "upload: \(reason); could not move it to upload_failed/ either, skipping it")
            }
            refreshCounts()
            return .skipped(reason: reason)
        }

        let isMeta: Bool = { if case .sessionMeta = item.item { return true }; return false }()
        let outcome: Outcome
        do {
            let code = try await transport.send(try makeRequest(for: item, body: body, config: config))
            outcome = classify(status: code, isMeta: isMeta, name: name)
        } catch {
            outcome = .retry(reason: (error as? URLError).map { "network: \($0.code.rawValue)" } ?? error.localizedDescription)
        }
        if case .retry = outcome {} else { notFoundAttempts.withLock { $0 = ("", 0) } }

        switch outcome {
        case .uploaded, .duplicate:
            recordAcknowledged(item)
            do { try FileManager.default.removeItem(at: file) } catch {
                // Skip it from now on (no hot loop re-sending it) and keep trying to delete it.
                leftovers.withLock { $0[name] = .delete }
                onEvent?(.warn, "upload: sent \(name) but could not delete it: \(error.localizedDescription)")
            }
            statusBox.withLock {
                $0.uploadedCount += 1
                $0.lastSuccessUp = self.uptime()
                $0.lastError = nil
                $0.currentBackoff = 0
            }
            refreshCounts()
        case .permanentFailure(let code):
            if moveToFailed(name) {
                onEvent?(.warn, "upload: \(name) rejected with HTTP \(code), moved to upload_failed/")
            } else {
                leftovers.withLock { $0[name] = .moveToFailed }
                onEvent?(.warn, "upload: \(name) rejected with HTTP \(code); could not move it to upload_failed/, skipping it")
            }
            statusBox.withLock { $0.lastError = "HTTP \(code)" }
            refreshCounts()
        case .retry(let reason):
            let previous = statusBox.withLock { s -> String? in
                let p = s.lastError
                s.lastError = reason
                s.currentBackoff = Self.nextBackoff(s.currentBackoff)
                return p
            }
            if previous != reason { onEvent?(.warn, "upload retry: \(reason)") }
        case .skipped, .disabled, .empty:
            break
        }
        return outcome
    }

    /// Spec §6 / §6.2 status mapping for one response to the head file.
    private func classify(status code: Int, isMeta: Bool, name: String) -> Outcome {
        switch code {
        case 200..<300: return .uploaded(status: code)
        case 409: return .duplicate
        case 401, 403: return .retry(reason: "HTTP \(code) (check device key)")
        // Session metadata on a backend without the PUT route ("until this exists, the backend creates
        // the trip from its first batch"), or a function redeploy in progress: retry for a while, then
        // set it aside so it never blocks the batches for good.
        case 404 where isMeta, 405 where isMeta: // `where` binds per pattern
            let attempts = notFoundAttempts.withLock { a -> Int in
                a = a.name == name ? (name, a.count + 1) : (name, 1)
                return a.count
            }
            return attempts >= Self.maxMetadataNotFoundAttempts
                ? .permanentFailure(status: code)
                : .retry(reason: "HTTP \(code) on session metadata (check the API URL)")
        // A wrong base path must not dump the whole queue into upload_failed/ within seconds.
        case 404: return .retry(reason: "HTTP 404 (check the API URL)")
        case 408, 429: return .retry(reason: "HTTP \(code)")
        case 400..<500: return .permanentFailure(status: code)
        // 5xx (the ingest function's 503 = storage/Event Hubs/Key Vault outage), 3xx (redirects are
        // never followed): retry the same file, in place, with backoff. Never re-ordered.
        default: return .retry(reason: "HTTP \(code)")
        }
    }

    /// Moves `name` from the queue to `upload_failed/` (replacing an older copy with the same name).
    private func moveToFailed(_ name: String) -> Bool {
        let fm = FileManager.default
        let dest = failedDirectory.appendingPathComponent(name)
        try? fm.removeItem(at: dest)
        return (try? fm.moveItem(at: directory.appendingPathComponent(name), to: dest)) != nil
    }

    /// Retries the delete/move of files that were already sent or rejected.
    private func finishLeftovers() {
        let pending = leftovers.current
        guard !pending.isEmpty else { return }
        let fm = FileManager.default
        for (name, action) in pending {
            let url = directory.appendingPathComponent(name)
            let done: Bool
            if !fm.fileExists(atPath: url.path) {
                done = true
            } else {
                switch action {
                case .delete: done = (try? fm.removeItem(at: url)) != nil
                case .moveToFailed: done = moveToFailed(name)
                }
            }
            if done { leftovers.withLock { _ = $0.removeValue(forKey: name) } }
        }
    }

    /// `.json.gz` files in the queue folder whose name we didn't write (Documents is visible in the
    /// Files app, so a user can copy or rename them): moved to `upload_failed/` instead of blocking.
    private func setAsideForeignFiles() {
        for name in Self.queueFileNames(in: directory) where Self.parseItem(fileName: name) == nil {
            if moveToFailed(name) {
                onEvent?(.warn, "upload: \(name) is not a queue file name, moved to upload_failed/")
            }
        }
    }

    static func nextBackoff(_ current: TimeInterval) -> TimeInterval {
        current <= 0 ? minBackoff : min(maxBackoff, current * 2)
    }

    // MARK: Background time

    /// Asks iOS for background time until the queue is empty (released by `processOnce` on `.empty`
    /// or `.disabled`, by `stop()`, or by iOS on expiration).
    func holdBackgroundTimeUntilDrained() {
        guard let provider = backgroundTime,
              backgroundHeld.withLock({ held -> Bool in defer { held = true }; return !held }) else { return }
        provider.begin { [weak self] in
            guard let self else { return }
            self.backgroundHeld.withLock { $0 = false }
            self.onEvent?(.warn, "upload: iOS ended the background time with \(self.status.queueCount) file(s) queued; "
                          + "they are sent when the app runs again")
        }
    }

    private func releaseBackgroundTime() {
        guard let provider = backgroundTime,
              backgroundHeld.withLock({ held -> Bool in defer { held = false }; return held }) else { return }
        provider.end()
    }

    var isHoldingBackgroundTime: Bool { backgroundHeld.current }

    // MARK: Loop

    func start() {
        loopTask.withLock { loopTask in
            guard loopTask == nil else { return }
            loopTask = Task.detached(priority: .utility) { [weak self] in
                while !Task.isCancelled {
                    guard let self else { return }
                    let outcome = await self.processOnce()
                    let wait: TimeInterval
                    switch outcome {
                    // The file just handled is gone or skipped (see `leftovers`), so this never re-sends it.
                    case .uploaded, .duplicate, .permanentFailure, .skipped: wait = 0
                    case .retry: wait = self.status.currentBackoff
                    case .disabled: wait = 2
                    case .empty: wait = 1
                    }
                    if wait > 0 { await self.sleep(wait) }
                }
            }
        }
    }

    func stop() {
        let task = loopTask.withLock { t -> Task<Void, Never>? in defer { t = nil }; return t }
        task?.cancel()
        releaseBackgroundTime()
    }

    /// Retry now: resets backoff and wakes the loop ("Upload full session").
    func kick() {
        statusBox.withLock { $0.currentBackoff = 0 }
        kickFlag.withLock { $0 = true }
    }

    /// Sleeps up to `seconds`, waking early on `kick()`.
    private func sleep(_ seconds: TimeInterval) async {
        let step: TimeInterval = 0.2
        var waited: TimeInterval = 0
        while waited < seconds && !Task.isCancelled {
            if kickFlag.withLock({ k -> Bool in let v = k; k = false; return v }) { return }
            try? await Task.sleep(nanoseconds: UInt64(min(step, seconds - waited) * 1_000_000_000))
            waited += step
        }
    }

    // MARK: Preflight connectivity test (warning only)

    /// Probe `POST {API}/api/ingest` with a deliberately invalid body (`{"probe":true,"deviceId":…}`,
    /// gzipped, with the device key). The ingest function checks the key, then that the key is stored
    /// under this deviceId, then the schema, so: 400/422 = reachable + key accepted for this device (the
    /// probe is rejected, never stored); 401 = unknown key; 403 = key stored under another Device ID;
    /// 404 = wrong base URL. There is no `/api/health` route (02 §5). Never blocks.
    static func testConnection(config: UploadConfig, deviceId: String = AppSettings.deviceId,
                               transport: HTTPTransport = URLSessionTransport()) async -> ProbeResult {
        guard let url = config.ingestURL else { return (false, "upload off (no URL)", "Upload off") }
        var r = URLRequest(url: url)
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.setValue("gzip", forHTTPHeaderField: "Content-Encoding")
        r.setValue(config.deviceKey, forHTTPHeaderField: "x-device-key")
        r.setValue("1", forHTTPHeaderField: "x-probe")
        let probe = (try? JSONSerialization.data(withJSONObject: ["probe": true, "deviceId": deviceId] as [String: Any]))
            ?? Data(#"{"probe":true}"#.utf8)
        r.httpBody = try? Gzip.compress(probe)
        r.timeoutInterval = 8
        do {
            return interpretProbe(status: try await transport.send(r))
        } catch {
            return (false, "unreachable: \(error.localizedDescription)", "Server unreachable")
        }
    }

    /// `detail` for logs and the preflight record; `short` is the few words Settings shows.
    typealias ProbeResult = (ok: Bool, detail: String, short: String)

    static func interpretProbe(status: Int) -> ProbeResult {
        switch status {
        case 400, 422: return (true, "reachable, key accepted (HTTP \(status) to probe)", "Connected")
        case 200..<300: return (true, "reachable (HTTP \(status))", "Connected")
        case 401: return (false, "device key rejected (HTTP 401)", "Wrong device key")
        case 403: return (false, "device key is stored under another Device ID (HTTP 403): add it for this phone's Device ID (Settings)",
                          "Key belongs to another phone")
        case 404: return (false, "endpoint not found (HTTP 404): check the API URL", "Wrong server address")
        default: return (false, "HTTP \(status) from /api/ingest", "Server error (HTTP \(status))")
        }
    }
}

/// Background execution time for the upload loop (`UIApplication.beginBackgroundTask`), behind a
/// protocol so tests can observe it. At most one request is outstanding per provider.
protocol BackgroundTimeProvider: AnyObject, Sendable {
    /// Requests background time. `onExpire` runs if iOS takes it back first (the provider has already
    /// ended the task then).
    func begin(onExpire: @escaping @Sendable () -> Void)
    func end()
}

/// The real provider. Both calls hop to the main thread in FIFO order, so an `end()` issued right after
/// a `begin()` can never run first; the task id is touched on the main thread only.
final class UIKitBackgroundTime: BackgroundTimeProvider, @unchecked Sendable {
    private var task: UIBackgroundTaskIdentifier = .invalid // main thread only

    func begin(onExpire: @escaping @Sendable () -> Void) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                guard self.task == .invalid else { return }
                self.task = UIApplication.shared.beginBackgroundTask(withName: "upload-queue-drain") {
                    MainActor.assumeIsolated { self.endOnMain() }
                    onExpire()
                }
            }
        }
    }

    func end() {
        DispatchQueue.main.async { MainActor.assumeIsolated { self.endOnMain() } }
    }

    @MainActor private func endOnMain() {
        guard task != .invalid else { return }
        UIApplication.shared.endBackgroundTask(task)
        task = .invalid
    }
}
