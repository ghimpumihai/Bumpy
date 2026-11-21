import XCTest
@testable import SensorRecorder

// Tests for the third multi-perspective review (hackathon requirements, red team, security,
// architecture, empirical E2E). Each pins a finding.

// MARK: - Security: URL allow-list, redirects, 404

final class UploadSecurityTests: XCTestCase {
    func testHttpAllowListCannotBeBypassedWithLookalikeHosts() {
        for bad in ["http://192.168.1.1.attacker.com", "http://10.0.0.1.evil.com", "http://evil.192.168.0.1.com",
                    "http://+10.0.0.1", "http://010.0.0.1", "http://192.168.1", "http://192.168.1.1.",
                    "http://localhost.evil.com", "http://user:pw@192.168.1.5", "http://192.168.1.5/?k=v",
                    "http://192.168.1.5/#frag", "http://.local", "https://user@api.example.com"] {
            XCTAssertNil(UploadConfig.parseBaseURL(bad), bad)
        }
        for ok in ["http://192.168.1.20:8765", "http://10.0.0.5", "http://172.16.0.1", "http://127.0.0.1:8765",
                   "http://localhost:8765", "http://my-mac.local:8765", "https://abc.execute-api.eu-central-1.amazonaws.com/prod"] {
            XCTAssertNotNil(UploadConfig.parseBaseURL(ok), ok)
        }
    }

    func testRedirectsAreRefused() {
        let delegate = URLSessionTransport.NoRedirects.shared
        let resp = HTTPURLResponse(url: URL(string: "https://api.test/api/ingest")!, statusCode: 307,
                                   httpVersion: nil, headerFields: ["Location": "https://evil.test/collect"])!
        let exp = expectation(description: "decided")
        delegate.urlSession(URLSession.shared, task: URLSession.shared.dataTask(with: URL(string: "https://api.test")!),
                            willPerformHTTPRedirection: resp, newRequest: URLRequest(url: URL(string: "https://evil.test")!)) { req in
            XCTAssertNil(req, "the key header must never be forwarded to another host")
            exp.fulfill()
        }
        wait(for: [exp], timeout: ciTimeout)
    }

    func testWrongAPIPath404IsRetriedNotDumpedIntoFailed() async throws {
        let t = MockTransport()
        let q = UploadQueue(directory: try makeTempDir().appendingPathComponent("q"), transport: t,
                            config: { UploadConfig(baseURL: URL(string: "https://api.test/wrong"), deviceKey: "k") })
        for i in 0..<3 {
            try q.enqueue(gzippedBody: Gzip.compress(Data("{}".utf8)), sessionId: "S", seq: i, createdUtcMs: Int64(1000 + i))
        }
        t.enqueue(404, 404, 404)
        for _ in 0..<3 {
            guard case .retry = await q.processOnce() else { return XCTFail("404 must be retried") }
        }
        XCTAssertEqual(q.pendingFiles().count, 3, "nothing lost or moved")
        XCTAssertTrue(q.failedFiles().isEmpty)
        XCTAssertTrue(q.status.lastError?.contains("API URL") == true)
    }
}

// MARK: - Session deletion (GDPR retention)

final class SessionDeletionTests: XCTestCase {
    func testDeleteOnlyInsideRoot() throws {
        let root = try makeTempDir()
        let store = SessionStore(root: root.appendingPathComponent("sessions"))
        let folder = try store.makeSessionFolder(start: Date(), id: UUID())
        try Data("x".utf8).write(to: folder.appendingPathComponent("accel_raw.csv"))
        XCTAssertThrowsError(try store.deleteSession(root), "must refuse anything that is not a session folder")
        try store.deleteSession(folder)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
        XCTAssertTrue(store.list().isEmpty)
    }
}

// MARK: - Verdict, recovery, writer after close

final class SessionVerdictTests: XCTestCase {
    private func meta(_ streams: [String: SessionMetadata.StreamStats], writeErrors: Int = 0) -> SessionMetadata {
        var m = SessionMetadataTests.sample()
        m.stats = .init(durationSec: 60, streams: streams, labelsCount: 0,
                        fileSizes: [:], totalBytes: 0, writeErrors: writeErrors, uploadBatchesCreated: 0)
        return m
    }
    private func s(_ n: Int64, gap: Double) -> SessionMetadata.StreamStats {
        .init(samples: n, meanRateHz: 100, maxGapSec: gap, gapsOver1s: gap > 1 ? 1 : 0, droppedEstimate: 0, fileBytes: nil)
    }

