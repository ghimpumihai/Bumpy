import XCTest
@testable import SensorRecorder

final class IngestBatchTests: XCTestCase {
    func testDrainProducesContractShape() throws {
        let acc = BatchAccumulator(sessionId: "S1", deviceId: "D1")
        for i in 0..<200 {
            let t = 500 + Double(i) * 0.01
            acc.add(DeviceMotionSample(t: t, userAccel: Vec3(x: 0.0123456789, y: 0, z: 0), gravity: Vec3(x: 0, y: 0, z: -1),
                                       rotationRate: .zero, quaternion: Quaternion(w: 1, x: 0, y: 0, z: 0),
                                       roll: 0, pitch: 0, yaw: 0))
            acc.addAccel(Vec3Sample(t: t, v: Vec3(x: 0, y: 0, z: -1)))
            acc.addGyro(Vec3Sample(t: t, v: .zero))
        }
        acc.add(LocationSample(utcMs: 1_763_716_532_120.4, lat: 46.771212345, lon: 23.62363, alt: 352.1, ellAlt: 0,
                               hAcc: 4.7, vAcc: 3, speed: 8.4, speedAcc: 0.5, course: 92, courseAcc: 1, isSimulated: false))
        acc.add(AltimeterSample(t: 500.5, relativeAltitudeM: 0.25, pressureKPa: 97.1))
        acc.add(AudioLevelSample(t: 500.1, avgDbfs: -31, peakDbfs: -10))
        acc.addLabel(t: 501.24, type: "pothole", value: nil, note: nil)

        let device = DeviceStatus(batteryLevel: 0.82, batteryState: "charging", thermal: .nominal, lowPowerMode: false,
                                  freeDiskBytes: 1, networkStatus: "satisfied", networkType: "wifi")
        let b = acc.drain(t0Up: 500, t0UtcMs: 1_763_716_532_000, device: device)
        XCTAssertEqual(b.batchSeq, 0)
        XCTAssertEqual(acc.drain(t0Up: 502, t0UtcMs: 0, device: device).batchSeq, 0, "not queued yet: number not used")
        acc.markQueued(seq: 0)
        XCTAssertEqual(acc.drain(t0Up: 504, t0UtcMs: 0, device: device).batchSeq, 1)
        acc.markQueued(seq: 1)
        XCTAssertEqual(acc.batchesCreated, 2)

        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: b.jsonData()) as? [String: Any])
        // Spec §6 keys (all must stay) + additive hackathon-rule keys.
        let specKeys: Set<String> = ["schemaVersion", "sessionId", "deviceId", "batchSeq", "t0Utc", "t0Up", "units",
                                     "deviceMotion", "accelRaw", "gyroRaw", "location", "altimeter", "audioLevel",
                                     "labels", "device"]
        XCTAssertEqual(Set(obj.keys), specKeys.union(["eventType", "source", "t0UtcMs", "fieldUnits",
                                                       "magRaw", "heading", "absAltitude", "activity"]))
        XCTAssertEqual(obj["eventType"] as? String, "sensor_batch")
        XCTAssertEqual(obj["source"] as? String, "live")
        XCTAssertEqual((obj["t0UtcMs"] as? NSNumber)?.int64Value, 1_763_716_532_000)
        let fieldUnits = try XCTUnwrap(obj["fieldUnits"] as? [String: String])
        XCTAssertEqual(fieldUnits["location.lat"], "deg")
        XCTAssertEqual(fieldUnits["audioLevel.avgDbfs"], "dBFS")
        XCTAssertEqual(obj["schemaVersion"] as? Int, 1)
        XCTAssertEqual(obj["t0Utc"] as? String, "2025-11-21T09:15:32.000Z")
        XCTAssertEqual(obj["units"] as? [String: String], ["accel": "g", "gyro": "rad/s", "speed": "m/s", "pressure": "kPa"])
        let dm = try XCTUnwrap(obj["deviceMotion"] as? [String: [Double]])
        XCTAssertEqual(Set(dm.keys), ["t", "ua_x", "ua_y", "ua_z", "g_x", "g_y", "g_z", "rr_x", "rr_y", "rr_z",
                                      "q_w", "q_x", "q_y", "q_z", "roll", "pitch", "yaw"])
        XCTAssertEqual(dm["t"]?.count, 200)
        XCTAssertEqual(dm["t"]?.first, 0)
        XCTAssertEqual(dm["t"]?[1] ?? 0, 0.01, accuracy: 1e-9)
        XCTAssertEqual(dm["ua_x"]?.first, 0.012346) // rounded to 6 decimals
        let loc = try XCTUnwrap((obj["location"] as? [[String: Any]])?.first)
        XCTAssertEqual(Set(loc.keys), ["tUtcMs", "lat", "lon", "alt", "hAcc", "speed", "speedAcc", "course", "isSimulated",
                                       "ellAlt", "vAcc", "courseAcc"])
        XCTAssertEqual(loc["isSimulated"] as? Bool, false)
        XCTAssertEqual(loc["tUtcMs"] as? Int64, 1_763_716_532_120)
        XCTAssertEqual(loc["lat"] as? Double, 46.77121235)
        let label = try XCTUnwrap((obj["labels"] as? [[String: Any]])?.first)
        XCTAssertEqual(label["t"] as? Double ?? 0, 1.24, accuracy: 1e-9)
        XCTAssertTrue(label["value"] is NSNull, "value must be an explicit null")
        XCTAssertTrue(label["note"] is NSNull)
        let alt = try XCTUnwrap(obj["altimeter"] as? [String: [Double]])
        XCTAssertEqual(Set(alt.keys), ["t", "relAltM", "pressureKpa"])
        let audio = try XCTUnwrap(obj["audioLevel"] as? [String: [Double]])
        XCTAssertEqual(Set(audio.keys), ["t", "avgDbfs", "peakDbfs"])
        let dev = try XCTUnwrap(obj["device"] as? [String: Any])
        XCTAssertEqual(dev["thermal"] as? String, "nominal")
        XCTAssertEqual(dev["lowPower"] as? Bool, false)

        // Size sanity (spec: ~30 KB raw / ~10 KB gzipped per 2 s batch)
        let raw = try b.jsonData()
        let gz = try Gzip.compress(raw)
        XCTAssertLessThan(raw.count, 60_000)
        XCTAssertLessThan(gz.count, raw.count / 2)
    }
}

