import XCTest
@testable import SensorRecorder

/// One test per row of the spec §7 "Warning rules" table.
final class HealthEvaluatorTests: XCTestCase {
    private func snap(_ id: StreamID, rate: Double, age: Double?, available: Bool = true) -> StreamSnapshot {
        StreamSnapshot(id: id, count: 1000, rateHz: rate, age: age, meanRateHz: rate, maxGap: 0.01,
                       gapsOver1s: 0, droppedEstimate: 0, available: available)
    }

    /// A healthy recording 60 s in.
    private func healthy() -> HealthInputs {
        var i = HealthInputs(now: 1060, recordingStartUp: 1000)
        i.streams = [.deviceMotion: snap(.deviceMotion, rate: 99.8, age: 0.01),
                     .accel: snap(.accel, rate: 99.9, age: 0.01),
                     .gyro: snap(.gyro, rate: 99.9, age: 0.01),
                     .mag: snap(.mag, rate: 50, age: 0.02),
                     .barometer: snap(.barometer, rate: 1, age: 0.6)]
        i.gpsLastFixUp = 1059.6
        i.gpsHorizontalAccuracy = 4.7
        i.freeDiskBytes = 40_000_000_000
        i.batteryLevel = 0.78
        i.batteryCharging = true
        return i
    }

    private func issues(_ i: HealthInputs) -> [HealthIssue] { HealthEvaluator.evaluate(i) }
    private func level(_ i: HealthInputs, _ keyPrefix: String) -> HealthLevel? {
        issues(i).first { $0.key.hasPrefix(keyPrefix) }?.level
    }

    func testHealthyIsAllOK() {
        XCTAssertEqual(issues(healthy()), [])
        XCTAssertEqual(HealthEvaluator.overall([]), .ok)
    }

    func testMotionRateBelow90IsWarn() {
        var i = healthy(); i.streams[.gyro] = snap(.gyro, rate: 85, age: 0.01)
        XCTAssertEqual(level(i, "rate.gyro"), .warn)
        XCTAssertEqual(HealthEvaluator.level(for: .gyro, in: issues(i)), .warn)
        XCTAssertEqual(HealthEvaluator.level(for: .accel, in: issues(i)), .ok)
    }

    func testMotionRateBelow50IsProblem() {
        var i = healthy(); i.streams[.accel] = snap(.accel, rate: 42, age: 0.01)
        XCTAssertEqual(level(i, "rate.accel"), .problem)
        XCTAssertEqual(HealthEvaluator.overall(issues(i)), .problem)
    }

    func testMagnetometerThresholdsScaleWithItsRate() {
        var i = healthy(); i.streams[.mag] = snap(.mag, rate: 47, age: 0.02)
        XCTAssertNil(level(i, "rate.mag"))
        i.streams[.mag] = snap(.mag, rate: 40, age: 0.02)
        XCTAssertEqual(level(i, "rate.mag"), .warn)
        i.streams[.mag] = snap(.mag, rate: 20, age: 0.02)
        XCTAssertEqual(level(i, "rate.mag"), .problem)
    }

    func testNoMotionSampleFor0_5sIsProblem() {
        var i = healthy(); i.streams[.deviceMotion] = snap(.deviceMotion, rate: 99, age: 0.6)
        XCTAssertEqual(level(i, "stale.deviceMotion"), .problem)
        i.streams[.deviceMotion] = snap(.deviceMotion, rate: 99, age: 0.4)
        XCTAssertNil(level(i, "stale.deviceMotion"))
    }

    func testUnavailableStreamIsIgnored() {
        var i = healthy(); i.streams[.mag] = snap(.mag, rate: 0, age: nil, available: false)
        XCTAssertEqual(issues(i), [])
    }

    func testRateNotJudgedDuringFirstWindowButMissingDataIs() {
        var i = healthy()
        i.now = 1001.0
        i.gpsLastFixUp = nil
        i.streams[.gyro] = snap(.gyro, rate: 30, age: 0.01) // window not full yet
        XCTAssertNil(level(i, "rate.gyro"))
        i.now = 1002.0
        i.streams[.accel] = snap(.accel, rate: 0, age: nil) // nothing at all after 2 s
        XCTAssertEqual(level(i, "stale.accel"), .problem)
    }

