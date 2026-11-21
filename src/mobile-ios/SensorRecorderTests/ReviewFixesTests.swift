import XCTest
@testable import SensorRecorder

// Tests added with the multi-perspective review: each pins a finding or a new requirement.

// MARK: - Writer failure paths (disk full / partial writes)

/// In-memory sink that accepts at most `capacity` bytes, then writes a partial prefix and throws.
final class FlakySink: FileSink {
    var data = Data()
    var capacity: Int
    init(initial: Data, capacity: Int) { data = initial; self.capacity = capacity }
    func offset() throws -> UInt64 { UInt64(data.count) }
    func write(_ d: Data) throws {
        let room = max(0, capacity - data.count)
        if d.count <= room { data.append(d); return }
        data.append(d.prefix(room)) // partial write, like a real full disk
        throw CocoaError(.fileWriteOutOfSpace)
    }
    func synchronize() throws {}
    func close() throws {}
}

final class WriterFailureTests: XCTestCase {
    private func makeWriter(header: String, capacity: Int) throws -> (BufferedFileWriter, FlakySink) {
        let url = try makeTempDir().appendingPathComponent("w.csv")
        var sinkRef: FlakySink!
        let w = try BufferedFileWriter(url: url, header: header) { _ in
            sinkRef = FlakySink(initial: Data((header + "\n").utf8), capacity: capacity)
            return sinkRef
        }
        return (w, sinkRef)
    }

    func testPartialWriteRetriesOnlyTheRemainderNoDuplicateBytes() throws {
        let (w, sink) = try makeWriter(header: "h", capacity: 2 + 6) // header "h\n" + 6 bytes
        w.append(line: "row1")
        w.append(line: "row2")
        XCTAssertThrowsError(try w.flush())                    // "row1\nr" written, "ow2\n" kept
        XCTAssertEqual(String(decoding: sink.data, as: UTF8.self), "h\nrow1\nr")
        sink.capacity = 1_000                                  // disk space freed
        w.append(line: "row3")
        try w.flush()
        XCTAssertEqual(String(decoding: sink.data, as: UTF8.self), "h\nrow1\nrow2\nrow3\n", "each byte exactly once")
        XCTAssertEqual(w.bytesWritten, Int64(sink.data.count))
    }

    func testCapTrimKeepsNewestWholeRowsIncludingOneStartingExactlyAtTheCut() throws {
        let (w, sink) = try makeWriter(header: "h", capacity: 2) // disk full right after the header
        w.maxRetryBytes = 8
        for r in ["AAA", "BBB", "CCC"] { w.append(line: r) }   // 12 bytes pending, cap 8 → cut at "BBB"
        XCTAssertThrowsError(try w.flush())
        sink.capacity = 1_000
        try w.flush()
        XCTAssertEqual(String(decoding: sink.data, as: UTF8.self), "h\nBBB\nCCC\n",
                       "the row starting exactly at the cut must be kept (off-by-one fix)")
    }

    func testCapTrimTerminatesAPartiallyWrittenRow() throws {
        let (w, sink) = try makeWriter(header: "h", capacity: 2 + 2) // fits "AA" of "AAAA\n"
        w.maxRetryBytes = 10
        for r in ["AAAA", "BBBB", "CCCC", "DDDD"] { w.append(line: r) }
        XCTAssertThrowsError(try w.flush())
        sink.capacity = 1_000
        try w.flush()
        let text = String(decoding: sink.data, as: UTF8.self)
        XCTAssertTrue(text.hasPrefix("h\nAA\n"), "torn row is terminated so later rows stay parseable: \(text)")
        XCTAssertTrue(text.hasSuffix("CCCC\nDDDD\n"))
        XCTAssertTrue(text.split(separator: "\n").allSatisfy { !$0.isEmpty })
    }
}

// MARK: - session.json compatibility and new public-transport fields

