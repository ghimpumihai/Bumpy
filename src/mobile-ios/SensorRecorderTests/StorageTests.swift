import XCTest
@testable import SensorRecorder

final class SessionMetadataTests: XCTestCase {
    static func sample() -> SessionMetadata {
        SessionMetadata(sessionId: "ABC", appVersion: "1.0.0 (1) abc123",
                        device: .init(model: "iPhone15,2", name: "iPhone 14 Pro", iosVersion: "18.1"),
                        timezone: "Europe/Bucharest", startedAtUtc: "2026-11-21T09:12:03.512Z",
                        startUptimeSec: 123456.789012, endedAtUtc: nil, vehicle: .init(), mount: .init(),
                        people: .init(), conditions: .init(), requestedRatesHz: SessionMetadata.requestedRates,
                        recovered: false, recoveredAtUtc: nil, syntheticSensors: false,
                        folderName: "2026-11-21T09-12-03Z_abcd", deviceId: "DEV", preflight: nil, stats: nil)
    }

    func testJSONHasSpecKeysAndExplicitNulls() throws {
        let data = try Self.sample().jsonData()
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        for key in ["sessionId", "appVersion", "device", "timezone", "startedAtUtc", "startUptimeSec", "endedAtUtc",
                    "vehicle", "mount", "people", "conditions", "requestedRatesHz", "recovered", "stats"] {
            XCTAssertNotNil(obj.index(forKey: key), "missing \(key)")
        }
        XCTAssertTrue(obj["endedAtUtc"] is NSNull)
        XCTAssertTrue(obj["stats"] is NSNull)
        let device = try XCTUnwrap(obj["device"] as? [String: Any])
        XCTAssertEqual(device["model"] as? String, "iPhone15,2")
        let mount = try XCTUnwrap(obj["mount"] as? [String: Any])
        XCTAssertEqual(Set(mount.keys), ["location", "phoneOrientation", "rigid"]) // photoFile omitted when nil
        let people = try XCTUnwrap(obj["people"] as? [String: Any])
        XCTAssertNotNil(people["operatorSeat"]); XCTAssertNotNil(people["raterSeat"]); XCTAssertNotNil(people["passengerCount"])
        let rates = try XCTUnwrap(obj["requestedRatesHz"] as? [String: Double])
        XCTAssertEqual(rates, ["deviceMotion": 100, "accel": 100, "gyro": 100, "mag": 50, "audioLevel": 10])
    }

    func testRoundTrip() throws {
        var m = Self.sample()
        m.endedAtUtc = "2026-11-21T10:00:00.000Z"
        m.stats = .init(durationSec: 10, streams: ["accel": .init(samples: 1000, meanRateHz: 99.9, maxGapSec: 0.02,
                                                                   gapsOver1s: 0, droppedEstimate: 0, fileBytes: 100)],
                        labelsCount: 3, sicknessRatings: 1, sicknessMissed: 0, audioFiles: ["audio_000.m4a"],
                        fileSizes: [:], totalBytes: 100, writeErrors: 0, uploadBatchesCreated: 5)
        let dir = try makeTempDir()
        let url = dir.appendingPathComponent("session.json")
        try m.write(to: url)
        XCTAssertEqual(try SessionMetadata.load(from: url), m)
    }
}

final class SessionStoreTests: XCTestCase {
    func testFolderNameFormat() {
        let id = UUID(uuidString: "7F3A1234-0000-0000-0000-000000000000")!
        let date = ISO8601.date("2026-11-21T09:12:03.512Z")!
        XCTAssertEqual(SessionStore.folderName(start: date, id: id), "2026-11-21T09-12-03Z_7f3a")
    }

