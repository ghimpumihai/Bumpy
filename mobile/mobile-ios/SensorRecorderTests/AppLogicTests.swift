import XCTest
@testable import SensorRecorder

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

// MARK: - Recording lifecycle, late log lines, export cleanup

/// A started session with fakes only (no upload); stop it with `stopOnMain`.
private func makeRunningSession(root: URL, clock: ClockSource = SystemClock()) throws -> RecordingSession {
    let deps = RecordingSession.Dependencies(
        motion: SyntheticMotionSource(), location: nil, altimeter: nil, activity: nil,
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

final class LateLogTests: XCTestCase {
    func testUploadEventsAfterStopReachTheSessionLog() throws {
        let session = try makeRunningSession(root: try makeTempDir())
        session.stop()
        // What AppModel's uploadQueue.onEvent does for the final batches / Stop metadata.
        session.log(.warn, "upload retry: HTTP 503")
        session.log(.warn, "upload: batch_000007 rejected with HTTP 400, moved to upload_failed/")
        session.writer.drainLateLog()
        let log = try String(contentsOf: session.folder.appendingPathComponent("app_log.txt"), encoding: .utf8)
        let lines = log.split(separator: "\n").map(String.init)
        let stopped = try XCTUnwrap(lines.firstIndex { $0.contains("recording stopped") })
        let retry = try XCTUnwrap(lines.firstIndex { $0.contains("[WARN] upload retry: HTTP 503") })
        let rejected = try XCTUnwrap(lines.firstIndex { $0.contains("batch_000007 rejected") })
        XCTAssertLessThan(stopped, retry)
        XCTAssertLessThan(retry, rejected, "late lines keep their order")
        XCTAssertTrue(log.hasSuffix("\n"))
        // The finished session is still a finished session: recovery leaves it alone.
        XCTAssertTrue(SessionStore(root: session.folder.deletingLastPathComponent()).recoverUnfinishedSessions().isEmpty)
        XCTAssertNotNil(try SessionMetadata.load(from: session.folder.appendingPathComponent("session.json")).endedAtUtc)
    }

    func testLateLineNeverRecreatesADeletedSession() throws {
        let dir = try makeTempDir().appendingPathComponent("s")
        let w = try SessionWriter(folder: dir, files: [])
        w.close()
        try FileManager.default.removeItem(at: dir)
        w.log(.warn, "upload retry after delete")
        w.drainLateLog()
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path))
    }

    func testCloseRacingAppendNeverLosesAcceptedLines() throws {
        for _ in 0..<50 {
            let url = try makeTempDir().appendingPathComponent("x.txt")
            let w = try BufferedFileWriter(url: url, header: nil)
            let accepted = Locked(0)
            let group = DispatchGroup()
            DispatchQueue.global().async(group: group) {
                for i in 0..<200 where w.append(line: "l\(i)") { accepted.withLock { $0 += 1 } }
            }
            try w.close()
            group.wait()
            let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
            XCTAssertEqual(lines.count, accepted.current, "every accepted line is in the final flush")
            XCTAssertEqual(lines.count + w.droppedAfterClose.current, 200)
        }
    }
}

final class StaleExportCleanupTests: XCTestCase {
    func testStaleExportZipsAreRemovedAndNothingElse() throws {
        let base = try makeTempDir()
        let session = base.appendingPathComponent("2026-11-21T09-12-03Z_abcd")
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: session.appendingPathComponent("session.json"))
        let exports = base.appendingPathComponent("exports"), legacy = base.appendingPathComponent("tmp")
        for dir in [exports, legacy] { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        let zip = exports.appendingPathComponent("2026-11-21T09-12-03Z_abcd.zip")
        try Data().write(to: zip)
        try Data().write(to: legacy.appendingPathComponent("old.zip"))
        try Data().write(to: legacy.appendingPathComponent("keep.txt"))
        XCTAssertEqual(FolderZipper.removeStaleExports(exportDirectory: exports, legacyDirectory: legacy), 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: zip.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacy.appendingPathComponent("keep.txt").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: session.path), "never touches session data")
    }
}