final class UploadQueueTests: XCTestCase {
    private var dir: URL!
    private var transport: MockTransport!
    private var config: Locked<UploadConfig>!
    private var queue: UploadQueue!

    override func setUpWithError() throws {
        dir = try makeTempDir().appendingPathComponent("upload_queue")
        transport = MockTransport()
        config = Locked(UploadConfig(baseURL: URL(string: "https://example.test/base"), deviceKey: "secret"))
        let cfg = config!
        queue = UploadQueue(directory: dir, transport: transport, config: { cfg.current })
    }

    private func enqueue(_ seq: Int, session: String = "S1", created: Int64 = 1_700_000_000_000) throws {
        try queue.enqueue(gzippedBody: Gzip.compress(Data("{\"batchSeq\":\(seq)}".utf8)), sessionId: session, seq: seq,
                          createdUtcMs: created + Int64(seq))
    }

    func testFileNameRoundTrip() {
        let n = UploadQueue.fileName(createdUtcMs: 1_700_000_000_123, sessionId: "AB-CD", seq: 42)
        XCTAssertEqual(n, "1700000000123_AB-CD_0000042.json.gz")
        let p = UploadQueue.parse(fileName: n)
        XCTAssertEqual(p?.createdMs, 1_700_000_000_123)
        XCTAssertEqual(p?.sessionId, "AB-CD")
        XCTAssertEqual(p?.seq, 42)
    }