    func testVerdict() {
        let good = ["deviceMotion": s(6000, gap: 0.02), "accel": s(6000, gap: 0.02), "gyro": s(6000, gap: 0.02),
                    "gps": s(60, gap: 1.01), "barometer": s(10, gap: 40)]
        XCTAssertTrue(SessionVerdict(metadata: meta(good)).ok, "1 Hz GPS jitter and slow barometer are not gaps")
        XCTAssertEqual(SessionVerdict(metadata: meta(good)).text, "All streams OK")
        var gap = good; gap["accel"] = s(6000, gap: 1.5)
        XCTAssertEqual(SessionVerdict(metadata: meta(gap)).gaps, ["Accel raw"])
        var missing = good; missing["gps"] = s(0, gap: 0)
        XCTAssertEqual(SessionVerdict(metadata: meta(missing)).missing, ["GPS"])
        XCTAssertFalse(SessionVerdict(metadata: meta(good, writeErrors: 2)).ok)
    }
}

final class RecoveryRound3Tests: XCTestCase {

    func testRecoveredDurationIsMeasuredFromTheSessionStart() throws {
        let root = try makeTempDir()
        let store = SessionStore(root: root)
        let folder = try store.makeSessionFolder(start: Date(), id: UUID())
        var m = SessionMetadataTests.sample()
        m.startUptimeSec = 1000
        try m.write(to: folder.appendingPathComponent("session.json"))
        // activity row from long before the session (current CMMotionActivity) must not inflate duration
        try Data("t_up,t_utc_ms,stationary,walking,running,automotive,cycling,unknown,confidence,start_utc_ms\n10,1,0,0,0,1,0,0,2,1\n".utf8)
            .write(to: folder.appendingPathComponent("activity.csv"))
        try Data("t_up,t_utc_ms,x,y,z\n1000.5,1,0,0,0\n1060.0,1,0,0,0\n".utf8)
            .write(to: folder.appendingPathComponent("accel_raw.csv"))
        store.recoverUnfinishedSessions()
        let r = try SessionMetadata.load(from: folder.appendingPathComponent("session.json"))
        XCTAssertEqual(r.stats?.durationSec ?? 0, 60, accuracy: 1e-6)
        XCTAssertEqual(r.stats?.fileSizes["app_log.txt"], FileManager.default.fileSize(folder.appendingPathComponent("app_log.txt")),
                       "sizes are measured after the recovery note is written")
    }

    func testWriterRefusesAppendsAfterClose() throws {
        let url = try makeTempDir().appendingPathComponent("x.csv")
        let w = try BufferedFileWriter(url: url, header: "h")
        w.append(line: "a")
        try w.close()
        w.append(line: "late")
        XCTAssertEqual(w.droppedAfterClose.current, 1)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "h\na\n")
    }
}

// MARK: - Health: location permission

final class HealthRound3Tests: XCTestCase {
    private func base() -> HealthInputs {
        var i = HealthInputs(now: 1060, recordingStartUp: 1000)
        i.gpsLastFixUp = 1059.5
        return i
    }

    func testLocationPermissionLossIsAProblem() {
        var i = base()
        i.locationDegraded = "Precise Location is OFF: GPS is approximate"
        let issues = HealthEvaluator.evaluate(i)
        XCTAssertEqual(issues.map(\.key), ["gps.permission"])
        XCTAssertEqual(issues.first?.level, .problem)
    }
}

// MARK: - GPS: cached and pre-start fixes

/// Location fake that delivers exactly the fixes it is given.
final class ScriptedLocation: LocationSource {
    let fixes: [LocationSample]
    init(_ fixes: [LocationSample]) { self.fixes = fixes }
    func startRecording(_ callbacks: LocationCallbacks) { fixes.forEach(callbacks.location) }
    func stopRecording() {}
}