final class MetadataCompatibilityTests: XCTestCase {
    func testOldSessionJSONWithoutNewKeysAndWithUnknownKeysDecodes() throws {
        let old = """
        {"sessionId":"S","appVersion":"1.0.0","device":{"model":"iPhone15,2","name":"iPhone 14 Pro","iosVersion":"18.1"},
         "timezone":"Europe/Bucharest","startedAtUtc":"2026-11-21T09:12:03.512Z","startUptimeSec":1.5,"endedAtUtc":null,
         "vehicle":{"type":"car","makeModel":"","notes":""},
         "mount":{"location":"console","phoneOrientation":"up","rigid":true},
         "people":{"operatorSeat":"front passenger","raterSeat":"rear left","passengerCount":3},
         "conditions":{"weather":"dry","notes":""},"requestedRatesHz":{"accel":100},"recovered":false,
         "syntheticSensors":true,"folderName":"f","deviceId":"D","mockScenario":"cluj-demo-v1","stats":null}
        """
        let m = try JSONDecoder().decode(SessionMetadata.self, from: Data(old.utf8))
        XCTAssertNil(m.vehicle.line)
        XCTAssertFalse(m.mount.handheld)
        XCTAssertFalse(m.mount.seatOverAxle)
        XCTAssertEqual(m.people.raterPosture, "seated")
        XCTAssertEqual(m.people.raterName, "")
        XCTAssertNil(m.preflight)
    }

    func testNewFieldsAreWrittenWithExplicitNulls() throws {
        var m = SessionMetadataTests.sample()
        m.vehicle.type = "bus"
        m.mount.handheld = true
        m.people.raterPosture = "standing"
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: m.jsonData()) as? [String: Any])
        XCTAssertNil(obj["audioEnabled"], "no audio (D48): the key is no longer written")
        let vehicle = try XCTUnwrap(obj["vehicle"] as? [String: Any])
        XCTAssertTrue(vehicle["line"] is NSNull, "spec: line is null when not set")
        let mount = try XCTUnwrap(obj["mount"] as? [String: Any])
        XCTAssertEqual(mount["handheld"] as? Bool, true)
        XCTAssertEqual(mount["seatOverAxle"] as? Bool, false)
        XCTAssertTrue(mount["photoFile"] is NSNull, "spec shows photoFile; null when no photo")
        XCTAssertEqual((obj["people"] as? [String: Any])?["raterPosture"] as? String, "standing")
        XCTAssertEqual(try JSONDecoder().decode(SessionMetadata.self, from: m.jsonData()), m)
    }

    func testLineNumberOnlyAppliesToPublicTransport() {
        var s = SessionSetup()
        s.vehicle.type = "bus"; s.vehicle.line = "24B"
        s.applyVehicleTypeDefaults()
        XCTAssertEqual(s.vehicle.line, "24B")
        s.vehicle.type = "tram"; s.applyVehicleTypeDefaults()
        XCTAssertEqual(s.vehicle.line, "24B")
        s.vehicle.type = "car"; s.applyVehicleTypeDefaults()
        XCTAssertNil(s.vehicle.line, "line only applies to bus/tram")
    }

    func testUnreadableSessionJSONStillGetsCSVsRepairedAndIsKept() throws {
        let root = try makeTempDir()
        let store = SessionStore(root: root)
        let folder = try store.makeSessionFolder(start: Date(), id: UUID())
        try Data("{ not json".utf8).write(to: folder.appendingPathComponent("session.json"))
        try Data("t_up,t_utc_ms,x,y,z\n1.0,1,0,0,0\n1.01,1,0,".utf8).write(to: folder.appendingPathComponent("accel_raw.csv"))
        XCTAssertEqual(store.recoverUnfinishedSessions(), [])
        XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent("accel_raw.csv"), encoding: .utf8),
                       "t_up,t_utc_ms,x,y,z\n1.0,1,0,0,0\n")
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path))
        let log = try String(contentsOf: folder.appendingPathComponent("app_log.txt"), encoding: .utf8)
        XCTAssertTrue(log.contains("unreadable"))
    }
}