    func testRequestFormat() async throws {
        try enqueue(7)
        transport.enqueue(201)
        let outcome = await queue.processOnce()
        XCTAssertEqual(outcome, .uploaded(status: 201))
        let r = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(r.httpMethod, "POST")
        XCTAssertEqual(r.url?.absoluteString, "https://example.test/base/api/ingest")
        XCTAssertEqual(r.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(r.value(forHTTPHeaderField: "Content-Encoding"), "gzip")
        XCTAssertEqual(r.value(forHTTPHeaderField: "x-device-key"), "secret")
        XCTAssertEqual(r.value(forHTTPHeaderField: "x-idempotency-key"), "S1:7")
        let body = try Gzip.decompress(try XCTUnwrap(r.httpBody))
        XCTAssertEqual(String(decoding: body, as: UTF8.self), "{\"batchSeq\":7}")
        XCTAssertEqual(queue.pendingFiles().count, 0)
        XCTAssertNotNil(queue.status.lastSuccessUp)
    }

    func testOldestFirstOneAtATime() async throws {
        // Enqueued 0, 1, 2 while the wall clock steps back each time: send order is still enqueue order.
        for seq in 0..<3 { try enqueue(seq, created: 1_700_000_000_000 - Int64(seq) * 5_000) }
        for _ in 0..<3 { _ = await queue.processOnce() }
        let keys = transport.requests.map { $0.value(forHTTPHeaderField: "x-idempotency-key") }
        XCTAssertEqual(keys, ["S1:0", "S1:1", "S1:2"])
        let o1 = await queue.processOnce()
        XCTAssertEqual(o1, .empty)
    }

    func testDuplicate409IsSuccess() async throws {
        try enqueue(0)
        transport.enqueue(409)
        let o2 = await queue.processOnce()
        XCTAssertEqual(o2, .duplicate)
        XCTAssertTrue(queue.pendingFiles().isEmpty)
        XCTAssertTrue(queue.failedFiles().isEmpty)
    }

    func testOther4xxMovesToFailedAndContinues() async throws {
        try enqueue(0); try enqueue(1)
        transport.enqueue(400, 200)
        let o3 = await queue.processOnce()
        XCTAssertEqual(o3, .permanentFailure(status: 400))
        XCTAssertEqual(queue.failedFiles().count, 1)
        XCTAssertEqual(queue.status.failedCount, 1)
        let o4 = await queue.processOnce()
        XCTAssertEqual(o4, .uploaded(status: 200))
        XCTAssertTrue(queue.pendingFiles().isEmpty)
        queue.requeueFailed()
        XCTAssertEqual(queue.pendingFiles().count, 1)
        XCTAssertTrue(queue.failedFiles().isEmpty)
    }

    func testServerErrorsAndNetworkFailuresRetryWithBackoff() async throws {
        try enqueue(0)
        transport.enqueue(500, 503)
        transport.enqueueError(URLError(.notConnectedToInternet))
        transport.enqueue(429, 401)
        var backoffs: [TimeInterval] = []
        for _ in 0..<5 {
            guard case .retry = await queue.processOnce() else { return XCTFail("expected retry") }
            backoffs.append(queue.status.currentBackoff)
        }
        XCTAssertEqual(backoffs, [1, 2, 4, 8, 16])
        XCTAssertEqual(queue.pendingFiles().count, 1, "file kept for retry")
        XCTAssertTrue(queue.failedFiles().isEmpty, "auth errors must not dump the queue into failed/")
        transport.enqueue(500, 500)
        _ = await queue.processOnce(); _ = await queue.processOnce()
        XCTAssertEqual(queue.status.currentBackoff, 30, "capped at 30 s")
        let o5 = await queue.processOnce()
        XCTAssertEqual(o5, .uploaded(status: 200))
        XCTAssertEqual(queue.status.currentBackoff, 0, "reset after success")
    }

    func testDisabledWhenNoURL() async throws {
        try enqueue(0)
        config.withLock { $0 = .disabled }
        let o6 = await queue.processOnce()
        XCTAssertEqual(o6, .disabled)
        XCTAssertTrue(transport.requests.isEmpty)
        XCTAssertEqual(queue.pendingFiles().count, 1, "batches stay queued for later")
        XCTAssertFalse(queue.status.enabled)
    }

    func testLoopDrainsQueueAndKickWakesBackoff() async throws {
        for i in 0..<5 { try enqueue(i) }
        transport.enqueue(500) // first attempt fails -> 1 s backoff
        queue.start()
        defer { queue.stop() }
        queue.kick()
        let deadline = Date().addingTimeInterval(ciTimeout)
        while !queue.pendingFiles().isEmpty && Date() < deadline { try await Task.sleep(nanoseconds: 50_000_000) }
        XCTAssertTrue(queue.pendingFiles().isEmpty)
        XCTAssertEqual(transport.requests.count, 6)
    }

    func testParseBaseURL() {
        XCTAssertNil(UploadConfig.parseBaseURL(""))
        XCTAssertNil(UploadConfig.parseBaseURL("   "))
        XCTAssertNil(UploadConfig.parseBaseURL("not a url"))
        XCTAssertNil(UploadConfig.parseBaseURL("ftp://x.y"))
        XCTAssertEqual(UploadConfig.parseBaseURL(" https://api.example.com/ ")?.absoluteString, "https://api.example.com")
        XCTAssertEqual(UploadConfig(baseURL: UploadConfig.parseBaseURL("http://localhost:8080"), deviceKey: "")
            .ingestURL?.absoluteString, "http://localhost:8080/api/ingest")
    }

    /// The infra output `ingest_base_url` used to include `/api/ingest`; pasting it must not double the path.
    func testParseBaseURLStripsAPastedIngestEndpoint() {
        for (raw, base) in [("https://fn.azurewebsites.net/api/ingest", "https://fn.azurewebsites.net"),
                            ("https://fn.azurewebsites.net/api/ingest/", "https://fn.azurewebsites.net"),
                            (" https://fn.azurewebsites.net/API/Ingest ", "https://fn.azurewebsites.net"),
                            ("https://host.test/prod/api/ingest", "https://host.test/prod"),
                            ("http://192.168.1.20:8765/api/ingest", "http://192.168.1.20:8765"),
                            ("https://fn.azurewebsites.net", "https://fn.azurewebsites.net"),
                            ("https://api/ingest", "https://api/ingest")] { // host "api", path "/ingest": kept
            XCTAssertEqual(UploadConfig.parseBaseURL(raw)?.absoluteString, base, raw)
        }
        let cfg = UploadConfig(baseURL: UploadConfig.parseBaseURL("https://fn.test/api/ingest"), deviceKey: "k")
        XCTAssertEqual(cfg.ingestURL?.absoluteString, "https://fn.test/api/ingest")
        XCTAssertEqual(cfg.sessionURL("S")?.absoluteString, "https://fn.test/api/ingest/sessions/S")
        XCTAssertNil(UploadConfig.parseBaseURL("https://fn.test/api/ingest?code=x"), "query strings stay refused")
        XCTAssertNil(UploadConfig.parseBaseURL("/api/ingest"))
    }
}

/// Records background-time requests instead of calling UIKit.
final class FakeBackgroundTime: BackgroundTimeProvider, @unchecked Sendable {
    private let state = Locked<(begins: Int, ends: Int, onExpire: (@Sendable () -> Void)?)>((0, 0, nil))
    var begins: Int { state.current.begins }
    var ends: Int { state.current.ends }
    func begin(onExpire: @escaping @Sendable () -> Void) { state.withLock { $0.begins += 1; $0.onExpire = onExpire } }
    func end() { state.withLock { $0.ends += 1; $0.onExpire = nil } }
    /// iOS takes the time back.
    func expire() { state.withLock { s -> (@Sendable () -> Void)? in defer { s.onExpire = nil }; return s.onExpire }?() }
}

/// Upload-queue review: the queue must never stall, re-order or hot-loop (spec §6, §6.1, §6.2; 02 D33).
final class UploadQueueStallTests: XCTestCase {
    private func makeQueue(_ t: MockTransport, dir: URL? = nil, background: BackgroundTimeProvider? = nil) throws -> UploadQueue {
        UploadQueue(directory: try dir ?? makeTempDir().appendingPathComponent("upload_queue"), transport: t,
                    backgroundTime: background,
                    config: { UploadConfig(baseURL: URL(string: "https://fn.test"), deviceKey: "k") })
    }