final class GPSFixTests: XCTestCase {
    func testStaleCachedFixDroppedEarlyFixKeptButNotCounted() throws {
        let nowMs = Date().timeIntervalSince1970 * 1000
        func fix(ageSec: Double) -> LocationSample {
            LocationSample(utcMs: nowMs - ageSec * 1000, lat: 46.77, lon: 23.62, alt: 350, ellAlt: 390, hAcc: 5, vAcc: 3,
                           speed: 0, speedAcc: 1, course: -1, courseAcc: -1, isSimulated: nil)
        }
        // 300 s old (another place, earlier) → dropped; 2 s old → written, not counted; 0 s → counted
        let deps = RecordingSession.Dependencies(
            motion: SyntheticMotionSource(), location: ScriptedLocation([fix(ageSec: 300), fix(ageSec: 2)]),
            altimeter: nil, activity: nil, deviceStatus: FakeDeviceStatus(), uploadQueue: nil,
            deviceId: "D", appVersion: "t", deviceInfo: .init(model: "x", name: "x", iosVersion: "x"))
        let session = try RecordingSession(store: SessionStore(root: try makeTempDir()), setup: SessionSetup(),
                                           preflight: nil, deps: deps)
        let e = expectation(description: "run")
        DispatchQueue.main.async {
            session.start()
            session.stop()
            e.fulfill()
        }
        wait(for: [e], timeout: ciTimeout)
        let rows = try readCSV(session.folder.appendingPathComponent("location.csv")).rows
        XCTAssertEqual(rows.count, 1, "the 300 s old cached fix must not be recorded")
        XCTAssertEqual(session.metadata.stats?.streams["gps"]?.samples ?? -1, 0, "pre-start fix not counted in GPS stats")
        let log = try String(contentsOf: session.folder.appendingPathComponent("app_log.txt"), encoding: .utf8)
        XCTAssertTrue(log.contains("ignored cached GPS fix"))
    }
}

// MARK: - Every CSV row matches its header (every file a recording writes)

final class AllFilesRowShapeTests: XCTestCase {
    func testEveryWrittenRowHasExactlyTheHeaderColumnCount() throws {
        let deps = RecordingSession.Dependencies(
            motion: SyntheticMotionSource(), location: FakeLocationSource(), altimeter: FakeAltimeter(),
            activity: FakeActivity(), deviceStatus: FakeDeviceStatus(), uploadQueue: nil,
            deviceId: "D", appVersion: "t", deviceInfo: .init(model: "x", name: "x", iosVersion: "x"))
        let session = try RecordingSession(store: SessionStore(root: try makeTempDir()), setup: SessionSetup(),
                                           preflight: nil, deps: deps)
        let e = expectation(description: "run")
        DispatchQueue.main.async {
            session.start()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { session.stop(); e.fulfill() }
        }
        wait(for: [e], timeout: ciTimeout)
        for file in StreamFile.recorded {
            let text = try String(contentsOf: session.folder.appendingPathComponent(file.fileName), encoding: .utf8)
            let lines = text.split(separator: "\n").map(String.init)
            XCTAssertEqual(lines.first, file.header, file.rawValue)
            for line in lines.dropFirst() {
                XCTAssertEqual(csvFieldCount(line), file.columns.count + 2, "\(file.rawValue): \(line)")
            }
        }
    }

    /// RFC 4180 field count (commas inside quotes don't split).
    private func csvFieldCount(_ line: String) -> Int {
        var n = 1, inQuotes = false
        for c in line {
            if c == "\"" { inQuotes.toggle() } else if c == ",", !inQuotes { n += 1 }
        }
        return n
    }
}

// MARK: - Spec §6.1 session metadata through the upload queue

