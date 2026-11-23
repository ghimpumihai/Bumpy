import XCTest
@testable import SensorRecorder

/// D59: an automatic trip's upload hold, Cancel within it, the `autoStart` key, and the start/stop rules.
final class AutoTripUploadHoldTests: XCTestCase {
    private var transport: MockTransport!
    private var queue: UploadQueue!
    private let clock = Locked<Int64>(1_800_000_000_000)
    private let body = try! Gzip.compress(Data("{}".utf8))

    override func setUpWithError() throws {
        transport = MockTransport()
        let clock = self.clock
        queue = UploadQueue(directory: try makeTempDir().appendingPathComponent("upload_queue"), transport: transport,
                            nowUtcMs: { clock.current }, backgroundTime: nil,
                            config: { UploadConfig(baseURL: URL(string: "https://fn.test"), deviceKey: "k") })
    }

    private func advance(seconds: Double) { clock.withLock { $0 += Int64(seconds * 1000) } }

    private func queueStartAndBatches(_ id: String, batches n: Int, at ms: Int64) throws {
        try queue.enqueueSessionMetadata(json: Data("{}".utf8), sessionId: id, phase: .start, createdUtcMs: ms)
        for seq in 0..<n { try queue.enqueue(gzippedBody: body, sessionId: id, seq: seq, createdUtcMs: ms + 1 + Int64(seq)) }
    }

    func testHeldTripIsNotSentButOtherTripsAre() async throws {
        XCTAssertTrue(queue.hold(sessionId: "AUTO"))
        try queueStartAndBatches("AUTO", batches: 2, at: 1)          // older files, held
        try queue.enqueue(gzippedBody: body, sessionId: "MANUAL", seq: 0, createdUtcMs: 10)

        XCTAssertEqual(await queue.processOnce(), .uploaded(status: 200), "the held head doesn't block the next trip")
        XCTAssertEqual(queue.acknowledged(sessionId: "MANUAL").batches, [0])
        XCTAssertEqual(await queue.processOnce(), .empty)
        XCTAssertEqual(transport.requests.count, 1)
        XCTAssertEqual(queue.tripState(sessionId: "AUTO").pendingItems, 3, "held files are still pending, not lost")
    }

    func testHoldEndsAfterTwoMinutesAndEverythingIsSentInOrder() async throws {
        queue.hold(sessionId: "AUTO")
        try queueStartAndBatches("AUTO", batches: 2, at: 1)
        advance(seconds: UploadQueue.holdSeconds - 1)
        XCTAssertEqual(await queue.processOnce(), .empty)
        advance(seconds: 2)
        for _ in 0..<3 { XCTAssertEqual(await queue.processOnce(), .uploaded(status: 200)) }
        XCTAssertEqual(await queue.processOnce(), .empty)
        XCTAssertEqual(queue.acknowledged(sessionId: "AUTO").batches, [0, 1])
        XCTAssertNil(queue.holdRemainingMs(sessionId: "AUTO"))
        XCTAssertTrue(queue.activeHolds().isEmpty, "the ended hold's file is removed")
    }

    func testHoldSurvivesARelaunch() async throws {
        queue.hold(sessionId: "AUTO")
        try queueStartAndBatches("AUTO", batches: 1, at: 1)
        let clock = self.clock
        let relaunched = UploadQueue(directory: queue.directory, transport: transport, nowUtcMs: { clock.current },
                                     backgroundTime: nil,
                                     config: { UploadConfig(baseURL: URL(string: "https://fn.test"), deviceKey: "k") })
        XCTAssertEqual(await relaunched.processOnce(), .empty)
        XCTAssertNotNil(relaunched.holdRemainingMs(sessionId: "AUTO"))
    }

