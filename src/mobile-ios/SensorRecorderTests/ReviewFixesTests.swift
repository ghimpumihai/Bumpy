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
        XCTAssertTrue(m.audioEnabled, "older versions always recorded audio")
        XCTAssertNil(m.vehicle.line)
        XCTAssertFalse(m.mount.handheld)
        XCTAssertFalse(m.mount.seatOverAxle)
        XCTAssertEqual(m.people.raterPosture, "seated")
        XCTAssertEqual(m.people.raterName, "")
        XCTAssertNil(m.preflight)
    }

    func testNewFieldsAreWrittenWithExplicitNulls() throws {
        var m = SessionMetadataTests.sample()
        m.audioEnabled = false
        m.vehicle.type = "bus"
        m.mount.handheld = true
        m.people.raterPosture = "standing"
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: m.jsonData()) as? [String: Any])
        XCTAssertEqual(obj["audioEnabled"] as? Bool, false)
        let vehicle = try XCTUnwrap(obj["vehicle"] as? [String: Any])
        XCTAssertTrue(vehicle["line"] is NSNull, "spec: line is null when not set")
        let mount = try XCTUnwrap(obj["mount"] as? [String: Any])
        XCTAssertEqual(mount["handheld"] as? Bool, true)
        XCTAssertEqual(mount["seatOverAxle"] as? Bool, false)
        XCTAssertTrue(mount["photoFile"] is NSNull, "spec shows photoFile; null when no photo")
        XCTAssertEqual((obj["people"] as? [String: Any])?["raterPosture"] as? String, "standing")
        XCTAssertEqual(try JSONDecoder().decode(SessionMetadata.self, from: m.jsonData()), m)
    }

    func testVehicleTypeDefaultsAudioOffOnPublicTransport() {
        var s = SessionSetup()
        XCTAssertTrue(s.audioEnabled)
        s.vehicle.type = "bus"; s.vehicle.line = "24B"
        s.applyVehicleTypeDefaults()
        XCTAssertFalse(s.audioEnabled, "GDPR: no audio recording on buses by default")
        XCTAssertEqual(s.vehicle.line, "24B")
        s.vehicle.type = "tram"; s.applyVehicleTypeDefaults()
        XCTAssertFalse(s.audioEnabled)
        s.vehicle.type = "car"; s.applyVehicleTypeDefaults()
        XCTAssertTrue(s.audioEnabled)
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

// MARK: - Audio policy, level meter maths

final class AudioPolicyTests: XCTestCase {
    func decide(now: Double, rec: Bool, seg: Double = 0, want: Bool = true, intr: Bool = false, intrAt: Double = 0,
                last: Double = -100) -> AudioSegmentPolicy.Action {
        AudioSegmentPolicy.decide(now: now, isRecording: rec, segmentStartedUp: seg, wantRecording: want,
                                  interrupted: intr, interruptedAtUp: intrAt, lastRestartAttemptUp: last)
    }

    func testRotatesEveryFiveMinutes() {
        XCTAssertEqual(decide(now: 299.9, rec: true), .none)
        XCTAssertEqual(decide(now: 300, rec: true), .rotate)
    }

    func testRestartsAStoppedRecorderEveryFiveSeconds() {
        XCTAssertEqual(decide(now: 10, rec: false, last: 4), .restart)
        XCTAssertEqual(decide(now: 10, rec: false, last: 6), .none, "throttled")
        XCTAssertEqual(decide(now: 10, rec: false, want: false), .none, "not after stop()")
    }

    func testInterruptionWaitsForEndedButNotForever() {
        XCTAssertEqual(decide(now: 110, rec: false, intr: true, intrAt: 100), .none, "call in progress")
        XCTAssertEqual(decide(now: 121, rec: false, intr: true, intrAt: 100), .restart, "no 'ended' after 20 s")
    }

    func testLevelAccumulator() {
        var acc = LevelAccumulator(windowSeconds: 0.1)
        let fs = 48_000.0
        let sine = (0..<4800).map { Float(sin(2 * Double.pi * 1000 * Double($0) / fs)) }
        let w = acc.add(samples: sine, sampleRate: fs, startUp: 4.9)
        XCTAssertEqual(w.count, 1)
        XCTAssertEqual(w[0].avgDbfs, -3.01, accuracy: 0.05, "full-scale sine RMS = -3 dBFS")
        XCTAssertEqual(w[0].peakDbfs, 0, accuracy: 0.01)
        XCTAssertEqual(w[0].t, 5, accuracy: 1e-9, "window ends at the capture time of its last sample")
        // silence and corrupt samples never produce NaN/inf (would crash the dashboard)
        let bad = acc.add(samples: [Float](repeating: .nan, count: 4800), sampleRate: fs, startUp: 6)
        XCTAssertTrue(bad[0].avgDbfs.isFinite && bad[0].peakDbfs.isFinite)
        XCTAssertEqual(LevelAccumulator.dbfs(.nan), -140)
        XCTAssertEqual(LevelAccumulator.dbfs(0), -140)
    }
}

// MARK: - Health: audio meter staleness

final class AudioHealthTests: XCTestCase {
    private func inputs(levelAge: Double?, meter: Bool, recorder: Bool, recording: Bool = true) -> HealthInputs {
        var i = HealthInputs(now: 1060, recordingStartUp: 1000)
        i.gpsLastFixUp = 1059.5
        i.audioMeterExpected = meter
        i.audioLastSoundUp = i.now - 0.5 // the cabin is not silent (silence has its own test)
        i.audioExpected = recorder
        i.audioRecording = recording
        i.streams[.audioLevel] = StreamSnapshot(id: .audioLevel, count: 10, rateHz: 10, age: levelAge, meanRateHz: 10,
                                                maxGap: 0.1, gapsOver1s: 0, droppedEstimate: 0, available: true)
        return i
    }

    func testMeterOnlyModeFlagsASilentMeter() {
        XCTAssertTrue(HealthEvaluator.evaluate(inputs(levelAge: 0.1, meter: true, recorder: false)).isEmpty)
        let issues = HealthEvaluator.evaluate(inputs(levelAge: 5, meter: true, recorder: false))
        XCTAssertEqual(issues.map(\.key), ["audio.meter"])
        XCTAssertEqual(issues.first?.level, .problem)
    }

    func testNoDuplicateWhenRecorderAlreadyReportedOff() {
        let keys = HealthEvaluator.evaluate(inputs(levelAge: 5, meter: true, recorder: true, recording: false)).map(\.key)
        XCTAssertEqual(keys, ["audio.off"])
    }

    func testNoAudioSourceNoAudioRule() {
        XCTAssertTrue(HealthEvaluator.evaluate(inputs(levelAge: nil, meter: false, recorder: false)).isEmpty)
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

    func testPoisonBatchMovesToBackAfterRepeatedServerErrors() async throws {
        let t = MockTransport()
        let events = Locked([String]())
        let q = try makeQueue(t, events: events)
        try enqueue(q, 0, created: 1_000)
        try enqueue(q, 1, created: 2_000)
        t.enqueue(500, 500, 500, 500, 500) // batch 0 fails 5× on the server
        for _ in 0..<5 { _ = await q.processOnce() }
        XCTAssertEqual(q.pendingFiles().map { UploadQueue.parse(fileName: $0.lastPathComponent)!.seq }, [1, 0],
                       "batch 0 rotated behind batch 1; nothing deleted")
        let ok = await q.processOnce()
        XCTAssertEqual(ok, .uploaded(status: 200))
        XCTAssertEqual(t.requests.last?.value(forHTTPHeaderField: "x-idempotency-key"), "S:1", "newer batch gets through")
        XCTAssertTrue(events.current.contains { $0.contains("moved to the back") })
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
                                                 transport: t)
        XCTAssertTrue(r.ok)
        let req = try XCTUnwrap(t.requests.first)
        XCTAssertEqual(req.httpMethod, "POST")
        XCTAssertEqual(req.url?.absoluteString, "https://api.test/v1/api/ingest")
        XCTAssertEqual(req.value(forHTTPHeaderField: "x-device-key"), "k")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Content-Encoding"), "gzip")
        XCTAssertEqual(String(decoding: try Gzip.decompress(try XCTUnwrap(req.httpBody)), as: UTF8.self), #"{"probe":true}"#)
        XCTAssertTrue(UploadQueue.interpretProbe(status: 422).ok)
        XCTAssertFalse(UploadQueue.interpretProbe(status: 401).ok)
        XCTAssertFalse(UploadQueue.interpretProbe(status: 404).ok)
        XCTAssertFalse(UploadQueue.interpretProbe(status: 502).ok)
    }
}

// MARK: - Map decimation

final class MapDecimationTests: XCTestCase {
    func testDecimateKeepsRecentTrackAndBoundsSize() {
        let pts = (0..<20_000).map { TrackBuffer.Point(lat: Double($0), lon: 0, speed: 10) }
        let d = TrackMapView.decimate(pts, max: 1500)
        XCTAssertLessThanOrEqual(d.count, 1501)
        XCTAssertEqual(d.first, pts.first)
        XCTAssertEqual(d.last, pts.last)
        XCTAssertEqual(Array(d.suffix(750)), Array(pts.suffix(750)), "newest stretch drawn at full resolution")
        XCTAssertEqual(TrackMapView.decimate(Array(pts.prefix(100))).count, 100, "short tracks untouched")
    }
}

// MARK: - RecordingController: alerts + sickness prompt flows

@MainActor
final class FakeAlerter: Alerter {
    var problems = 0, prompts = 0, labels = 0, stops = 0
    func prepare() {}
    func labelConfirmed() { labels += 1 }
    func sicknessPrompt() { prompts += 1 }
    func newProblem() { problems += 1 }
    func stopped() { stops += 1 }
}

@MainActor
final class RecordingControllerTests: XCTestCase {
    private func makeController(device: FakeDeviceStatus = FakeDeviceStatus(), audio: FakeAudio = FakeAudio(),
                                interval: TimeInterval = 120, timeout: TimeInterval = 30) throws -> (RecordingController, FakeAlerter) {
        let deps = RecordingSession.Dependencies(
            motion: SyntheticMotionSource(), location: FakeLocationSource(), altimeter: FakeAltimeter(),
            activity: FakeActivity(), audio: audio, deviceStatus: device, uploadQueue: nil, deviceId: "D",
            appVersion: "t", deviceInfo: .init(model: "x", name: "x", iosVersion: "x"))
        let session = try RecordingSession(store: SessionStore(root: try makeTempDir()), setup: SessionSetup(),
                                           preflight: nil, deps: deps)
        let alerter = FakeAlerter()
        let c = RecordingController(session: session, sicknessInterval: interval, sicknessTimeout: timeout, alerter: alerter)
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

    /// Spins the main run loop (the controller's 8 Hz timer keeps firing) until `cond` holds.
    private func waitUntil(_ timeout: TimeInterval, _ cond: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if cond() { return true }
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        return cond()
    }

    func testPromptTimesOutAsMissedSkipIsMissedAndStopDuringPromptIsMissed() throws {
        let (c, alerter) = try makeController(interval: 0.3, timeout: 0.3)
        c.start()
        XCTAssertTrue(waitUntil(ciTimeout) { c.sicknessPromptActive })
        XCTAssertGreaterThanOrEqual(alerter.prompts, 1)
        XCTAssertTrue(waitUntil(ciTimeout) { c.session.labels.sicknessMissed >= 1 }, "unanswered prompt → sickness_missed")
        XCTAssertTrue(waitUntil(ciTimeout) { c.sicknessPromptActive })
        let before = c.session.labels.sicknessMissed
        c.skipSicknessPrompt() // no run-loop turn in between: deterministic
        XCTAssertEqual(c.session.labels.sicknessMissed, before + 1)
        XCTAssertFalse(c.sicknessPromptActive)
        XCTAssertEqual(c.session.labels.sicknessRatings, 0, "skip never fakes a rating")
        XCTAssertTrue(waitUntil(ciTimeout) { c.sicknessPromptActive })
        c.stop()
        let labels = try String(contentsOf: c.session.folder.appendingPathComponent("labels.csv"), encoding: .utf8)
        XCTAssertTrue(labels.contains("sickness_missed,,skipped"))
        XCTAssertTrue(labels.contains("sickness_missed,,recording stopped"))
        XCTAssertEqual(alerter.stops, 1)
    }

    func testRatingClosesPromptAndIsLoggedAsPrompted() throws {
        let (c, _) = try makeController(interval: 0.2, timeout: 5)
        c.start()
        defer { c.stop() }
        XCTAssertTrue(waitUntil(ciTimeout) { c.sicknessPromptActive })
        c.rateSickness(4)
        XCTAssertFalse(c.sicknessPromptActive)
        XCTAssertEqual(c.session.labels.sicknessRatings, 1)
        XCTAssertEqual(c.snapshot.lastSickness, 4)
    }

    func testAudioOffSessionHasNoAudioProblemAndIsRecordedAsOff() throws {
        let meterOnly = FakeAudio()
        meterOnly.recordsAudio = false
        let (c, _) = try makeController(audio: meterOnly)
        c.start()
        spin(0.5)
        // Audio recording is OFF: "recorder not recording" must never be raised (meter health is
        // timing-dependent and tested exactly in AudioHealthTests).
        XCTAssertFalse(c.issues.contains { $0.key == "audio.off" }, "\(c.issues)")
        let meta = c.session.stop()
        XCTAssertFalse(meta.audioEnabled)
    }
}

// MARK: - Multi-segment audio bookkeeping

final class AudioSegmentsIntegrationTests: XCTestCase {
    func testEverySegmentHasStartStopRowsAClockAnchorAndAFile() throws {
        let audio = FakeAudio()
        audio.segments = 3
        let deps = RecordingSession.Dependencies(
            motion: SyntheticMotionSource(), location: nil, altimeter: nil, activity: nil, audio: audio,
            deviceStatus: FakeDeviceStatus(), uploadQueue: nil, deviceId: "D", appVersion: "t",
            deviceInfo: .init(model: "x", name: "x", iosVersion: "x"))
        let session = try RecordingSession(store: SessionStore(root: try makeTempDir()), setup: SessionSetup(),
                                           preflight: nil, deps: deps)
        let e = expectation(description: "run")
        var meta: SessionMetadata?
        DispatchQueue.main.async {
            session.start()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { meta = session.stop(); e.fulfill() }
        }
        wait(for: [e], timeout: ciTimeout)
        let segs = try readCSV(session.folder.appendingPathComponent("audio_segments.csv")).rows
        XCTAssertEqual(segs.filter { $0[2] == "start" }.map { $0[3] }, ["audio_000.m4a", "audio_001.m4a", "audio_002.m4a"])
        XCTAssertEqual(segs.filter { $0[2] == "stop" }.count, 3)
        let clockStarts = try readCSV(session.folder.appendingPathComponent("clock.csv")).rows.filter { $0[2] == "audio_start" }
        XCTAssertEqual(clockStarts.count, 3, "n-th audio_start row ↔ audio_00n.m4a")
        XCTAssertEqual(meta?.stats?.audioFiles, ["audio_000.m4a", "audio_001.m4a", "audio_002.m4a"])
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
        acc.add(AudioLevelSample(t: 100.03, avgDbfs: -31, peakDbfs: -12))
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
        m.audioEnabled = false
        m.vehicle.type = "bus"; m.vehicle.line = "24B"
        m.stats = .init(durationSec: 2808.488, streams: [:], labelsCount: 3, sicknessRatings: 1, sicknessMissed: 0,
                        audioFiles: [], fileSizes: [:], totalBytes: 1, writeErrors: 0, uploadBatchesCreated: 3)
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