// MARK: - Labels: free text stays on one line

final class LabelSanitizeTests: XCTestCase {
    func testNewlinesAreFlattened() {
        XCTAssertEqual(RecordingSession.sanitize("tram\ncrossing\r\nrough\r"), "tram crossing rough")
        XCTAssertNil(RecordingSession.sanitize("  \n "))
        XCTAssertNil(RecordingSession.sanitize(nil))
        XCTAssertEqual(RecordingSession.sanitize("a, \"b\""), "a, \"b\"", "commas/quotes are handled by CSV escaping")
    }
}

// MARK: - Upload: poison batch, retry logging, http safety, connectivity probe

final class UploadRobustnessTests: XCTestCase {
    private func makeQueue(_ transport: MockTransport, events: Locked<[String]>? = nil) throws -> UploadQueue {
        let q = UploadQueue(directory: try makeTempDir().appendingPathComponent("upload_queue"), transport: transport,
                            config: { UploadConfig(baseURL: URL(string: "https://api.test"), deviceKey: "k") })
        if let events { q.onEvent = { _, m in events.withLock { $0.append(m) } } }
        return q
    }

    private func enqueue(_ q: UploadQueue, _ seq: Int, created: Int64) throws {
        try q.enqueue(gzippedBody: Gzip.compress(Data("{}".utf8)), sessionId: "S", seq: seq, createdUtcMs: created)
    }

    /// The ingest function answers 503 only for its own outages (storage, Event Hubs, Key Vault), never
    /// for a bad payload: however long the outage, nothing is re-ordered, parked or deleted.
    func testServerErrorsRetryInPlaceAndNeverReorder() async throws {
        let t = MockTransport()
        let events = Locked([String]())
        let q = try makeQueue(t, events: events)
        try enqueue(q, 0, created: 1_000)
        try enqueue(q, 1, created: 2_000)
        for code in [503, 500, 502, 504, 408, 429, 503, 503, 503, 503, 503, 503] { t.enqueue(code) }
        for _ in 0..<12 {
            guard case .retry = await q.processOnce() else { return XCTFail("server errors must be retried") }
        }
        XCTAssertEqual(Set(t.requests.compactMap { $0.value(forHTTPHeaderField: "x-idempotency-key") }), ["S:0"],
                       "the head file is retried, nothing jumps ahead of it")
        XCTAssertEqual(q.pendingFiles().map { UploadQueue.parse(fileName: $0.lastPathComponent)!.seq }, [0, 1])
        XCTAssertTrue(q.failedFiles().isEmpty)
        XCTAssertEqual(q.status.currentBackoff, UploadQueue.maxBackoff, "capped")
        for _ in 0..<2 { _ = await q.processOnce() }
        XCTAssertEqual(t.requests.suffix(2).map { $0.value(forHTTPHeaderField: "x-idempotency-key") }, ["S:0", "S:1"])
        XCTAssertTrue(q.pendingFiles().isEmpty)
        XCTAssertFalse(events.current.contains { $0.contains("back of the queue") })
    }

    func testNetworkErrorsNeverRotate() async throws {
        let t = MockTransport()
        let q = try makeQueue(t)
        try enqueue(q, 0, created: 1_000)
        try enqueue(q, 1, created: 2_000)
        for _ in 0..<8 { t.enqueueError(URLError(.notConnectedToInternet)) }
        for _ in 0..<8 { _ = await q.processOnce() }
        XCTAssertEqual(q.pendingFiles().map { UploadQueue.parse(fileName: $0.lastPathComponent)!.seq }, [0, 1])
    }

    func testRetryReasonIsLoggedOncePerChange() async throws {
        let t = MockTransport()
        let events = Locked([String]())
        let q = try makeQueue(t, events: events)
        try enqueue(q, 0, created: 1_000)
        t.enqueue(503, 503, 401)
        for _ in 0..<3 { _ = await q.processOnce() }
        XCTAssertEqual(events.current.filter { $0.hasPrefix("upload retry") },
                       ["upload retry: HTTP 503", "upload retry: HTTP 401 (check device key)"])
    }