final class SessionMetadataUploadTests: XCTestCase {
    func testFileNamesSortIntoSendOrder() {
        let id = "S"
        let start = UploadQueue.fileName(createdUtcMs: 1_000, sessionId: id, item: .sessionMeta(phase: .start))
        let b0 = UploadQueue.fileName(createdUtcMs: 3_000, sessionId: id, item: .batch(seq: 0))
        let bLast = UploadQueue.fileName(createdUtcMs: 9_000, sessionId: id, item: .batch(seq: 3))
        let stop = UploadQueue.fileName(createdUtcMs: 9_000, sessionId: id, item: .sessionMeta(phase: .stop)) // same ms
        XCTAssertEqual([stop, bLast, b0, start].sorted(), [start, b0, bLast, stop])
        XCTAssertEqual(UploadQueue.parseItem(fileName: stop)?.item, .sessionMeta(phase: .stop))
        XCTAssertNil(UploadQueue.parse(fileName: stop), "batch-only parser ignores metadata files")
        XCTAssertEqual(UploadQueue.parseItem(fileName: b0)?.idempotencyKey, "S:0")
        XCTAssertEqual(UploadQueue.parseItem(fileName: start)?.idempotencyKey, "S:meta-start")
        XCTAssertNil(UploadQueue.parseItem(fileName: "1_S_meta-pause.json.gz"))
    }