    private func batch(_ q: UploadQueue, _ seq: Int, created: Int64) throws {
        try q.enqueue(gzippedBody: Gzip.compress(Data("{}".utf8)), sessionId: "S", seq: seq, createdUtcMs: created)
    }

    private func keys(_ t: MockTransport) -> [String] {
        t.requests.compactMap { $0.value(forHTTPHeaderField: "x-idempotency-key") }
    }

    private func setWritable(_ url: URL, _ writable: Bool) throws {
        try FileManager.default.setAttributes([.posixPermissions: writable ? 0o755 : 0o555], ofItemAtPath: url.path)
    }

    // Bug: 5 server errors parked the Stop copy in upload_failed/ (backend never learnt batchCount)
    // and rotated batches behind it.
    func testLongOutageKeepsTheStopCopyQueuedAndLast() async throws {
        let t = MockTransport()
        let q = try makeQueue(t)
        try batch(q, 0, created: 1_000)
        try batch(q, 1, created: 3_000)
        try q.enqueueSessionMetadata(json: Data("{}".utf8), sessionId: "S", phase: .stop, createdUtcMs: 3_001)
        for _ in 0..<40 { t.enqueue(503) }
        for _ in 0..<40 { _ = await q.processOnce() }
        XCTAssertTrue(q.failedFiles().isEmpty)
        for _ in 0..<3 { _ = await q.processOnce() }
        XCTAssertEqual(Array(keys(t).suffix(3)), ["S:0", "S:1", "S:meta-stop"], "Stop copy after the last batch (02 D33)")
        XCTAssertTrue(q.pendingFiles().isEmpty)
    }

