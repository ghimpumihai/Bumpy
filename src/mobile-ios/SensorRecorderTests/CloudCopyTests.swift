import XCTest
@testable import SensorRecorder

/// D56: which parts of a trip the backend acknowledged, what the Recap shows, when a trip may be
/// deleted, and retrying rejected parts.
final class CloudCopyTests: XCTestCase {
    private var transport: MockTransport!
    private var queue: UploadQueue!
    private let body = try! Gzip.compress(Data("{}".utf8))

    override func setUpWithError() throws {
        transport = MockTransport()
        queue = UploadQueue(directory: try makeTempDir().appendingPathComponent("upload_queue"), transport: transport,
                            backgroundTime: nil,
                            config: { UploadConfig(baseURL: URL(string: "https://fn.test"), deviceKey: "k") })
    }

    /// Start copy, batches 0..<n, Stop copy: the order a recording queues them in.
    private func queueTrip(_ id: String, batches n: Int) throws {
        try queue.enqueueSessionMetadata(json: Data("{}".utf8), sessionId: id, phase: .start, createdUtcMs: 1)
        for seq in 0..<n { try queue.enqueue(gzippedBody: body, sessionId: id, seq: seq, createdUtcMs: Int64(2 + seq)) }
        try queue.enqueueSessionMetadata(json: Data("{}".utf8), sessionId: id, phase: .stop, createdUtcMs: 100)
    }

    private func drain() async {
        while true {
            let o = await queue.processOnce()
            if o == .empty { return }
            if case .retry = o { return XCTFail("unexpected retry") }
        }
    }

    private func stats(batches: Int, notQueued: Int? = nil) -> SessionMetadata.Stats {
        .init(durationSec: 10, streams: [:], labelsCount: 0, fileSizes: [:], totalBytes: 1, writeErrors: 0,
              uploadBatchesCreated: batches, uploadWindowsNotQueued: notQueued)
    }

    private func stoppedMeta(_ id: String, _ stats: SessionMetadata.Stats?) -> SessionMetadata {
        var m = SessionMetadataTests.sample()
        m.sessionId = id
        m.endedAtUtc = "2026-11-21T10:00:00.000Z"
        m.stats = stats
        return m
    }

    func testEveryAcceptedPartIsRecordedAndTheTripIsComplete() async throws {
        try queueTrip("S", batches: 3)
        try queue.enqueue(gzippedBody: body, sessionId: "T", seq: 0, createdUtcMs: 50)
        transport.enqueue(200, 200, 409, 200, 200, 200) // 409 (duplicate) counts as accepted
        await drain()

        XCTAssertEqual(queue.acknowledged(sessionId: "S").batches, [0, 1, 2])
        XCTAssertTrue(queue.acknowledged(sessionId: "S").stop)
        XCTAssertEqual(queue.acknowledged(sessionId: "T").batches, [0], "per trip")
        XCTAssertFalse(queue.acknowledged(sessionId: "T").stop)
        let copy = TripCloudCopy(stats: stats(batches: 3), state: queue.tripState(sessionId: "S"))
        XCTAssertTrue(copy.isComplete)
        XCTAssertEqual(copy.percent, 100)
        XCTAssertEqual(copy.partsNeverQueued, 0)
        XCTAssertNil(TripCloudCopy.deleteRefusal(metadata: stoppedMeta("S", stats(batches: 3)), state: queue.tripState(sessionId: "S")))
    }

    func testWhileUploadingThePercentCountsTheStopCopyAndNeverSays100() async throws {
        try queueTrip("S", batches: 3)
        for _ in 0..<4 { _ = await queue.processOnce() } // Start copy + batches 0-2; Stop copy still queued
        let copy = TripCloudCopy(stats: stats(batches: 3), state: queue.tripState(sessionId: "S"))
        XCTAssertEqual(copy.sentParts, 3)
        XCTAssertEqual(copy.totalParts, 4)
        XCTAssertEqual(copy.percent, 75)
        XCTAssertFalse(copy.isComplete)
        XCTAssertFalse(copy.stopMissing, "queued, not missing")
        XCTAssertEqual(TripCloudCopy.deleteRefusal(metadata: stoppedMeta("S", stats(batches: 3)),
                                                   state: queue.tripState(sessionId: "S")), .stillQueued(1))
    }