    func testMetadataIsSentAsPUTToTheSessionURL() async throws {
        let t = MockTransport()
        let q = UploadQueue(directory: try makeTempDir().appendingPathComponent("q"), transport: t,
                            config: { UploadConfig(baseURL: URL(string: "https://fn.test/base"), deviceKey: "k") })
        try q.enqueueSessionMetadata(json: Data(#"{"sessionId":"S"}"#.utf8), sessionId: "S", phase: .start, createdUtcMs: 1)
        try q.enqueue(gzippedBody: Gzip.compress(Data("{}".utf8)), sessionId: "S", seq: 0, createdUtcMs: 2)
        _ = await q.processOnce()
        _ = await q.processOnce()
        XCTAssertEqual(t.requests.map(\.httpMethod), ["PUT", "POST"])
        let put = t.requests[0]
        XCTAssertEqual(put.url?.absoluteString, "https://fn.test/base/api/ingest/sessions/S")
        XCTAssertEqual(put.value(forHTTPHeaderField: "Content-Encoding"), "gzip")
        XCTAssertEqual(put.value(forHTTPHeaderField: "x-device-key"), "k")
        XCTAssertEqual(put.value(forHTTPHeaderField: "x-idempotency-key"), "S:meta-start")
        XCTAssertEqual(String(decoding: try Gzip.decompress(try XCTUnwrap(put.httpBody)), as: UTF8.self), #"{"sessionId":"S"}"#)
        XCTAssertEqual(t.requests[1].url?.absoluteString, "https://fn.test/base/api/ingest")
        XCTAssertTrue(q.pendingFiles().isEmpty)
    }

    func testMetadataIsNeverReorderedBehindBatches() async throws {
        let t = MockTransport()
        let q = UploadQueue(directory: try makeTempDir().appendingPathComponent("q"), transport: t,
                            config: { UploadConfig(baseURL: URL(string: "https://fn.test"), deviceKey: "k") })
        try q.enqueueSessionMetadata(json: Data("{}".utf8), sessionId: "S", phase: .start, createdUtcMs: 1)
        try q.enqueue(gzippedBody: Gzip.compress(Data("{}".utf8)), sessionId: "S", seq: 0, createdUtcMs: 2)
        for _ in 0..<20 { t.enqueue(503) }
        for _ in 0..<20 { _ = await q.processOnce() }
        // 02 D33: context first. An outage (503) neither moves the Start copy behind batch 0 nor parks it.
        XCTAssertTrue(q.failedFiles().isEmpty, "an outage must not park session metadata")
        XCTAssertEqual(q.pendingFiles().compactMap { UploadQueue.parseItem(fileName: $0.lastPathComponent)?.item },
                       [.sessionMeta(phase: .start), .batch(seq: 0)])
        XCTAssertEqual(Set(t.requests.map(\.httpMethod)), ["PUT"], "batch 0 never overtakes the Start copy")
    }

    /// Spec §6.1 "Until this exists, the backend creates the trip from its first batch": a backend
    /// without the PUT route must not block the batches behind the Start copy.
    func testMissingMetadataRouteDoesNotBlockBatches() async throws {
        for code in [404, 405] {
            let t = MockTransport()
            let q = UploadQueue(directory: try makeTempDir().appendingPathComponent("q"), transport: t,
                                config: { UploadConfig(baseURL: URL(string: "https://fn.test"), deviceKey: "k") })
            try q.enqueueSessionMetadata(json: Data("{}".utf8), sessionId: "S", phase: .start, createdUtcMs: 1)
            try q.enqueue(gzippedBody: Gzip.compress(Data("{}".utf8)), sessionId: "S", seq: 0, createdUtcMs: 2)
            let grace = UploadQueue.maxMetadataNotFoundAttempts
            for _ in 0..<grace { t.enqueue(code) }
            t.enqueue(201)
            // A redeploy (transient 404) or a URL fixed later must not lose the copy: retried first…
            for _ in 0..<(grace - 1) {
                guard case .retry = await q.processOnce() else { return XCTFail("metadata \(code) is retried first") }
            }
            XCTAssertTrue(q.failedFiles().isEmpty)
            // …then set aside, so a backend without the PUT route doesn't block the batches for good.
            let parked = await q.processOnce()
            XCTAssertEqual(parked, .permanentFailure(status: code))
            let next = await q.processOnce()
            XCTAssertEqual(next, .uploaded(status: 201), "batch 0 still goes out")
            XCTAssertEqual(t.requests.map(\.httpMethod), Array(repeating: "PUT", count: grace) + ["POST"])
            XCTAssertTrue(q.pendingFiles().isEmpty)
            XCTAssertEqual(q.failedFiles().count, 1)
        }
        // …while a batch 404 (wrong API URL) is still retried, never dumped:
        let t = MockTransport()
        let q = UploadQueue(directory: try makeTempDir().appendingPathComponent("q"), transport: t,
                            config: { UploadConfig(baseURL: URL(string: "https://fn.test"), deviceKey: "k") })
        try q.enqueue(gzippedBody: Gzip.compress(Data("{}".utf8)), sessionId: "S", seq: 0, createdUtcMs: 2)
        t.enqueue(404, 405)
        guard case .retry = await q.processOnce() else { return XCTFail("batch 404 must be retried") }
        let r405 = await q.processOnce()
        XCTAssertEqual(r405, .permanentFailure(status: 405), "a batch 405 is an ordinary 4xx")
    }

    func testCloudCopyDropsRaterNameAndTagsSource() throws {
        var m = SessionMetadataTests.sample()
        m.people.raterName = "Ana Popescu"
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: RecordingSession.sessionMetadataBody(m, batchCount: nil))
                                as? [String: Any])
        XCTAssertNil((obj["people"] as? [String: Any])?["raterName"], "personal data stays on the phone")
        XCTAssertEqual((obj["people"] as? [String: Any])?["raterSeat"] as? String, m.people.raterSeat)
        XCTAssertEqual(obj["source"] as? String, "live")
        XCTAssertNil(obj["batchCount"])
        XCTAssertTrue(String(decoding: try m.jsonData(), as: UTF8.self).contains("Ana Popescu"), "local session.json keeps it")
    }

    private func runSession(uploadOn: Locked<Bool>, seconds: TimeInterval, toggleOnAfter: TimeInterval? = nil) throws
        -> (RecordingSession, UploadQueue) {
        let q = UploadQueue(directory: try makeTempDir().appendingPathComponent("q"), transport: MockTransport(),
                            config: { uploadOn.current ? UploadConfig(baseURL: URL(string: "https://fn.test"), deviceKey: "k") : .disabled })
        let deps = RecordingSession.Dependencies(
            motion: SyntheticMotionSource(), location: nil, altimeter: nil, activity: nil,
            deviceStatus: FakeDeviceStatus(), uploadQueue: q, deviceId: "D", appVersion: "t",
            deviceInfo: .init(model: "x", name: "x", iosVersion: "x"))
        let session = try RecordingSession(store: SessionStore(root: try makeTempDir()), setup: SessionSetup(),
                                           preflight: nil, deps: deps)
        let e = expectation(description: "run")
        DispatchQueue.main.async {
            session.start()
            if let after = toggleOnAfter {
                DispatchQueue.main.asyncAfter(deadline: .now() + after) { uploadOn.withLock { $0 = true } }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { session.stop(); e.fulfill() }
        }
        wait(for: [e], timeout: ciTimeout)
        return (session, q)
    }

    func testUploadOffQueuesNothing() throws {
        let (session, q) = try runSession(uploadOn: Locked(false), seconds: 2.5)
        XCTAssertTrue(q.pendingFiles().isEmpty, "upload OFF: no metadata, no batches")
        XCTAssertEqual(session.metadata.stats?.uploadBatchesCreated, 0)
    }

    func testBatchSeqIsContiguousWhenUploadIsTurnedOnMidSession() throws {
        let (session, q) = try runSession(uploadOn: Locked(false), seconds: 5.0, toggleOnAfter: 2.5)
        let seqs = q.pendingFiles().compactMap { UploadQueue.parse(fileName: $0.lastPathComponent)?.seq }
        XCTAssertFalse(seqs.isEmpty)
        XCTAssertEqual(seqs, Array(0..<seqs.count), "no gaps: windows while upload was OFF don't consume a seq")
        XCTAssertEqual(session.metadata.stats?.uploadBatchesCreated, seqs.count)
    }

    func testRealistic2SecondBatchIsFarBelowTheBackendLimit() throws {
        var rng = SeededGenerator(seed: 42)
        func r() -> Double { Double.random(in: -2...2, using: &rng) }
        let acc = BatchAccumulator(sessionId: UUID().uuidString, deviceId: UUID().uuidString)
        for i in 0..<220 { // 2.2 s at 100 Hz with full-precision noisy values
            let t = 100 + Double(i) * 0.01
            acc.add(DeviceMotionSample(t: t, userAccel: Vec3(x: r(), y: r(), z: r()), gravity: Vec3(x: r(), y: r(), z: r()),
                                       rotationRate: Vec3(x: r(), y: r(), z: r()), quaternion: Quaternion(w: r(), x: r(), y: r(), z: r()),
                                       roll: r(), pitch: r(), yaw: r()))
            acc.addAccel(Vec3Sample(t: t, v: Vec3(x: r(), y: r(), z: r())))
            acc.addGyro(Vec3Sample(t: t, v: Vec3(x: r(), y: r(), z: r())))
        }
        let json = try acc.drain(t0Up: 100, t0UtcMs: 1_763_716_532_000, device: FakeDeviceStatus().status).jsonData()
        XCTAssertLessThan(json.count, RecordingSession.maxBatchJSONBytes / 2, "\(json.count) bytes")
    }
}

// MARK: - 02 D32: every batch carries the full dataset

final class FullDatasetBatchTests: XCTestCase {
    func testBatchCarriesEveryStreamOfTheSessionFolder() throws {
        let acc = BatchAccumulator(sessionId: "S", deviceId: "D")
        acc.add(DeviceMotionSample(t: 100.01, userAccel: .zero, gravity: Vec3(x: 0, y: 0, z: -1), rotationRate: .zero,
                                   quaternion: Quaternion(w: 1, x: 0, y: 0, z: 0), roll: 0.1, pitch: -0.2, yaw: 1.5))
        acc.addMag(Vec3Sample(t: 100.02, v: Vec3(x: 20, y: -5, z: -40)))
        acc.add(HeadingSample(utcMs: 1_763_716_532_100, magneticHeading: 91, trueHeading: 95, accuracy: 10,
                              raw: Vec3(x: 1, y: 2, z: 3)))
        acc.add(AbsoluteAltitudeSample(t: 100.5, altitudeM: 352, accuracyM: 3.5, precisionM: 0.4))
        acc.add(ActivitySample(t: 100.6, stationary: false, walking: false, running: false, automotive: true,
                               cycling: false, unknown: false, confidence: 2, startUtcMs: 1_763_716_500_000))
        acc.add(LocationSample(utcMs: 1_763_716_532_120, lat: 46.77, lon: 23.62, alt: 352, ellAlt: 390, hAcc: 4.7,
                               vAcc: 3.1, speed: 8.4, speedAcc: 0.5, course: 92, courseAcc: 4.5, isSimulated: false))
        let device = DeviceStatus(batteryLevel: 0.8, batteryState: "charging", thermal: .fair, lowPowerMode: false,
                                  freeDiskBytes: 42_000_000_000, networkStatus: "satisfied", networkType: "cellular")
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: acc.drain(t0Up: 100, t0UtcMs: 1_763_716_532_000,
                                                                             device: device).jsonData()) as? [String: Any])
        let dm = try XCTUnwrap(obj["deviceMotion"] as? [String: [Double]])
        XCTAssertEqual(dm["roll"], [0.1]); XCTAssertEqual(dm["pitch"], [-0.2]); XCTAssertEqual(dm["yaw"], [1.5])
        let mag = try XCTUnwrap(obj["magRaw"] as? [String: [Double]])
        XCTAssertEqual(mag["x"], [20]); XCTAssertEqual(mag["t"]?.first ?? -1, 0.02, accuracy: 1e-9)
        let heading = try XCTUnwrap((obj["heading"] as? [[String: Any]])?.first)
        XCTAssertEqual(heading["trueHeading"] as? Double, 95)
        XCTAssertEqual((heading["tUtcMs"] as? NSNumber)?.int64Value, 1_763_716_532_100)
        let abs = try XCTUnwrap(obj["absAltitude"] as? [String: [Double]])
        XCTAssertEqual(abs["altitudeM"], [352])
        let act = try XCTUnwrap((obj["activity"] as? [[String: Any]])?.first)
        XCTAssertEqual(act["automotive"] as? Bool, true)
        XCTAssertEqual(act["confidence"] as? Int, 2)
        let loc = try XCTUnwrap((obj["location"] as? [[String: Any]])?.first)
        XCTAssertEqual(loc["ellAlt"] as? Double, 390); XCTAssertEqual(loc["vAcc"] as? Double, 3.1)
        XCTAssertEqual(loc["courseAcc"] as? Double, 4.5)
        let dev = try XCTUnwrap(obj["device"] as? [String: Any])
        XCTAssertEqual(dev["batteryState"] as? String, "charging")
        XCTAssertEqual((dev["freeDiskBytes"] as? NSNumber)?.int64Value, 42_000_000_000)
        XCTAssertEqual(dev["netType"] as? String, "cellular")
        let units = try XCTUnwrap(obj["fieldUnits"] as? [String: String])
        for k in ["magRaw", "deviceMotion.roll", "heading.trueHeading", "absAltitude.altitudeM", "activity.confidence",
                  "location.ellAlt", "device.freeDiskBytes"] {
            XCTAssertNotNil(units[k], "unit documented for \(k)")
        }
    }
}

