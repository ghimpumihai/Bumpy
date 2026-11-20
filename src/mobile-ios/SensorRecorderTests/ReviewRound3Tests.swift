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

    func testClearPendingOnlyForOneSession() throws {
        let q = UploadQueue(directory: try makeTempDir().appendingPathComponent("q"), transport: MockTransport(),
                            config: { .disabled })
        try q.enqueue(gzippedBody: Data([1]), sessionId: "A", seq: 0, createdUtcMs: 1)
        try q.enqueue(gzippedBody: Data([1]), sessionId: "B", seq: 0, createdUtcMs: 2)
        q.clearPending(sessionId: "A")
        XCTAssertEqual(q.pendingFiles().map { UploadQueue.parse(fileName: $0.lastPathComponent)!.sessionId }, ["B"])
        XCTAssertEqual(q.status.queueCount, 1)
    }
}

// MARK: - Session deletion (GDPR retention)

final class SessionDeletionTests: XCTestCase {
    func testDeleteOnlyInsideRoot() throws {
        let root = try makeTempDir()
        let store = SessionStore(root: root.appendingPathComponent("sessions"))
        let folder = try store.makeSessionFolder(start: Date(), id: UUID())
        try Data("x".utf8).write(to: folder.appendingPathComponent("audio_000.m4a"))
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
        m.stats = .init(durationSec: 60, streams: streams, labelsCount: 0, sicknessRatings: 0, sicknessMissed: 0,
                        audioFiles: [], fileSizes: [:], totalBytes: 0, writeErrors: writeErrors, uploadBatchesCreated: 0)
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
    private func box(_ type: String, payload: Int) -> Data {
        var d = Data()
        let size = UInt32(8 + payload)
        d.append(contentsOf: [UInt8(size >> 24), UInt8((size >> 16) & 0xff), UInt8((size >> 8) & 0xff), UInt8(size & 0xff)])
        d.append(contentsOf: Array(type.utf8))
        d.append(Data(repeating: 0, count: payload))
        return d
    }

    func testDetectsAudioWithoutMoovIndex() throws {
        let dir = try makeTempDir()
        try (box("ftyp", payload: 16) + box("mdat", payload: 1000) + box("moov", payload: 40))
            .write(to: dir.appendingPathComponent("audio_000.m4a"))
        try (box("ftyp", payload: 16) + box("mdat", payload: 1000)) // crashed while recording
            .write(to: dir.appendingPathComponent("audio_001.m4a"))
        XCTAssertEqual(SessionAnalyzer.unplayableAudioFiles(in: dir), ["audio_001.m4a"])
    }

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
        try (box("ftyp", payload: 8) + box("mdat", payload: 100)).write(to: folder.appendingPathComponent("audio_000.m4a"))
        store.recoverUnfinishedSessions()
        let r = try SessionMetadata.load(from: folder.appendingPathComponent("session.json"))
        XCTAssertEqual(r.stats?.durationSec ?? 0, 60, accuracy: 1e-6)
        XCTAssertEqual(r.stats?.audioFilesIncomplete, ["audio_000.m4a"])
        let log = try String(contentsOf: folder.appendingPathComponent("app_log.txt"), encoding: .utf8)
        XCTAssertTrue(log.contains("audio_000.m4a has no index"))
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

// MARK: - Health: silent mic, location permission

final class HealthRound3Tests: XCTestCase {
    private func base() -> HealthInputs {
        var i = HealthInputs(now: 1060, recordingStartUp: 1000)
        i.gpsLastFixUp = 1059.5
        i.audioExpected = false
        i.audioMeterExpected = true
        i.streams[.audioLevel] = StreamSnapshot(id: .audioLevel, count: 600, rateHz: 10, age: 0.1, meanRateHz: 10,
                                                maxGap: 0.1, gapsOver1s: 0, droppedEstimate: 0, available: true)
        return i
    }

    func testSilentMeterMeansDeniedOrBlockedMic() {
        var i = base()
        i.audioLastSoundUp = 1059
        XCTAssertTrue(HealthEvaluator.evaluate(i).isEmpty)
        i.audioLastSoundUp = 1040
        XCTAssertEqual(HealthEvaluator.evaluate(i).map(\.key), ["audio.silent"])
        i.audioLastSoundUp = nil // never any sound since start (60 s)
        XCTAssertEqual(HealthEvaluator.evaluate(i).first?.level, .warn)
    }

    func testLocationPermissionLossIsAProblem() {
        var i = base()
        i.audioLastSoundUp = 1059
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
            altimeter: nil, activity: nil, audio: nil, deviceStatus: FakeDeviceStatus(), uploadQueue: nil,
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

// MARK: - Every CSV row matches its header (all 14 files)

final class AllFilesRowShapeTests: XCTestCase {
    func testEveryWrittenRowHasExactlyTheHeaderColumnCount() throws {
        let deps = RecordingSession.Dependencies(
            motion: SyntheticMotionSource(), location: FakeLocationSource(), altimeter: FakeAltimeter(),
            activity: FakeActivity(), audio: FakeAudio(), deviceStatus: FakeDeviceStatus(), uploadQueue: nil,
            deviceId: "D", appVersion: "t", deviceInfo: .init(model: "x", name: "x", iosVersion: "x"))
        let session = try RecordingSession(store: SessionStore(root: try makeTempDir()), setup: SessionSetup(),
                                           preflight: nil, deps: deps)
        let e = expectation(description: "run")
        DispatchQueue.main.async {
            session.start()
            session.addLabel(.note, note: "a, \"quoted\" note")
            session.toggleSurface(.gravel)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { session.stop(); e.fulfill() }
        }
        wait(for: [e], timeout: ciTimeout)
        for file in StreamFile.allCases {
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

    func testPoisonRotationKeepsTheItemKind() async throws {
        let t = MockTransport()
        let q = UploadQueue(directory: try makeTempDir().appendingPathComponent("q"), transport: t,
                            config: { UploadConfig(baseURL: URL(string: "https://fn.test"), deviceKey: "k") })
        try q.enqueueSessionMetadata(json: Data("{}".utf8), sessionId: "S", phase: .stop, createdUtcMs: 1)
        t.enqueue(500, 500, 500, 500, 500)
        for _ in 0..<5 { _ = await q.processOnce() }
        XCTAssertEqual(q.pendingFiles().compactMap { UploadQueue.parseItem(fileName: $0.lastPathComponent)?.item },
                       [.sessionMeta(phase: .stop)])
    }

    private func runSession(uploadOn: Locked<Bool>, seconds: TimeInterval, toggleOnAfter: TimeInterval? = nil) throws
        -> (RecordingSession, UploadQueue) {
        let q = UploadQueue(directory: try makeTempDir().appendingPathComponent("q"), transport: MockTransport(),
                            config: { uploadOn.current ? UploadConfig(baseURL: URL(string: "https://fn.test"), deviceKey: "k") : .disabled })
        let deps = RecordingSession.Dependencies(
            motion: SyntheticMotionSource(), location: nil, altimeter: nil, activity: nil, audio: nil,
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
        for i in 0..<22 { acc.add(AudioLevelSample(t: 100 + Double(i) * 0.1, avgDbfs: -40 + r(), peakDbfs: -20 + r())) }
        let json = try acc.drain(t0Up: 100, t0UtcMs: 1_763_716_532_000, device: FakeDeviceStatus().status).jsonData()
        XCTAssertLessThan(json.count, RecordingSession.maxBatchJSONBytes / 2, "\(json.count) bytes")
    }
}
