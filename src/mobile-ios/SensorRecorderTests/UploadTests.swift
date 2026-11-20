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
        XCTAssertEqual(acc.drain(t0Up: 502, t0UtcMs: 0, device: device).batchSeq, 1)
        XCTAssertEqual(acc.batchesCreated, 2)

        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: b.jsonData()) as? [String: Any])
        // Spec §6 keys (all must stay) + additive hackathon-rule keys.
        let specKeys: Set<String> = ["schemaVersion", "sessionId", "deviceId", "batchSeq", "t0Utc", "t0Up", "units",
                                     "deviceMotion", "accelRaw", "gyroRaw", "location", "altimeter", "audioLevel",
                                     "labels", "device"]
        XCTAssertEqual(Set(obj.keys), specKeys.union(["eventType", "source", "t0UtcMs", "fieldUnits"]))
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
                                      "q_w", "q_x", "q_y", "q_z"])
        XCTAssertEqual(dm["t"]?.count, 200)
        XCTAssertEqual(dm["t"]?.first, 0)
        XCTAssertEqual(dm["t"]?[1] ?? 0, 0.01, accuracy: 1e-9)
        XCTAssertEqual(dm["ua_x"]?.first, 0.012346) // rounded to 6 decimals
        let loc = try XCTUnwrap((obj["location"] as? [[String: Any]])?.first)
        XCTAssertEqual(Set(loc.keys), ["tUtcMs", "lat", "lon", "alt", "hAcc", "speed", "speedAcc", "course", "isSimulated"])
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
        try enqueue(2); try enqueue(0); try enqueue(1)
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
}