    func testKickWakesALongBackoff() async throws {
        let t = MockTransport()
        let q = try makeQueue(t)
        try enqueue(q, 0, created: 1_000)
        t.enqueue(500, 500, 500, 500) // backoff 1, 2, 4, 8 s
        for _ in 0..<4 { _ = await q.processOnce() }
        XCTAssertEqual(q.status.currentBackoff, 8)
        q.start()
        defer { q.stop() }
        try await Task.sleep(nanoseconds: 300_000_000) // loop is now sleeping out its 8 s backoff…
        let kickedAt = Date()
        q.kick()
        while !q.pendingFiles().isEmpty && Date().timeIntervalSince(kickedAt) < ciTimeout { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertTrue(q.pendingFiles().isEmpty)
        // Bound well below the 8 s backoff but loose enough for slow CI simulators.
        XCTAssertLessThan(Date().timeIntervalSince(kickedAt), 7, "kick() must cut the 8 s backoff short")
    }

    func testPlainHTTPOnlyForLocalHosts() {
        XCTAssertNil(UploadConfig.parseBaseURL("http://api.example.com"), "device key must not travel in cleartext")
        XCTAssertNotNil(UploadConfig.parseBaseURL("https://abc.execute-api.eu-central-1.amazonaws.com"))
        for local in ["http://localhost:8765", "http://127.0.0.1:8765", "http://192.168.1.20:8765", "http://10.0.0.5",
                      "http://172.20.1.1", "http://my-mac.local:8765"] {
            XCTAssertNotNil(UploadConfig.parseBaseURL(local), local)
        }
        XCTAssertNil(UploadConfig.parseBaseURL("http://172.32.0.1"))
    }

    func testConnectionProbeContractAndInterpretation() async throws {
        let t = MockTransport()
        t.enqueue(400)
        let r = await UploadQueue.testConnection(config: UploadConfig(baseURL: URL(string: "https://api.test/v1"), deviceKey: "k"),
                                                 deviceId: "8C3F1A2B-0000-4000-8000-000000000001", transport: t)
        XCTAssertTrue(r.ok)
        let req = try XCTUnwrap(t.requests.first)
        XCTAssertEqual(req.httpMethod, "POST")
        XCTAssertEqual(req.url?.absoluteString, "https://api.test/v1/api/ingest")
        XCTAssertEqual(req.value(forHTTPHeaderField: "x-device-key"), "k")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Content-Encoding"), "gzip")
        // The probe names the device, so ingest can say whether the key is stored under this Device ID.
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: try Gzip.decompress(try XCTUnwrap(req.httpBody))) as? [String: Any])
        XCTAssertEqual(body["probe"] as? Bool, true)
        XCTAssertEqual(body["deviceId"] as? String, "8C3F1A2B-0000-4000-8000-000000000001")
        XCTAssertEqual(body.count, 2)
        XCTAssertTrue(UploadQueue.interpretProbe(status: 422).ok)
        XCTAssertFalse(UploadQueue.interpretProbe(status: 401).ok)
        let wrongDevice = UploadQueue.interpretProbe(status: 403)
        XCTAssertFalse(wrongDevice.ok)
        XCTAssertTrue(wrongDevice.detail.contains("Device ID"))
        XCTAssertFalse(UploadQueue.interpretProbe(status: 404).ok)
        XCTAssertFalse(UploadQueue.interpretProbe(status: 502).ok)
        // The few words Settings shows next to Test connection.
        XCTAssertEqual(UploadQueue.interpretProbe(status: 422).short, "Connected")
        XCTAssertEqual(UploadQueue.interpretProbe(status: 401).short, "Wrong device key")
        XCTAssertEqual(UploadQueue.interpretProbe(status: 404).short, "Wrong server address")
        XCTAssertEqual(UploadQueue.interpretProbe(status: 502).short, "Server error (HTTP 502)")
    }
}