    // Bug: a name that doesn't parse (Files-app copy) stayed at the head and blocked every upload.
    func testForeignFileNameNeverBlocksTheQueue() async throws {
        let t = MockTransport()
        let dir = try makeTempDir().appendingPathComponent("upload_queue")
        let q = try makeQueue(t, dir: dir)
        let copy = "0000000000001_S_0000042 2.json.gz" // sorts before everything we wrote
        let other = "0000000000001_S_0000042.json 2.gz" // not .json.gz at all: left alone
        for n in [copy, other] { try Data([1, 2]).write(to: dir.appendingPathComponent(n)) }
        try batch(q, 0, created: 1_000)
        XCTAssertEqual(q.pendingFiles().map(\.lastPathComponent).filter { $0.contains("0000042") }, [], "never the head")
        let first = await q.processOnce()
        XCTAssertEqual(first, .uploaded(status: 200))
        XCTAssertEqual(keys(t), ["S:0"])
        XCTAssertEqual(q.failedFiles().map(\.lastPathComponent), [copy], "set aside, not deleted")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent(other).path))
        let next = await q.processOnce()
        XCTAssertEqual(next, .empty)
    }

    // Bug: an unreadable head file was retried as a network error forever.
    func testUnreadableFileIsSetAsideAndTheNextOneIsSent() async throws {
        let t = MockTransport()
        let q = try makeQueue(t)
        try batch(q, 0, created: 1_000)
        try batch(q, 1, created: 2_000)
        let head = try XCTUnwrap(q.pendingFiles().first)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: head.path)
        let first = await q.processOnce()
        guard case .skipped = first else { return XCTFail("expected skipped, got \(first)") }
        XCTAssertTrue(t.requests.isEmpty)
        XCTAssertEqual(q.failedFiles().map(\.lastPathComponent), [head.lastPathComponent])
        let second = await q.processOnce()
        XCTAssertEqual(second, .uploaded(status: 200))
        XCTAssertEqual(keys(t), ["S:1"])
        XCTAssertEqual(q.status.failedCount, 1)
    }

    // Bug: a sent (or rejected) file that couldn't be deleted (or moved) was re-sent with wait = 0.
    func testFileThatCannotBeDeletedIsNotResentInAHotLoop() async throws {
        let t = MockTransport()
        let dir = try makeTempDir().appendingPathComponent("upload_queue")
        let q = try makeQueue(t, dir: dir)
        try batch(q, 0, created: 1_000)
        try batch(q, 1, created: 2_000)
        try setWritable(dir, false)
        defer { try? setWritable(dir, true) }
        t.enqueue(200, 400)
        let sent = await q.processOnce()
        XCTAssertEqual(sent, .uploaded(status: 200))
        let rejected = await q.processOnce()
        XCTAssertEqual(rejected, .permanentFailure(status: 400))
        for _ in 0..<5 {
            let o = await q.processOnce()
            XCTAssertEqual(o, .empty, "both files are done; neither is sent again")
        }
        XCTAssertEqual(keys(t), ["S:0", "S:1"])
        XCTAssertEqual(Self.names(in: dir).count, 2, "the delete and the move really failed")
        XCTAssertEqual(q.status.queueCount, 0)
        try setWritable(dir, true)
        _ = await q.processOnce()
        XCTAssertEqual(Self.names(in: dir), [], "delete and move are finished once possible")
        XCTAssertEqual(q.failedFiles().count, 1)
        XCTAssertEqual(keys(t), ["S:0", "S:1"])
    }

    private static func names(in dir: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.hasSuffix(".json.gz") }
    }

    // Bug: one 404 parked the session metadata at once (function redeploy, URL fixed a minute later).
    func testTransientMetadata404IsRetriedNotParked() async throws {
        let t = MockTransport()
        let q = try makeQueue(t)
        try q.enqueueSessionMetadata(json: Data("{}".utf8), sessionId: "S", phase: .start, createdUtcMs: 1_000)
        try batch(q, 0, created: 2_000)
        t.enqueue(404, 404, 405, 404)
        for _ in 0..<4 {
            guard case .retry = await q.processOnce() else { return XCTFail("metadata 404/405 is retried first") }
        }
        _ = await q.processOnce(); _ = await q.processOnce()
        XCTAssertEqual(Array(keys(t).suffix(2)), ["S:meta-start", "S:0"], "context first, then batch 0")
        XCTAssertTrue(q.failedFiles().isEmpty)
        XCTAssertTrue(q.pendingFiles().isEmpty)
    }

    // Bug: nothing kept the app alive after Stop, so the Stop copy waited for the next launch.
    func testStopCopyHoldsBackgroundTimeUntilTheQueueIsEmpty() async throws {
        let t = MockTransport()
        let bg = FakeBackgroundTime()
        let q = try makeQueue(t, background: bg)
        try q.enqueueSessionMetadata(json: Data("{}".utf8), sessionId: "S", phase: .start, createdUtcMs: 1_000)
        try batch(q, 0, created: 2_000)
        XCTAssertEqual(bg.begins, 0, "only Stop asks for background time (recording keeps the app alive)")
        try q.enqueueSessionMetadata(json: Data("{}".utf8), sessionId: "S", phase: .stop, createdUtcMs: 3_000)
        XCTAssertEqual(bg.begins, 1)
        XCTAssertTrue(q.isHoldingBackgroundTime)
        t.enqueue(503)
        for _ in 0..<4 { _ = await q.processOnce() } // 503 + three uploads
        XCTAssertEqual(bg.ends, 0, "held while anything is queued")
        let done = await q.processOnce()
        XCTAssertEqual(done, .empty)
        XCTAssertEqual(bg.ends, 1, "released once the queue is empty")
        XCTAssertFalse(q.isHoldingBackgroundTime)
        _ = await q.processOnce()
        XCTAssertEqual(bg.ends, 1, "released once")

        // iOS takes the time back: nothing is ended twice, and the next Stop asks again.
        try q.enqueueSessionMetadata(json: Data("{}".utf8), sessionId: "T", phase: .stop, createdUtcMs: 4_000)
        XCTAssertEqual(bg.begins, 2)
        bg.expire()
        XCTAssertFalse(q.isHoldingBackgroundTime)
        _ = await q.processOnce(); _ = await q.processOnce()
        XCTAssertEqual(bg.ends, 1)
    }

    // Bug: names came from the wall clock, so a step back could sort the Stop copy before the last batch.
    func testWallClockStepBackCannotReorderTheStopCopy() async throws {
        let t = MockTransport()
        let dir = try makeTempDir().appendingPathComponent("upload_queue")
        let q = try makeQueue(t, dir: dir)
        try q.enqueueSessionMetadata(json: Data("{}".utf8), sessionId: "S", phase: .start, createdUtcMs: 10_000)
        try batch(q, 0, created: 9_000) // the clock stepped back 1 s
        try batch(q, 1, created: 12_000)
        try q.enqueueSessionMetadata(json: Data("{}".utf8), sessionId: "S", phase: .stop, createdUtcMs: 11_000)
        // A relaunch (new queue instance) continues after the files already on disk.
        let relaunched = try makeQueue(t, dir: dir)
        try relaunched.enqueue(gzippedBody: Gzip.compress(Data("{}".utf8)), sessionId: "U", seq: 0, createdUtcMs: 5_000)
        for _ in 0..<5 { _ = await relaunched.processOnce() }
        XCTAssertEqual(keys(t), ["S:meta-start", "S:0", "S:1", "S:meta-stop", "U:0"])
    }
}