    func testRecoveryMarksUnfinishedRepairsCSVsAndFillsStats() throws {
        let root = try makeTempDir()
        let store = SessionStore(root: root)

        // An unfinished session with a torn last line
        let crashed = try store.makeSessionFolder(start: Date(timeIntervalSince1970: 1_700_000_000), id: UUID())
        var meta = SessionMetadataTests.sample()
        try meta.write(to: crashed.appendingPathComponent("session.json"))
        var csv = "t_up,t_utc_ms,x,y,z\n"
        for i in 0..<200 { csv += "\(CSV.f6(100 + Double(i) * 0.01)),1,0.1,0.2,0.3\n" }
        csv += "102.000000,1,0.1,0." // torn
        try Data(csv.utf8).write(to: crashed.appendingPathComponent("accel_raw.csv"))
        try Data("t_up,t_utc_ms,type,value,note\n100.5,1,pothole,,\n101,1,sickness,3,prompt\n".utf8)
            .write(to: crashed.appendingPathComponent("labels.csv"))

        // A finished session
        let finished = try store.makeSessionFolder(start: Date(timeIntervalSince1970: 1_700_001_000), id: UUID())
        meta.endedAtUtc = "2026-11-21T10:00:00.000Z"
        try meta.write(to: finished.appendingPathComponent("session.json"))

        // A currently-recording session (must not be touched)
        let active = try store.makeSessionFolder(start: Date(timeIntervalSince1970: 1_700_002_000), id: UUID())
        meta.endedAtUtc = nil
        try meta.write(to: active.appendingPathComponent("session.json"))

        let recovered = store.recoverUnfinishedSessions(excluding: active)
        XCTAssertEqual(recovered.map(\.lastPathComponent), [crashed.lastPathComponent])

        let r = try SessionMetadata.load(from: crashed.appendingPathComponent("session.json"))
        XCTAssertTrue(r.recovered)
        XCTAssertNotNil(r.recoveredAtUtc)
        XCTAssertNil(r.endedAtUtc)
        let accel = try XCTUnwrap(r.stats?.streams["accel"])
        XCTAssertEqual(accel.samples, 200)
        XCTAssertEqual(accel.meanRateHz, 100, accuracy: 0.01)
        XCTAssertEqual(r.stats?.labelsCount, 2)
        XCTAssertEqual(r.stats?.sicknessRatings, 1)

        let text = try String(contentsOf: crashed.appendingPathComponent("accel_raw.csv"), encoding: .utf8)
        XCTAssertTrue(text.hasSuffix("0.1,0.2,0.3\n"))
        XCTAssertEqual(text.split(separator: "\n").count, 201)
        let log = try String(contentsOf: crashed.appendingPathComponent("app_log.txt"), encoding: .utf8)
        XCTAssertTrue(log.contains("session recovered"))
        XCTAssertTrue(log.contains("trimmed 19 bytes"))

        XCTAssertFalse(try SessionMetadata.load(from: finished.appendingPathComponent("session.json")).recovered)
        XCTAssertFalse(try SessionMetadata.load(from: active.appendingPathComponent("session.json")).recovered)

        // Second launch: nothing more to recover
        XCTAssertEqual(store.recoverUnfinishedSessions(excluding: active), [])

        // Listing: newest first, recovered flag visible
        let list = store.list()
        XCTAssertEqual(list.count, 3)
        XCTAssertEqual(list.first?.folder.lastPathComponent, active.lastPathComponent)
        XCTAssertTrue(list.first { $0.folder.lastPathComponent == crashed.lastPathComponent }!.isRecovered)
    }

    func testRepairTornLineEdgeCases() throws {
        let dir = try makeTempDir()
        let url = dir.appendingPathComponent("a.csv")
        try Data("h\n1\n2\n".utf8).write(to: url)
        XCTAssertEqual(try CSVRepair.repairTornLine(url), 0)
        try Data("h\n1\n2".utf8).write(to: url)
        XCTAssertEqual(try CSVRepair.repairTornLine(url), 1)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "h\n1\n")
        try Data().write(to: url)
        XCTAssertEqual(try CSVRepair.repairTornLine(url), 0)
        // long torn line spanning multiple chunks
        let long = "h\n" + String(repeating: "x", count: 200_000)
        try Data(long.utf8).write(to: url)
        XCTAssertEqual(try CSVRepair.repairTornLine(url), 200_000)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "h\n")
    }

    func testAnalyzerParsesFirstColumn() throws {
        let dir = try makeTempDir()
        try Data("t_up,t_utc_ms,x,y,z\n1.0,0,0,0,0\n1.01,0,0,0,0\n1.02,0,0,0,0\n".utf8)
            .write(to: dir.appendingPathComponent("gyro_raw.csv"))
        let r = SessionAnalyzer.analyze(folder: dir)
        XCTAssertEqual(r.streams[.gyro]?.count, 3)
        XCTAssertEqual(r.streams[.gyro]?.meanRateHz ?? 0, 100, accuracy: 0.01)
        XCTAssertEqual(r.durationSec, 0.02, accuracy: 1e-9)
    }
}