// MARK: - RecordingController: alerts

@MainActor
final class FakeAlerter: Alerter {
    var problems = 0, labels = 0, stops = 0
    func prepare() {}
    func labelConfirmed() { labels += 1 }
    func newProblem() { problems += 1 }
    func stopped() { stops += 1 }
}

@MainActor
final class RecordingControllerTests: XCTestCase {
    private func makeController(device: FakeDeviceStatus = FakeDeviceStatus()) throws -> (RecordingController, FakeAlerter) {
        let deps = RecordingSession.Dependencies(
            motion: SyntheticMotionSource(), location: FakeLocationSource(), altimeter: FakeAltimeter(),
            activity: FakeActivity(), deviceStatus: device, uploadQueue: nil, deviceId: "D",
            appVersion: "t", deviceInfo: .init(model: "x", name: "x", iosVersion: "x"))
        let session = try RecordingSession(store: SessionStore(root: try makeTempDir()), setup: SessionSetup(),
                                           preflight: nil, deps: deps)
        let alerter = FakeAlerter()
        let c = RecordingController(session: session, alerter: alerter)
        return (c, alerter)
    }

    private func spin(_ seconds: TimeInterval) {
        let e = expectation(description: "spin")
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { e.fulfill() }
        wait(for: [e], timeout: seconds + ciTimeout)
    }

    /// Alert *policy* is tested exactly in IssueTrackerTests. Here only the wiring, asserted on the
    /// condition this test causes — never on global counts, which unrelated issues (e.g. a lagging
    /// synthetic sensor on a slow CI simulator) can legitimately change.
    func testLowPowerModeRaisesAProblemThatClearsWhenTurnedOff() throws {
        let device = FakeDeviceStatus()
        let (c, alerter) = try makeController(device: device)
        c.start()
        defer { c.stop() }
        device.status.lowPowerMode = true
        let before = alerter.problems
        c.refresh()
        XCTAssertTrue(c.issues.contains { $0.key == "lowpower" && $0.level == .problem })
        XCTAssertEqual(c.overall, .problem)
        XCTAssertGreaterThan(alerter.problems, before, "a new PROBLEM alerts the operator")
        device.status.lowPowerMode = false
        c.refresh()
        XCTAssertFalse(c.issues.contains { $0.key == "lowpower" })
    }

    /// D48: nothing from the microphone, no audio files or keys, no audio health rule.
    func testRecordingWritesNoAudio() throws {
        let (c, _) = try makeController()
        c.start()
        spin(0.5)
        XCTAssertFalse(c.issues.contains { $0.key.hasPrefix("audio") }, "\(c.issues)")
        c.stop()
        let folder = c.session.folder
        let files = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        XCTAssertFalse(files.contains { $0.hasPrefix("audio") }, "\(files)")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(contentsOf: folder.appendingPathComponent(SessionFileName.metadata))) as? [String: Any])
        XCTAssertNil(json["audioEnabled"])
        XCTAssertNil((json["requestedRatesHz"] as? [String: Any])?["audioLevel"])
        let stats = try XCTUnwrap(json["stats"] as? [String: Any])
        XCTAssertNil(stats["audioFiles"])
        XCTAssertNil(stats["audioFilesIncomplete"])
    }
}

// MARK: - Cross-language contract fixture