    func testGPSNoFixWarnAfter5ProblemAfter15() {
        var i = healthy()
        i.gpsLastFixUp = 1060 - 4
        XCTAssertNil(level(i, "gps.nofix"))
        i.gpsLastFixUp = 1060 - 6
        XCTAssertEqual(level(i, "gps.nofix"), .warn)
        i.gpsLastFixUp = 1060 - 16
        XCTAssertEqual(level(i, "gps.nofix"), .problem)
        i.gpsLastFixUp = nil // never had a fix; measured from start (60 s)
        XCTAssertEqual(level(i, "gps.nofix"), .problem)
    }

    func testGPSAccuracyAbove20IsWarn() {
        var i = healthy(); i.gpsHorizontalAccuracy = 25
        XCTAssertEqual(level(i, "gps.accuracy"), .warn)
        i.gpsHorizontalAccuracy = 20
        XCTAssertNil(level(i, "gps.accuracy"))
    }

    func testAudioNotRecordingIsProblem() {
        var i = healthy(); i.audioRecording = false
        XCTAssertEqual(level(i, "audio.off"), .problem)
        i.audioExpected = false
        XCTAssertNil(level(i, "audio.off"))
    }

    func testDiskWriteErrorIsProblemForAWhile() {
        var i = healthy(); i.lastWriteErrorUp = 1050; i.lastWriteError = "No space"
        XCTAssertEqual(level(i, "disk.write"), .problem)
        i.lastWriteErrorUp = 1020
        XCTAssertNil(level(i, "disk.write"))
    }

    func testFreeDiskThresholds() {
        var i = healthy(); i.freeDiskBytes = 900_000_000
        XCTAssertEqual(level(i, "disk.free"), .warn)
        i.freeDiskBytes = 200_000_000
        XCTAssertEqual(level(i, "disk.free"), .problem)
    }

    func testThermal() {
        var i = healthy(); i.thermal = .fair
        XCTAssertNil(level(i, "thermal"))
        i.thermal = .serious
        XCTAssertEqual(level(i, "thermal"), .warn)
        i.thermal = .critical
        XCTAssertEqual(level(i, "thermal"), .problem)
    }

    func testLowPowerModeIsProblem() {
        var i = healthy(); i.lowPowerMode = true
        XCTAssertEqual(level(i, "lowpower"), .problem)
    }

    func testBatteryLowAndNotCharging() {
        var i = healthy(); i.batteryLevel = 0.15; i.batteryCharging = true
        XCTAssertNil(level(i, "battery"))
        i.batteryCharging = false
        XCTAssertEqual(level(i, "battery"), .warn)
        i.batteryLevel = -1 // unknown (simulator)
        XCTAssertNil(level(i, "battery"))
    }

    func testBackgroundIsWarn() {
        var i = healthy(); i.inBackground = true
        XCTAssertEqual(level(i, "background"), .warn)
        i.inBackground = false; i.returnedFromBackgroundUp = 1055
        XCTAssertEqual(level(i, "background"), .warn)
        i.returnedFromBackgroundUp = 1040
        XCTAssertNil(level(i, "background"))
    }

    func testUploadIssuesAreNeverProblem() {
        var i = healthy()
        i.uploadEnabled = true
        i.uploadQueueCount = 31
        i.uploadLastSuccessUp = 1060 - 61
        let up = issues(i).filter { $0.key.hasPrefix("upload") }
        XCTAssertEqual(up.count, 2)
        XCTAssertTrue(up.allSatisfy { $0.level == .warn })
        // disabled upload -> nothing
        i.uploadEnabled = false
        XCTAssertTrue(issues(i).filter { $0.key.hasPrefix("upload") }.isEmpty)
    }

    func testUploadNoSuccessYetMeasuredFromEnable() {
        var i = healthy()
        i.uploadEnabled = true
        i.uploadEnabledSinceUp = 1030
        XCTAssertNil(level(i, "upload.stale"))
        i.uploadEnabledSinceUp = 990
        XCTAssertEqual(level(i, "upload.stale"), .warn)
    }

    func testIssuesSortedMostSevereFirst() {
        var i = healthy()
        i.thermal = .serious
        i.lowPowerMode = true
        let r = issues(i)
        XCTAssertEqual(r.first?.level, .problem)
        XCTAssertEqual(r.last?.level, .warn)
    }
}