    func testAHoldFurtherAwayThanAWholeHoldEndsNow() async throws {
        queue.hold(sessionId: "AUTO")
        try queueStartAndBatches("AUTO", batches: 1, at: 1)
        advance(seconds: -3600) // the wall clock stepped back an hour
        XCTAssertNil(queue.holdRemainingMs(sessionId: "AUTO"))
        XCTAssertEqual(await queue.processOnce(), .uploaded(status: 200), "never held for longer than a hold")
    }

    func testCancelWithinTheHoldDiscardsEveryQueuedPart() throws {
        queue.hold(sessionId: "AUTO")
        try queueStartAndBatches("AUTO", batches: 3, at: 1)
        try queue.enqueueSessionMetadata(json: Data("{}".utf8), sessionId: "AUTO", phase: .stop, createdUtcMs: 50)
        try queue.enqueue(gzippedBody: body, sessionId: "OTHER", seq: 0, createdUtcMs: 60)
        advance(seconds: 30)

        XCTAssertTrue(queue.discardHeldSession(sessionId: "AUTO"))
        XCTAssertEqual(queue.tripState(sessionId: "AUTO").pendingItems, 0)
        XCTAssertEqual(queue.tripState(sessionId: "OTHER").pendingItems, 1, "other trips untouched")
        XCTAssertNil(queue.holdRemainingMs(sessionId: "AUTO"))
    }

    func testNoDiscardOnceTheHoldIsNearlyOver() throws {
        queue.hold(sessionId: "AUTO")
        try queueStartAndBatches("AUTO", batches: 1, at: 1)
        advance(seconds: UploadQueue.holdSeconds - UploadQueue.discardMarginSeconds + 1)
        XCTAssertFalse(queue.discardHeldSession(sessionId: "AUTO"), "the loop may already be sending it")
        XCTAssertEqual(queue.tripState(sessionId: "AUTO").pendingItems, 2, "kept: a late Cancel keeps the trip")
    }

    func testNoDiscardWhenAnyPartWasAcknowledged() async throws {
        try queueStartAndBatches("AUTO", batches: 1, at: 1)
        XCTAssertEqual(await queue.processOnce(), .uploaded(status: 200)) // Start copy sent before the hold
        queue.hold(sessionId: "AUTO")
        XCTAssertFalse(queue.discardHeldSession(sessionId: "AUTO"))
        XCTAssertEqual(queue.tripState(sessionId: "AUTO").pendingItems, 1)
    }

    func testNoDiscardWithoutAHold() throws {
        try queueStartAndBatches("MANUAL", batches: 1, at: 1)
        XCTAssertFalse(queue.discardHeldSession(sessionId: "MANUAL"))
        XCTAssertEqual(queue.tripState(sessionId: "MANUAL").pendingItems, 2)
    }

    func testAHoldThatCannotBeWrittenUploadsAtOnce() async throws {
        let failing = UploadQueue(directory: try makeTempDir().appendingPathComponent("q"), transport: transport,
                                  backgroundTime: nil,
                                  writeFile: { data, url in
                                      if url.path.contains("upload_held") { throw CocoaError(.fileWriteOutOfSpace) }
                                      try data.write(to: url, options: .atomic)
                                  },
                                  config: { UploadConfig(baseURL: URL(string: "https://fn.test"), deviceKey: "k") })
        XCTAssertFalse(failing.hold(sessionId: "AUTO"))
        try failing.enqueue(gzippedBody: body, sessionId: "AUTO", seq: 0, createdUtcMs: 1)
        XCTAssertEqual(await failing.processOnce(), .uploaded(status: 200), "never lost, just not cancellable")
    }
}