    func testWindowsLeftOutOfTheLiveUploadMeanTheCloudCopyHasGaps() async throws {
        try queueTrip("S", batches: 2)
        await drain()
        let st = stats(batches: 2, notQueued: 16) // e.g. a full disk: > 15 windows dropped
        let copy = TripCloudCopy(stats: st, state: queue.tripState(sessionId: "S"))
        XCTAssertFalse(copy.isComplete, "every queued batch was sent, but the trip has gaps")
        XCTAssertEqual(copy.totalParts, 19)
        XCTAssertEqual(copy.percent, 3 * 100 / 19)
        XCTAssertEqual(copy.partsNeverQueued, 16, "the Recap tells the operator to do the laptop upload")
        XCTAssertEqual(TripCloudCopy.deleteRefusal(metadata: stoppedMeta("S", st), state: queue.tripState(sessionId: "S")),
                       .notInCloud(16))
    }

    func testAStopCopyThatCouldNotBeQueuedIsMissing() async throws {
        try queue.enqueue(gzippedBody: body, sessionId: "S", seq: 0, createdUtcMs: 1) // no Stop copy (full disk)
        await drain()
        let copy = TripCloudCopy(stats: stats(batches: 1), state: queue.tripState(sessionId: "S"))
        XCTAssertTrue(copy.stopMissing)
        XCTAssertEqual(copy.partsNeverQueued, 1)
        XCTAssertEqual(copy.percent, 50)
        XCTAssertEqual(TripCloudCopy.deleteRefusal(metadata: stoppedMeta("S", stats(batches: 1)), state: queue.tripState(sessionId: "S")),
                       .notInCloud(1))
    }

    /// Upload off for the whole trip: nothing was queued, so nothing is known to be in the cloud.
    func testATripRecordedWithUploadOffCanNotBeDeleted() {
        let st = stats(batches: 0, notQueued: 300)
        XCTAssertEqual(TripCloudCopy.deleteRefusal(metadata: stoppedMeta("S", st), state: queue.tripState(sessionId: "S")),
                       .notInCloud(301))
        XCTAssertEqual(TripCloudCopy.deleteRefusal(metadata: stoppedMeta("S", stats(batches: 0)), state: queue.tripState(sessionId: "S")),
                       .notInCloud(1), "even without windows counted, the Stop copy was never acknowledged")
    }

    func testDeleteIsRefusedForUnreadableRecoveredOrIncompleteTrips() async throws {
        try queueTrip("S", batches: 2)
        await drain()
        let state = queue.tripState(sessionId: "S")
        XCTAssertEqual(TripCloudCopy.deleteRefusal(metadata: nil, state: state), .unreadable)
        var recovered = stoppedMeta("S", stats(batches: 2))
        recovered.endedAtUtc = nil
        recovered.recovered = true
        XCTAssertEqual(TripCloudCopy.deleteRefusal(metadata: recovered, state: state), .notInCloud(0))
        XCTAssertEqual(TripCloudCopy.deleteRefusal(metadata: stoppedMeta("S", nil), state: state), .notInCloud(0))
        // A batch the ack record doesn't have (sent by an older build, or the record failed to write).
        XCTAssertEqual(TripCloudCopy.deleteRefusal(metadata: stoppedMeta("S", stats(batches: 3)), state: state), .notInCloud(1))
        XCTAssertNil(TripCloudCopy.deleteRefusal(metadata: stoppedMeta("S", stats(batches: 2)), state: state))
        queue.forgetAcknowledged(sessionId: "S")
        XCTAssertEqual(TripCloudCopy.deleteRefusal(metadata: stoppedMeta("S", stats(batches: 2)), state: queue.tripState(sessionId: "S")),
                       .notInCloud(3))
    }

