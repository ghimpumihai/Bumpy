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

final class ExportStateTests: XCTestCase {
    private let sharing = ExportState.sharing(name: "s.zip", bytes: 10)

    func testOnlyACompletedShareCountsAsExported() {
        let done = sharing.shareFinished(completed: true, activity: "com.apple.UIKit.activity.AirDrop", error: nil)
        XCTAssertEqual(done.state, .exported(name: "s.zip", bytes: 10))
        XCTAssertTrue(done.sheetClosed)
        let dismissed = sharing.shareFinished(completed: false, activity: nil, error: nil)
        XCTAssertEqual(dismissed.state, .cancelled(name: "s.zip", bytes: 10), "closing the sheet is not an export")
        XCTAssertTrue(dismissed.sheetClosed, "zip can be deleted")
    }

    func testBackingOutOfAnActivityKeepsTheSheetAndTheZip() {
        let backed = sharing.shareFinished(completed: false, activity: "com.apple.UIKit.activity.Mail", error: nil)
        XCTAssertEqual(backed.state, sharing)
        XCTAssertFalse(backed.sheetClosed, "the sheet is still up: keep the zip for the next activity")
        let failed = sharing.shareFinished(completed: false, activity: "x", error: "boom")
        XCTAssertEqual(failed.state, .sharing(name: "s.zip", bytes: 10, error: "boom"))
        XCTAssertFalse(failed.sheetClosed)
        // ... then another activity succeeds: still an export.
        XCTAssertEqual(failed.state.shareFinished(completed: true, activity: "y", error: nil).state,
                       .exported(name: "s.zip", bytes: 10))
        // ... or the sheet is closed: the failure is shown.
        XCTAssertEqual(failed.state.shareFinished(completed: false, activity: nil, error: nil).state, .failed("Export failed: boom"))
    }

    func testBusyOnlyWhileZipping() {
        XCTAssertTrue(ExportState.zipping.isBusy)
        XCTAssertFalse(sharing.isBusy, "a share sheet that never reports back must not lock Export")
        XCTAssertFalse(ExportState.cancelled(name: "s.zip", bytes: 1).isBusy)
        XCTAssertFalse(ExportState.exported(name: "s.zip", bytes: 1).isBusy)
    }

    func testZipGoesToTheExportFolderAndStaleZipsAreRemoved() throws {
        let base = try makeTempDir()
        let session = base.appendingPathComponent("2026-11-21T09-12-03Z_abcd")
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: session.appendingPathComponent("session.json"))
        let exports = base.appendingPathComponent("exports"), legacy = base.appendingPathComponent("tmp")
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        let zip = try FolderZipper.zip(session, into: exports)
        XCTAssertEqual(zip.deletingLastPathComponent().standardizedFileURL, exports.standardizedFileURL)
        try Data().write(to: legacy.appendingPathComponent("old.zip"))
        try Data().write(to: legacy.appendingPathComponent("keep.txt"))
        XCTAssertEqual(FolderZipper.removeStaleExports(exportDirectory: exports, legacyDirectory: legacy), 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: zip.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacy.appendingPathComponent("keep.txt").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: session.path), "never touches session data")
        FolderZipper.removeExport(zip) // already gone: no throw, no crash
    }
}

final class AudioRecoveryPolicyTests: XCTestCase {
    private func decide(now: Double, rec: Bool = false, blocked: Bool = false, last: Double = 0,
                        seg: Double = 0, lastRotate: Double = -.infinity) -> AudioSegmentPolicy.Action {
        AudioSegmentPolicy.decide(now: now, isRecording: rec, segmentStartedUp: seg, wantRecording: true,
                                  interrupted: false, interruptedAtUp: 0, lastRestartAttemptUp: last,
                                  backgroundBlocked: blocked, lastRotateAttemptUp: lastRotate)
    }

    func testBlockedInBackgroundStopsHammering() {
        XCTAssertEqual(decide(now: 106, last: 100), .restart, "normal cadence: every 5 s")
        XCTAssertEqual(decide(now: 106, blocked: true, last: 100), .none, "refused in background: slow down")
        XCTAssertEqual(decide(now: 159, blocked: true, last: 100), .none)
        XCTAssertEqual(decide(now: 161, blocked: true, last: 100), .restart)
    }

    func testFailedRotationIsRetriedLaterNotEveryTick() {
        XCTAssertEqual(decide(now: 300, rec: true), .rotate)
        XCTAssertEqual(decide(now: 300.1, rec: true, lastRotate: 300), .none, "keeps the running segment")
        XCTAssertEqual(decide(now: 310, rec: true, lastRotate: 300), .rotate)
    }
}

final class CaptureClockTests: XCTestCase {
    func testBufferIsStampedWithItsCaptureTime() {
        // Host clock and uptime have different epochs; only the buffer's age matters.
        let t = CaptureClock.bufferStartUp(bufferHostSec: 5_000.000, nowHostSec: 5_000.045, nowUp: 1_000, bufferDuration: 0.021)
        XCTAssertEqual(t, 999.955, accuracy: 1e-9, "processed 45 ms after capture")
    }

    func testInvalidHostTimeFallsBackToBufferEndingNow() {
        XCTAssertEqual(CaptureClock.bufferStartUp(bufferHostSec: nil, nowHostSec: 1, nowUp: 1_000, bufferDuration: 0.02), 999.98,
                       accuracy: 1e-9)
        XCTAssertEqual(CaptureClock.bufferStartUp(bufferHostSec: 10, nowHostSec: 5, nowUp: 1_000, bufferDuration: 0.02), 999.98,
                       accuracy: 1e-9, "future host time")
        XCTAssertEqual(CaptureClock.bufferStartUp(bufferHostSec: 0, nowHostSec: 500, nowUp: 1_000, bufferDuration: 0.02), 999.98,
                       accuracy: 1e-9, "implausibly old")
    }

    func testWindowsInsideOneBufferGetTheirOwnTimes() {
        var acc = LevelAccumulator(windowSeconds: 0.1)
        let fs = 1_000.0
        let w = acc.add(samples: [Float](repeating: 0.5, count: 250), sampleRate: fs, startUp: 10)
        XCTAssertEqual(w.count, 2)
        XCTAssertEqual(w[0].t, 10.1, accuracy: 1e-9, "not both stamped with the processing time")
        XCTAssertEqual(w[1].t, 10.2, accuracy: 1e-9)
        // The partial third window continues in the next buffer.
        let next = acc.add(samples: [Float](repeating: 0.5, count: 50), sampleRate: fs, startUp: 10.25)
        XCTAssertEqual(next.count, 1)
        XCTAssertEqual(next[0].t, 10.3, accuracy: 1e-9)
    }
}