final class AutoStartMetadataTests: XCTestCase {
    func testAutoStartIsOmittedForManualTrips() throws {
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: SessionMetadataTests.sample().jsonData()) as? [String: Any])
        XCTAssertNil(obj.index(forKey: "autoStart"), "manual trips: format unchanged")
    }

    func testAutoStartKeysAndRoundTrip() throws {
        var m = SessionMetadataTests.sample()
        m.autoStart = .init(detectedAtUtc: "2026-11-23T08:00:00.000Z")
        var obj = try XCTUnwrap(JSONSerialization.jsonObject(with: m.jsonData()) as? [String: Any])
        XCTAssertEqual(obj["autoStart"] as? [String: String], ["detectedAtUtc": "2026-11-23T08:00:00.000Z"],
                       "cancelledAtUtc omitted until cancelled")
        m.autoStart?.cancelledAtUtc = "2026-11-23T08:05:00.000Z"
        obj = try XCTUnwrap(JSONSerialization.jsonObject(with: m.jsonData()) as? [String: Any])
        XCTAssertEqual(obj["autoStart"] as? [String: String],
                       ["detectedAtUtc": "2026-11-23T08:00:00.000Z", "cancelledAtUtc": "2026-11-23T08:05:00.000Z"])
        XCTAssertEqual(try JSONDecoder().decode(SessionMetadata.self, from: m.jsonData()), m)
    }

    func testAnAutoTripCarriesAutoStartAndTheCancelIntoTheStopCopy() throws {
        let transport = MockTransport()
        let queue = UploadQueue(directory: try makeTempDir().appendingPathComponent("q"), transport: transport,
                                backgroundTime: nil,
                                config: { UploadConfig(baseURL: URL(string: "https://fn.test"), deviceKey: "k") })
        let deps = RecordingSession.Dependencies(
            motion: SyntheticMotionSource(), location: nil, altimeter: nil, activity: nil,
            deviceStatus: FakeDeviceStatus(), uploadQueue: queue, deviceId: "D", appVersion: "t",
            deviceInfo: .init(model: "x", name: "x", iosVersion: "x"))
        let session = try RecordingSession(store: SessionStore(root: try makeTempDir()), setup: SessionSetup(), preflight: nil,
                                           deps: deps, autoStart: .init(detectedAtUtc: "2026-11-23T08:00:00.000Z"))
        session.start() // XCTest runs on the main thread
        session.markCancelled(at: Date(timeIntervalSince1970: 1_800_000_000))
        let meta = session.stop()
        XCTAssertEqual(meta.autoStart?.detectedAtUtc, "2026-11-23T08:00:00.000Z")
        XCTAssertNotNil(meta.autoStart?.cancelledAtUtc)
        XCTAssertEqual(try SessionMetadata.load(from: session.folder.appendingPathComponent("session.json")), meta)

        let stop = try XCTUnwrap(queue.pendingFiles().last)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Gzip.decompress(Data(contentsOf: stop))) as? [String: Any])
        XCTAssertNotNil(json["batchCount"], "the Stop copy")
        XCTAssertEqual((json["autoStart"] as? [String: Any])?["cancelledAtUtc"] as? String, meta.autoStart?.cancelledAtUtc)
    }

    func testCancelDoesNothingToAManualTrip() throws {
        let deps = RecordingSession.Dependencies(
            motion: SyntheticMotionSource(), location: nil, altimeter: nil, activity: nil,
            deviceStatus: FakeDeviceStatus(), uploadQueue: nil, deviceId: "D", appVersion: "t",
            deviceInfo: .init(model: "x", name: "x", iosVersion: "x"))
        let session = try RecordingSession(store: SessionStore(root: try makeTempDir()), setup: SessionSetup(), preflight: nil, deps: deps)
        session.start()
        session.markCancelled(at: Date())
        XCTAssertNil(session.stop().autoStart)
    }
}

final class AutoTripRulesTests: XCTestCase {
    private func activity(automotive: Bool = false, walking: Bool = false, running: Bool = false, cycling: Bool = false,
                          confidence: Int = 2) -> ActivitySample {
        ActivitySample(t: 0, stationary: false, walking: walking, running: running, automotive: automotive,
                       cycling: cycling, unknown: false, confidence: confidence, startUtcMs: 0)
    }

