import Foundation

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
///   `<createdUtcMs>_<sessionId>_<batchSeq>.json.gz` so lexical order = oldest first.
/// - One request at a time, oldest first. Exponential backoff 1 s → 30 s on failure.
/// - 2xx and 409 (duplicate) → delete. 408/429 → retry. 401/403 → retry with backoff (a wrong key
///   must not dump the whole queue into `upload_failed/`). Other 4xx → move to `upload_failed/`.
/// - Idempotency key = `sessionId:batchSeq` (also inside the body).
final class UploadQueue: @unchecked Sendable {
    enum Outcome: Equatable {
        case uploaded(status: Int)
        case duplicate
        case permanentFailure(status: Int)
        case retry(reason: String)
        case disabled
        case empty
    }

    let directory: URL
    let failedDirectory: URL
    private let transport: HTTPTransport
    private let configProvider: @Sendable () -> UploadConfig
    private let uptime: @Sendable () -> TimeInterval
    private let statusBox = Locked(UploadStatus())
    private let kickFlag = Locked(false)
    private var loopTask: Task<Void, Never>?

    /// After this many consecutive server-side errors (5xx/408/429) for the SAME batch, move it to the
    /// back of the queue so one bad batch can't block every newer one. Network errors don't count
    /// (that's an outage, not the batch). Nothing is ever deleted on failure.
    static let maxServerErrorsPerBatch = 5
    private let headFailures = Locked<(name: String, count: Int)>(("", 0))

    static let minBackoff: TimeInterval = 1
    static let maxBackoff: TimeInterval = 30

    var onEvent: (@Sendable (LogLevel, String) -> Void)?

