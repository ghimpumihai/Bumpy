import XCTest
@testable import SensorRecorder

/// The ingest contract accepts only finite numbers (no null) in a batch, and one bad value rejects the
/// whole batch, so a NaN/Inf sample is left out or, where iOS uses -1 for "invalid", sent as -1.
final class NonFiniteBatchTests: XCTestCase {
    private let nan = Double.nan

    private func dm(_ t: Double, uaX: Double = 0.01) -> DeviceMotionSample {
        DeviceMotionSample(t: t, userAccel: Vec3(x: uaX, y: 0, z: 0), gravity: Vec3(x: 0, y: 0, z: -1),
                           rotationRate: .zero, quaternion: Quaternion(w: 1, x: 0, y: 0, z: 0), roll: 0, pitch: 0, yaw: 0)
    }

    private func fix(lat: Double = 46.77, lon: Double = 23.62, alt: Double = 352, hAcc: Double = 5,
                     speed: Double = 8, course: Double = 90) -> LocationSample {
        LocationSample(utcMs: 1_763_716_532_120, lat: lat, lon: lon, alt: alt, ellAlt: 390, hAcc: hAcc, vAcc: 3,
                       speed: speed, speedAcc: 0.5, course: course, courseAcc: 3, isSimulated: false)
    }

    func testNonFiniteValuesNeverReachTheBatchAndArraysStayAligned() throws {
        let acc = BatchAccumulator(sessionId: "S", deviceId: "D")
        acc.add(dm(100.00))
        acc.add(dm(100.01, uaX: nan))
        acc.add(dm(100.02, uaX: .infinity))
        acc.add(dm(100.03))
        acc.addAccel(Vec3Sample(t: 100.0, v: Vec3(x: nan, y: 0, z: -1)))
        acc.addAccel(Vec3Sample(t: 100.01, v: Vec3(x: 0, y: 0, z: -1)))
        acc.addMag(Vec3Sample(t: 100.0, v: Vec3(x: 1, y: 2, z: -.infinity)))
        acc.add(fix())                                   // kept as is
        acc.add(fix(lat: nan))                           // no position: left out
        acc.add(fix(lat: -180, lon: -180))               // kCLLocationCoordinate2DInvalid: left out
        acc.add(fix(alt: nan, hAcc: nan, speed: nan, course: .infinity)) // kept, invalid values as -1
        acc.add(HeadingSample(utcMs: 1_763_716_532_000, magneticHeading: 10, trueHeading: nan, accuracy: nan, raw: Vec3(x: 1, y: 2, z: 3)))
        acc.add(HeadingSample(utcMs: 1_763_716_532_000, magneticHeading: 10, trueHeading: 12, accuracy: 5, raw: Vec3(x: nan, y: 2, z: 3)))
        acc.add(AltimeterSample(t: 100.0, relativeAltitudeM: 0.1, pressureKPa: nan))
        acc.add(AltimeterSample(t: 100.5, relativeAltitudeM: 0.2, pressureKPa: 97.2))
        acc.add(AbsoluteAltitudeSample(t: 100.0, altitudeM: 350, accuracyM: nan, precisionM: 1))
        acc.add(ActivitySample(t: nan, stationary: false, walking: false, running: false, automotive: true, cycling: false,
                               unknown: false, confidence: 2, startUtcMs: 1))
        let device = DeviceStatus(batteryLevel: .nan, batteryState: "unknown", thermal: .nominal, lowPowerMode: false,
                                  freeDiskBytes: 1, networkStatus: "satisfied", networkType: "wifi")
        let b = acc.drain(t0Up: 100, t0UtcMs: 1_763_716_532_000, device: device)

        XCTAssertNoThrow(try b.jsonData(), "JSONEncoder throws on NaN: such a batch would never be queued")
        XCTAssertEqual(b.deviceMotion.t, [0, 0.03], "the NaN and Inf samples are left out, not sent as 0")
        for col in [b.deviceMotion.ua_x, b.deviceMotion.g_z, b.deviceMotion.q_w, b.deviceMotion.yaw] {
            XCTAssertEqual(col.count, 2, "every column stays aligned with t")
        }
        XCTAssertEqual(b.accelRaw.t, [0.01]); XCTAssertEqual(b.accelRaw.x, [0])
        XCTAssertTrue(b.magRaw.t.isEmpty && b.magRaw.z.isEmpty)

        XCTAssertEqual(b.location.count, 2)
        XCTAssertEqual(b.location[0], IngestBatch.Location(tUtcMs: 1_763_716_532_120, lat: 46.77, lon: 23.62, alt: 352, hAcc: 5,
                                                          speed: 8, speedAcc: 0.5, course: 90, isSimulated: false,
                                                          ellAlt: 390, vAcc: 3, courseAcc: 3))
        let bad = b.location[1]
        XCTAssertEqual([bad.hAcc, bad.speed, bad.course], [-1, -1, -1], "iOS's own 'invalid' value")
        XCTAssertEqual(bad.vAcc, -1, "a non-finite altitude is marked invalid through vAcc, as iOS does")
        XCTAssertEqual(bad.alt, 0)

        XCTAssertEqual(b.heading.count, 1, "a heading without its raw vector is left out")
        XCTAssertEqual(b.heading.first?.trueHeading, -1)
        XCTAssertEqual(b.heading.first?.headingAcc, -1)
        XCTAssertEqual(b.altimeter.t, [0.5]); XCTAssertEqual(b.altimeter.pressureKpa, [97.2])
        XCTAssertTrue(b.absAltitude.t.isEmpty && b.absAltitude.accuracyM.isEmpty)
        XCTAssertTrue(b.activity.isEmpty)
        XCTAssertEqual(b.device.battery, -1, "-1 = unknown")

        // Everything the ingest contract checks is a finite number.
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: b.jsonData()) as? [String: Any])
        for block in ["deviceMotion", "accelRaw", "gyroRaw", "altimeter", "magRaw", "absAltitude"] {
            let cols = try XCTUnwrap(json[block] as? [String: [Double]], block)
            let n = cols["t"]?.count
            for (name, col) in cols {
                XCTAssertEqual(col.count, n, "\(block).\(name)")
                XCTAssertTrue(col.allSatisfy(\.isFinite), "\(block).\(name)")
            }
        }
    }
}