    /// Settings' "Retry failed uploads (N)": N is `failedFiles().count`; the button calls `requeueFailed()`.
    func testRejectedPartsCanBeRetriedFromSettings() async throws {
        try queueTrip("S", batches: 2)
        transport.enqueue(200, 422, 200, 200) // batch 0 rejected
        await drain()
        var state = queue.tripState(sessionId: "S")
        XCTAssertEqual(queue.failedFiles().count, 1, "Settings shows the row")
        XCTAssertEqual(state.failedBatches, 1)
        let copy = TripCloudCopy(stats: stats(batches: 2), state: state)
        XCTAssertEqual(copy.rejectedParts, 1)
        XCTAssertEqual(copy.percent, 66)
        XCTAssertEqual(TripCloudCopy.deleteRefusal(metadata: stoppedMeta("S", stats(batches: 2)), state: state), .rejected(1))

        queue.requeueFailed()
        XCTAssertTrue(queue.failedFiles().isEmpty, "the row disappears")
        XCTAssertEqual(queue.tripState(sessionId: "S").pendingBatches, 1)
        await drain() // the backend accepts it now
        state = queue.tripState(sessionId: "S")
        XCTAssertTrue(TripCloudCopy(stats: stats(batches: 2), state: state).isComplete)
        XCTAssertNil(TripCloudCopy.deleteRefusal(metadata: stoppedMeta("S", stats(batches: 2)), state: state))
    }

    // MARK: session.json and the Stop copy

    func testWindowsNotQueuedStayOnThePhone() throws {
        var m = stoppedMeta("S", stats(batches: 2, notQueued: 4))
        let local = try XCTUnwrap(JSONSerialization.jsonObject(with: m.jsonData()) as? [String: Any])
        XCTAssertEqual((local["stats"] as? [String: Any])?["uploadWindowsNotQueued"] as? Int, 4)
        let cloud = try XCTUnwrap(JSONSerialization.jsonObject(with: RecordingSession.sessionMetadataBody(m, batchCount: 2)) as? [String: Any])
        let cloudStats = try XCTUnwrap(cloud["stats"] as? [String: Any])
        XCTAssertNil(cloudStats["uploadWindowsNotQueued"], "not part of the §6.1 Stop copy")
        XCTAssertEqual(cloudStats["uploadBatchesCreated"] as? Int, 2)

        m.stats = stats(batches: 2)
        let none = try XCTUnwrap(JSONSerialization.jsonObject(with: m.jsonData()) as? [String: Any])
        XCTAssertNil((none["stats"] as? [String: Any])?["uploadWindowsNotQueued"], "omitted when 0: format unchanged")
        XCTAssertNil(try JSONDecoder().decode(SessionMetadata.self, from: m.jsonData()).stats?.uploadWindowsNotQueued,
                     "older session.json files (no key) still decode")
    }

    func testARecordingWithUploadOffCountsItsWindowsAsNotQueued() throws {
        let off = UploadQueue(directory: try makeTempDir().appendingPathComponent("q"), transport: MockTransport(),
                              backgroundTime: nil, config: { .disabled })
        let deps = RecordingSession.Dependencies(
            motion: SyntheticMotionSource(), location: nil, altimeter: nil, activity: nil,
            deviceStatus: FakeDeviceStatus(), uploadQueue: off, deviceId: "D", appVersion: "t",
            deviceInfo: .init(model: "x", name: "x", iosVersion: "x"))
        let session = try RecordingSession(store: SessionStore(root: try makeTempDir()), setup: SessionSetup(), preflight: nil, deps: deps)
        session.start() // XCTest runs on the main thread
        let meta = session.stop()
        XCTAssertEqual(meta.stats?.uploadBatchesCreated, 0)
        XCTAssertGreaterThanOrEqual(meta.stats?.uploadWindowsNotQueued ?? 0, 1, "the final window at Stop")
        XCTAssertEqual(try SessionMetadata.load(from: session.folder.appendingPathComponent("session.json")), meta)
    }
}
