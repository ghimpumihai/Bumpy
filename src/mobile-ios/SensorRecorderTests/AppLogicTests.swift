import XCTest
@testable import SensorRecorder

final class SicknessSchedulerTests: XCTestCase {
    func testPromptsEveryIntervalAndAutoDismisses() {
        var s = SicknessScheduler(start: 0, interval: 120, timeout: 30)
        XCTAssertNil(s.tick(now: 119.9))
        XCTAssertEqual(s.tick(now: 120), .prompt)
        XCTAssertTrue(s.isPromptActive)
        XCTAssertEqual(s.remaining(now: 130) ?? -1, 20, accuracy: 1e-9)
        XCTAssertNil(s.tick(now: 149.9))
        XCTAssertEqual(s.tick(now: 150), .missed)
        XCTAssertFalse(s.isPromptActive)
        XCTAssertNil(s.tick(now: 200))
        XCTAssertEqual(s.tick(now: 240), .prompt) // fixed cadence from start
        s.answered()
        XCTAssertFalse(s.isPromptActive)
        XCTAssertNil(s.tick(now: 260))
        XCTAssertEqual(s.tick(now: 360), .prompt)
    }

    func testManualAnswerDoesNotShiftCadence() {
        var s = SicknessScheduler(start: 0, interval: 120, timeout: 30)
        s.answered() // manual rating at t=50
        XCTAssertEqual(s.tick(now: 120), .prompt)
    }

    func testLongSuspensionDoesNotBurst() {
        var s = SicknessScheduler(start: 0, interval: 120, timeout: 30)
        XCTAssertEqual(s.tick(now: 1000), .prompt)
        XCTAssertEqual(s.nextPromptAt, 1120)
        XCTAssertEqual(s.tick(now: 1030), .missed)
        XCTAssertNil(s.tick(now: 1031))
    }
}

final class MotionTestAnalysisTests: XCTestCase {
    func testRatesAndStillness() {
        var accel: [Vec3Sample] = []
        var t: [Double] = []
        for i in 0..<500 {
            let ti = Double(i) * 0.01
            t.append(ti)
            accel.append(Vec3Sample(t: ti, v: Vec3(x: 0.001 * (i % 2 == 0 ? 1 : -1), y: 0, z: -1)))
        }
        let r = MotionTestAnalysis.analyze(dmTimes: t, gravity: Array(repeating: Vec3(x: 0, y: 0, z: -1), count: 500),
                                           accel: accel, gyroTimes: t, magTimes: stride(from: 0.0, to: 5, by: 0.02).map { $0 })
        XCTAssertEqual(r.rates[.accel] ?? 0, 100, accuracy: 0.01)
        XCTAssertEqual(r.rates[.mag] ?? 0, 50, accuracy: 0.01)
        XCTAssertEqual(r.accelStd.x, 0.001, accuracy: 1e-9)
        XCTAssertEqual(r.accelMean.z, -1, accuracy: 1e-12)
        XCTAssertEqual(r.gravityMean, Vec3(x: 0, y: 0, z: -1))
        XCTAssertLessThan(r.maxStd, PreflightModel.stillnessMaxStdG)
        XCTAssertEqual(MotionTestAnalysis.rate([1]), 0)
    }
}

final class MapSegmentTests: XCTestCase {
    func testSegmentsSplitBySpeedBucketAndShareBoundary() {
        let pts: [TrackBuffer.Point] = [
            .init(lat: 0, lon: 0, speed: 5),   // 18 km/h
            .init(lat: 0, lon: 1, speed: 5),
            .init(lat: 0, lon: 2, speed: 20),  // 72 km/h
            .init(lat: 0, lon: 3, speed: 20),
        ]
        let segs = TrackMapView.segments(pts)
        XCTAssertEqual(segs.count, 2)
        XCTAssertEqual(segs[0].coords.map(\.longitude), [0, 1, 2])
        XCTAssertEqual(segs[1].coords.map(\.longitude), [2, 3])
        XCTAssertTrue(TrackMapView.segments([pts[0]]).isEmpty)
    }
}

final class ExportTests: XCTestCase {
    func testFolderZipProducesZipArchive() throws {
        let dir = try makeTempDir().appendingPathComponent("2026-11-21T09-12-03Z_abcd")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("t_up,t_utc_ms,x,y,z\n".utf8).write(to: dir.appendingPathComponent("accel_raw.csv"))
        try Data("{}".utf8).write(to: dir.appendingPathComponent("session.json"))
        let zip = try FolderZipper.zip(dir)
        XCTAssertEqual(zip.lastPathComponent, "2026-11-21T09-12-03Z_abcd.zip")
        let data = try Data(contentsOf: zip)
        XCTAssertEqual(Array(data.prefix(4)), [0x50, 0x4b, 0x03, 0x04], "PK zip signature")
        XCTAssertNotNil(data.range(of: Data("accel_raw.csv".utf8)))
    }
}

// MARK: - Recording lifecycle, late log lines, export state, audio recovery

/// A started session with fakes only (no upload, no audio); stop it with `stopOnMain`.
private func makeRunningSession(root: URL, clock: ClockSource = SystemClock()) throws -> RecordingSession {
    let deps = RecordingSession.Dependencies(
        motion: SyntheticMotionSource(), location: nil, altimeter: nil, activity: nil, audio: nil,
        deviceStatus: FakeDeviceStatus(), uploadQueue: nil, clock: clock, deviceId: "D", appVersion: "t",
        deviceInfo: .init(model: "x", name: "x", iosVersion: "x"))
    let session = try RecordingSession(store: SessionStore(root: root), setup: SessionSetup(), preflight: nil, deps: deps)
    session.start() // XCTest runs test methods on the main thread
    return session
}

final class LifecycleNoteTests: XCTestCase {
    private func clockSources(_ session: RecordingSession) throws -> [String] {
        session.writer.flushNow()
        return try readCSV(session.folder.appendingPathComponent("clock.csv")).rows.map { $0[2] }
    }

    func testInactiveToActiveWithoutBackgroundIsNotAForegroundReturn() throws {
        let session = try makeRunningSession(root: try makeTempDir())
        defer { session.stop() }
        // Control Center / Notification Center / a call banner: inactive → active, never background.
        session.noteLifecycle(background: false)
        session.noteLifecycle(background: false)
        XCTAssertNil(session.latest.returnedFromBackgroundUp, "no 'App was in background' banner")
        XCTAssertFalse(try clockSources(session).contains("foreground"))
        let log = try String(contentsOf: session.folder.appendingPathComponent("app_log.txt"), encoding: .utf8)
        XCTAssertFalse(log.contains("app returned to foreground"))
    }

    func testRealBackgroundTripIsNotedOnceEachWay() throws {
        let session = try makeRunningSession(root: try makeTempDir())
        defer { session.stop() }
        session.noteLifecycle(background: true)
        session.noteLifecycle(background: true) // duplicate scene-phase callback
        XCTAssertTrue(session.latest.inBackground)
        session.noteLifecycle(background: false)
        session.noteLifecycle(background: false) // e.g. a later Control Center trip
        XCTAssertFalse(session.latest.inBackground)
        XCTAssertNotNil(session.latest.returnedFromBackgroundUp)
        let sources = try clockSources(session)
        XCTAssertEqual(sources.filter { $0 == "background" }.count, 1)
        XCTAssertEqual(sources.filter { $0 == "foreground" }.count, 1)
    }
}