    init(directory: URL, transport: HTTPTransport = URLSessionTransport(),
         uptime: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         config: @escaping @Sendable () -> UploadConfig) {
        self.directory = directory
        failedDirectory = directory.deletingLastPathComponent().appendingPathComponent("upload_failed", isDirectory: true)
        self.transport = transport
        self.configProvider = config
        self.uptime = uptime
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: failedDirectory, withIntermediateDirectories: true)
        refreshCounts()
    }

    static var defaultDirectory: URL {
        SessionStore.documentsDirectory.appendingPathComponent("upload_queue", isDirectory: true)
    }

    var status: UploadStatus { statusBox.current }

    /// Upload configured right now (API URL set).
    var isEnabled: Bool { configProvider().isEnabled }

    // MARK: Enqueue

    static func fileName(createdUtcMs: Int64, sessionId: String, seq: Int) -> String {
        String(format: "%013lld", createdUtcMs) + "_" + sessionId + "_" + String(format: "%07d", seq) + ".json.gz"
    }

    static func parse(fileName: String) -> (createdMs: Int64, sessionId: String, seq: Int)? {
        guard fileName.hasSuffix(".json.gz") else { return nil }
        let stem = fileName.dropLast(".json.gz".count)
        let parts = stem.split(separator: "_")
        guard parts.count == 3, let ms = Int64(parts[0]), let seq = Int(parts[2]) else { return nil }
        return (ms, String(parts[1]), seq)
    }

    /// Writes the gzipped batch atomically (temp + rename): a half-written file is never uploaded.
    func enqueue(gzippedBody: Data, sessionId: String, seq: Int, createdUtcMs: Int64) throws {
        let name = Self.fileName(createdUtcMs: createdUtcMs, sessionId: sessionId, seq: seq)
        try gzippedBody.write(to: directory.appendingPathComponent(name), options: .atomic)
        statusBox.withLock { $0.queueCount += 1 }
    }

    func enqueue(batch: IngestBatch, createdUtcMs: Int64) throws {
        let gz = try Gzip.compress(try batch.jsonData())
        try enqueue(gzippedBody: gz, sessionId: batch.sessionId, seq: batch.batchSeq, createdUtcMs: createdUtcMs)
    }

    func pendingFiles() -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.filter { $0.hasSuffix(".json.gz") }.sorted().map { directory.appendingPathComponent($0) }
    }

    func pendingCount(sessionId: String) -> Int {
        pendingFiles().filter { Self.parse(fileName: $0.lastPathComponent)?.sessionId == sessionId }.count
    }

    func failedFiles() -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: failedDirectory.path)) ?? []
        return names.filter { $0.hasSuffix(".json.gz") }.sorted().map { failedDirectory.appendingPathComponent($0) }
    }

    func refreshCounts() {
        let q = pendingFiles().count
        let f = failedFiles().count
        statusBox.withLock { $0.queueCount = q; $0.failedCount = f }
    }

    /// Deletes queued batches (operator action; session files are NOT affected). Optionally only
    /// one session's batches. Safe while the loop runs: a batch being sent is simply gone afterwards.
    func clearPending(sessionId: String? = nil) {
        for f in pendingFiles() where sessionId == nil || Self.parse(fileName: f.lastPathComponent)?.sessionId == sessionId {
            do { try FileManager.default.removeItem(at: f) } catch {
                onEvent?(.warn, "upload: could not delete \(f.lastPathComponent): \(error.localizedDescription)")
            }
        }
        refreshCounts()
    }

    /// Moves everything in `upload_failed/` back into the queue (operator action).
    func requeueFailed() {
        for f in failedFiles() {
            try? FileManager.default.moveItem(at: f, to: directory.appendingPathComponent(f.lastPathComponent))
        }
        refreshCounts()
        kick()
    }

    // MARK: Processing

    func makeRequest(for file: URL, config: UploadConfig) throws -> URLRequest {
        guard let url = config.ingestURL else { throw URLError(.badURL) }
        var r = URLRequest(url: url)
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.setValue("gzip", forHTTPHeaderField: "Content-Encoding")
        r.setValue(config.deviceKey, forHTTPHeaderField: "x-device-key")
        if let p = Self.parse(fileName: file.lastPathComponent) {
            r.setValue("\(p.sessionId):\(p.seq)", forHTTPHeaderField: "x-idempotency-key")
        }
        r.httpBody = try Data(contentsOf: file)
        r.timeoutInterval = 15
        return r
    }

    /// Uploads the oldest queued batch once. Deterministic and unit-tested; the loop calls it.
    func processOnce() async -> Outcome {
        let config = configProvider()
        let now = uptime()
        statusBox.withLock {
            if config.isEnabled && !$0.enabled { $0.enabledSinceUp = now }
            if !config.isEnabled { $0.enabledSinceUp = nil }
            $0.enabled = config.isEnabled
        }
        guard config.isEnabled else { return .disabled }
        guard let file = pendingFiles().first else {
            statusBox.withLock { $0.queueCount = 0 }
            return .empty
        }
        statusBox.withLock { $0.lastAttemptUp = now }
        let outcome: Outcome
        var serverSide = false
        do {
            let req = try makeRequest(for: file, config: config)
            let code = try await transport.send(req)
            switch code {
            case 200..<300: outcome = .uploaded(status: code)
            case 409: outcome = .duplicate
            case 408, 429: outcome = .retry(reason: "HTTP \(code)"); serverSide = true
            case 401, 403: outcome = .retry(reason: "HTTP \(code) (check device key)")
            // A wrong base path must not dump the whole queue into upload_failed/ within seconds.
            case 404: outcome = .retry(reason: "HTTP 404 (check the API URL)")
            case 400..<500: outcome = .permanentFailure(status: code)
            default: outcome = .retry(reason: "HTTP \(code)"); serverSide = true
            }
        } catch {
            outcome = .retry(reason: (error as? URLError).map { "network: \($0.code.rawValue)" } ?? error.localizedDescription)
        }

        let fm = FileManager.default
        switch outcome {
        case .uploaded, .duplicate:
            do { try fm.removeItem(at: file) } catch {
                // Would be re-sent (harmless: idempotent), but the counters must not drift silently.
                onEvent?(.warn, "upload: sent \(file.lastPathComponent) but could not delete it: \(error.localizedDescription)")
            }
            headFailures.withLock { $0 = ("", 0) }
            statusBox.withLock {
                $0.uploadedCount += 1
                $0.lastSuccessUp = self.uptime()
                $0.lastError = nil
                $0.currentBackoff = 0
                $0.queueCount = max(0, $0.queueCount - 1)
            }
        case .permanentFailure(let code):
            let dest = failedDirectory.appendingPathComponent(file.lastPathComponent)
            try? fm.removeItem(at: dest) // an older copy with the same name, if any
            do { try fm.moveItem(at: file, to: dest) } catch {
                onEvent?(.warn, "upload: could not move \(file.lastPathComponent) to upload_failed/: \(error.localizedDescription)")
            }
            statusBox.withLock {
                $0.lastError = "HTTP \(code)"
                $0.failedCount += 1
                $0.queueCount = max(0, $0.queueCount - 1)
            }
            onEvent?(.warn, "upload: \(file.lastPathComponent) rejected with HTTP \(code), moved to upload_failed/")
        case .retry(let reason):
            let previous = statusBox.withLock { s -> String? in
                let p = s.lastError
                s.lastError = reason
                s.currentBackoff = Self.nextBackoff(s.currentBackoff)
                return p
            }
            if previous != reason { onEvent?(.warn, "upload retry: \(reason)") }
            if serverSide { rotateIfPoisoned(file) } else { headFailures.withLock { $0 = ("", 0) } }
        case .disabled, .empty:
            break
        }
        return outcome
    }

    private func rotateIfPoisoned(_ file: URL) {
        let name = file.lastPathComponent
        let count = headFailures.withLock { h -> Int in
            h = h.name == name ? (name, h.count + 1) : (name, 1)
            return h.count
        }
        guard count >= Self.maxServerErrorsPerBatch, let p = Self.parse(fileName: name) else { return }
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let dest = directory.appendingPathComponent(Self.fileName(createdUtcMs: nowMs, sessionId: p.sessionId, seq: p.seq))
        if (try? FileManager.default.moveItem(at: file, to: dest)) != nil {
            headFailures.withLock { $0 = ("", 0) }
            onEvent?(.warn, "upload: \(name) failed \(count)× on the server, moved to the back of the queue")
        }
    }

    static func nextBackoff(_ current: TimeInterval) -> TimeInterval {
        current <= 0 ? minBackoff : min(maxBackoff, current * 2)
    }

    // MARK: Loop

    func start() {
        guard loopTask == nil else { return }
        loopTask = Task.detached(priority: .utility) { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let outcome = await self.processOnce()
                let wait: TimeInterval
                switch outcome {
                case .uploaded, .duplicate, .permanentFailure: wait = 0
                case .retry: wait = self.status.currentBackoff
                case .disabled: wait = 2
                case .empty: wait = 1
                }
                if wait > 0 { await self.sleep(wait) }
            }
        }
    }

    func stop() {
        loopTask?.cancel()
        loopTask = nil
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

    /// Probe `POST {API}/api/ingest` with a deliberately invalid body (`{"probe":true}`, gzipped,
    /// with the device key). The ingest Lambda checks the key first and the schema second, so:
    /// 400/422 = reachable + key accepted (the probe is rejected, never stored); 401/403 = key
    /// rejected; 404 = wrong base URL. There is no `/api/health` route in the AWS plan. Never blocks.
    static func testConnection(config: UploadConfig, transport: HTTPTransport = URLSessionTransport()) async -> (ok: Bool, detail: String) {
        guard let url = config.ingestURL else { return (false, "upload off (no URL)") }
        var r = URLRequest(url: url)
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.setValue("gzip", forHTTPHeaderField: "Content-Encoding")
        r.setValue(config.deviceKey, forHTTPHeaderField: "x-device-key")
        r.setValue("1", forHTTPHeaderField: "x-probe")
        r.httpBody = try? Gzip.compress(Data(#"{"probe":true}"#.utf8))
        r.timeoutInterval = 8
        do {
            return interpretProbe(status: try await transport.send(r))
        } catch {
            return (false, "unreachable: \(error.localizedDescription)")
        }
    }

    static func interpretProbe(status: Int) -> (ok: Bool, detail: String) {
        switch status {
        case 400, 422: return (true, "reachable, key accepted (HTTP \(status) to probe)")
        case 200..<300: return (true, "reachable (HTTP \(status))")
        case 401, 403: return (false, "device key rejected (HTTP \(status))")
        case 404: return (false, "endpoint not found (HTTP 404): check the API URL")
        default: return (false, "HTTP \(status) from /api/ingest")
        }
    }
}