// MARK: - Alert policy (pure, exact)

final class IssueTrackerTests: XCTestCase {
    private func issue(_ key: String, _ level: HealthLevel) -> HealthIssue { .init(level: level, key: key, message: key) }

    func testAlertsOnNewProblemOnceAndAgainAfterItResolved() {
        var t = IssueTracker()
        XCTAssertFalse(t.update([]).alert)
        let first = t.update([issue("lowpower", .problem)])
        XCTAssertTrue(first.alert)
        XCTAssertEqual(first.appeared.map(\.key), ["lowpower"])
        for _ in 0..<5 { XCTAssertEqual(t.update([issue("lowpower", .problem)]), .init(), "persisting: no re-alert, no log") }
        let gone = t.update([])
        XCTAssertEqual(gone.resolved, ["lowpower"])
        XCTAssertFalse(gone.alert)
        XCTAssertTrue(t.update([issue("lowpower", .problem)]).alert, "comes back: alerts again")
    }

    func testWarnDoesNotAlertButEscalationToProblemDoes() {
        var t = IssueTracker()
        let warn = t.update([issue("rate.gyro", .warn)])
        XCTAssertFalse(warn.alert)
        XCTAssertEqual(warn.appeared.count, 1, "a new WARN is logged")
        let esc = t.update([issue("rate.gyro", .problem)])
        XCTAssertTrue(esc.alert, "WARN → PROBLEM alerts")
        let deesc = t.update([issue("rate.gyro", .warn)])
        XCTAssertFalse(deesc.alert)
        XCTAssertEqual(deesc.appeared.map(\.level), [.warn], "de-escalation is logged, not alerted")
    }

    func testAnUnrelatedProblemAlertsIndependently() {
        var t = IssueTracker()
        _ = t.update([issue("lowpower", .problem)])
        let both = t.update([issue("lowpower", .problem), issue("stale.deviceMotion", .problem)])
        XCTAssertTrue(both.alert)
        XCTAssertEqual(both.appeared.map(\.key), ["stale.deviceMotion"])
    }
}