/// Bug: drain() consumed a batchSeq before the batch was queued, so a failed enqueue left a hole that
/// the Stop copy's batchCount still counted (spec §6.2: batchCount is exact).
final class BatchSeqWithoutHolesTests: XCTestCase {
    func testFailedEnqueueBurnsNoSeqAndLosesNoWindow() throws {
        let dir = try makeTempDir().appendingPathComponent("upload_queue")
        let q = UploadQueue(directory: dir, transport: MockTransport(), backgroundTime: nil,
                            config: { UploadConfig(baseURL: URL(string: "https://fn.test"), deviceKey: "k") })
        let deps = RecordingSession.Dependencies(
            motion: SyntheticMotionSource(), location: nil, altimeter: nil, activity: nil, audio: nil,
            deviceStatus: FakeDeviceStatus(), uploadQueue: q, deviceId: "D", appVersion: "t",
            deviceInfo: .init(model: "x", name: "x", iosVersion: "x"))
        let session = try RecordingSession(store: SessionStore(root: try makeTempDir()), setup: SessionSetup(),
                                           preflight: nil, deps: deps)
        func setWritable(_ w: Bool) {
            try? FileManager.default.setAttributes([.posixPermissions: w ? 0o755 : 0o555], ofItemAtPath: dir.path)
        }
        defer { setWritable(true) }
        let e = expectation(description: "run")
        DispatchQueue.main.async {
            session.start()
            // The queue folder can't be written while the 4 s and 6 s batch ticks fire, then recovers;
            // stop() queues what is still waiting before the Stop copy.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { setWritable(false) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 6.9) { setWritable(true) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 7.5) { session.stop(); e.fulfill() }
        }
        wait(for: [e], timeout: ciTimeout)

        let log = try String(contentsOf: session.folder.appendingPathComponent("app_log.txt"), encoding: .utf8)
        XCTAssertTrue(log.contains("could not queue upload batch"), "the test really made an enqueue fail")
        let files = q.pendingFiles()
        let batches = files.filter { UploadQueue.parse(fileName: $0.lastPathComponent) != nil }
        var seqs: [Int] = []
        var totalDM = 0
        for f in batches {
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Gzip.decompress(Data(contentsOf: f))) as? [String: Any])
            seqs.append(try XCTUnwrap(json["batchSeq"] as? Int))
            totalDM += try XCTUnwrap((json["deviceMotion"] as? [String: [Double]])?["t"]).count
        }
        XCTAssertEqual(seqs, Array(0..<batches.count), "no hole where the enqueue failed")
        XCTAssertEqual(session.metadata.stats?.uploadBatchesCreated, batches.count)
        let stop = try XCTUnwrap(files.last)
        XCTAssertEqual(UploadQueue.parseItem(fileName: stop.lastPathComponent)?.item, .sessionMeta(phase: .stop))
        let stopMeta = try XCTUnwrap(JSONSerialization.jsonObject(with: Gzip.decompress(Data(contentsOf: stop))) as? [String: Any])
        XCTAssertEqual(stopMeta["batchCount"] as? Int, batches.count, "batchCount = batches actually queued")
        XCTAssertEqual(Int64(totalDM), session.metadata.stats?.streams["deviceMotion"]?.samples,
                       "the window that failed to queue was retried, not dropped")
    }
}