final class ContractFixtureTests: XCTestCase {
    /// Writes one real batch with the app's own encoder + gzip to tools/fixtures/, where
    /// tools/test_tools.py POSTs it to the mock ingest server (CI) — catches Swift/Python drift.
    func testWriteIngestContractFixture() throws {
        let acc = BatchAccumulator(sessionId: "00000000-0000-4000-8000-000000000001", deviceId: "FIXTURE-DEVICE")
        for i in 0..<5 {
            let t = 100 + Double(i) * 0.01
            acc.add(DeviceMotionSample(t: t, userAccel: Vec3(x: 0.01, y: -0.02, z: 0.03), gravity: Vec3(x: 0, y: 0, z: -1),
                                       rotationRate: Vec3(x: 0.1, y: 0, z: 0), quaternion: Quaternion(w: 1, x: 0, y: 0, z: 0),
                                       roll: 0, pitch: 0, yaw: 0))
            acc.addAccel(Vec3Sample(t: t, v: Vec3(x: 0, y: 0, z: -1)))
            acc.addGyro(Vec3Sample(t: t, v: .zero))
        }
        acc.add(LocationSample(utcMs: 1_763_716_532_120, lat: 46.77121, lon: 23.62363, alt: 352, ellAlt: 390, hAcc: 4.7,
                               vAcc: 3, speed: 8.4, speedAcc: 0.5, course: 92, courseAcc: 3, isSimulated: false))
        acc.add(AltimeterSample(t: 100.02, relativeAltitudeM: 0.1, pressureKPa: 97.2))
        acc.addLabel(t: 100.04, type: "pothole", value: nil, note: nil)
        acc.addLabel(t: 100.05, type: "note", value: nil, note: "a, \"quoted\" note")
        let device = DeviceStatus(batteryLevel: 0.8, batteryState: "charging", thermal: .nominal, lowPowerMode: false,
                                  freeDiskBytes: 1, networkStatus: "satisfied", networkType: "wifi")
        let batch = acc.drain(t0Up: 100, t0UtcMs: 1_763_716_532_000, device: device)
        let gz = try Gzip.compress(try batch.jsonData())
        XCTAssertEqual(try Gzip.decompress(gz), try batch.jsonData(), "deterministic encoding (sortedKeys)")
        try checkFixture("ingest_batch_v1.json.gz", gz)
    }

    /// §6.1 Stop-copy body exactly as the app builds it; tools/test_tools.py PUTs it to the mock backend.
    func testSessionMetadataStopFixture() throws {
        var m = SessionMetadataTests.sample()
        m.sessionId = "00000000-0000-4000-8000-000000000001"
        m.endedAtUtc = "2026-11-21T10:00:00.000Z"
        m.vehicle.type = "bus"; m.vehicle.line = "24B"
        // sicknessRatings: 1 matches the committed (pre-D47) fixture; the app now always writes 0.
        m.stats = .init(durationSec: 2808.488, streams: [:], labelsCount: 3, sicknessRatings: 1, sicknessMissed: 0,
                        fileSizes: [:], totalBytes: 1, writeErrors: 0, uploadBatchesCreated: 3)
        let body = try RecordingSession.sessionMetadataBody(m, batchCount: 3)
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(obj["batchCount"] as? Int, 3)
        XCTAssertEqual(obj["sessionId"] as? String, m.sessionId)
        try checkFixture("session_meta_stop_v1.json.gz", Gzip.compress(body))
    }

    /// Header line per CSV file: the single source of truth that tools/quick_check.py is tested against.
    func testCSVHeadersFixture() throws {
        var map: [String: String] = [:]
        for f in StreamFile.allCases { map[f.rawValue] = f.header }
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try checkFixture("csv_headers.json", enc.encode(map) + Data("\n".utf8))
    }

    /// Compares with the committed fixture (a change in the app's output must be deliberate).
    /// Regenerate with: TEST_RUNNER_REGENERATE_FIXTURES=1 xcodebuild … -only-testing:SensorRecorderTests/ContractFixtureTests test
    private func checkFixture(_ name: String, _ data: Data) throws {
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("tools/fixtures", isDirectory: true)
        let url = dir.appendingPathComponent(name)
        if ProcessInfo.processInfo.environment["REGENERATE_FIXTURES"] == "1" {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            return
        }
        let committed = try Data(contentsOf: url)
        XCTAssertEqual(committed, data, "\(name) differs from the app's output: if intended, regenerate the fixture")    }
}