    private func drive(_ r: inout AutoTripRules, from: TimeInterval, seconds: Int, speed: Double) {
        for i in 0...seconds { r.addFix(t: from + Double(i), speed: speed) }
    }

    func testStartsAfterThirtyFastSecondsWhileDriving() {
        var r = AutoTripRules()
        r.addActivity(t: 0, activity(automotive: true))
        drive(&r, from: 0, seconds: 29, speed: 8)
        XCTAssertFalse(r.shouldStart(now: 29))
        drive(&r, from: 30, seconds: 2, speed: 8)
        XCTAssertTrue(r.shouldStart(now: 32))
    }

    func testStopAndGoCountsWithinTheWindow() {
        var r = AutoTripRules()
        r.addActivity(t: 0, activity(automotive: true))
        for burst in 0..<4 { // 8 fast s, 12 slow s, four times
            let t0 = Double(burst * 20)
            drive(&r, from: t0, seconds: 8, speed: 7)
            drive(&r, from: t0 + 9, seconds: 10, speed: 1)
        }
        XCTAssertTrue(r.shouldStart(now: 80))
    }

    func testRunningOrCyclingNeverStarts() {
        for blocker in [activity(running: true), activity(cycling: true)] {
            var r = AutoTripRules()
            r.addActivity(t: 0, blocker)
            r.addActivity(t: 20, activity(automotive: true))
            drive(&r, from: 0, seconds: 60, speed: 8)
            XCTAssertFalse(r.shouldStart(now: 60), "\(blocker.summary) in the last minute")
        }
        var r = AutoTripRules()
        r.addActivity(t: 0, activity(walking: true))
        drive(&r, from: 0, seconds: 60, speed: 8)
        XCTAssertFalse(r.shouldStart(now: 60), "not in a vehicle")
    }

    func testLowConfidenceDrivingIsNotACandidate() {
        var r = AutoTripRules()
        r.addActivity(t: 0, activity(automotive: true, confidence: 0))
        XCTAssertFalse(r.isCandidate(now: 1))
    }

    func testGPSGapsDoNotCountAsFast() {
        var r = AutoTripRules()
        r.addActivity(t: 0, activity(automotive: true))
        r.addFix(t: 0, speed: 8)
        r.addFix(t: 60, speed: 8)
        XCTAssertLessThan(r.fastSeconds(now: 60), AutoTripRules.startFastSeconds)
    }

    func testStopsAfterTenMinutesStopped() {
        var r = AutoTripRules()
        r.resetForTrip(startedAt: 0)
        drive(&r, from: 0, seconds: 100, speed: 10)
        drive(&r, from: 101, seconds: 598, speed: 0)
        XCTAssertFalse(r.shouldStop(now: 699), "a bus layover")
        drive(&r, from: 700, seconds: 1, speed: 0)
        XCTAssertTrue(r.shouldStop(now: 701))
    }

    func testNoGPSIsNotStopped() {
        var r = AutoTripRules()
        r.resetForTrip(startedAt: 0)
        r.addFix(t: 0, speed: 0)
        XCTAssertFalse(r.shouldStop(now: 900), "a tunnel or a garage")
    }

    func testStopsWhenWalkingAwaySlowly() {
        var r = AutoTripRules()
        r.resetForTrip(startedAt: 0)
        r.addActivity(t: 0, activity(automotive: true))
        drive(&r, from: 0, seconds: 100, speed: 10)
        r.addActivity(t: 101, activity(walking: true))
        drive(&r, from: 101, seconds: 70, speed: 1.2)
        XCTAssertFalse(r.shouldStop(now: 150))
        XCTAssertTrue(r.shouldStop(now: 171))
    }

    func testAStandingTramPassengerIsNotWalkingAway() {
        var r = AutoTripRules()
        r.resetForTrip(startedAt: 0)
        r.addActivity(t: 0, activity(walking: true))
        drive(&r, from: 0, seconds: 120, speed: 9)
        XCTAssertFalse(r.shouldStop(now: 120))
    }
}
