import XCTest
@testable import SensorRecorder

final class CSVTests: XCTestCase {
    func testFixedMatchesPrintfWithinHalfULPOfLastDigit() {
        var rng = SeededGenerator(seed: 0x5EED) // reproducible
        for _ in 0..<20_000 {
            let mag = [1e-7, 1e-3, 1, 50, 360, 1e5, 1e6][Int.random(in: 0..<7, using: &rng)]
            let v = Double.random(in: -mag...mag, using: &rng)
            let ours = CSV.f6(v)
            let parsed = Double(ours)!
            XCTAssertLessThanOrEqual(abs(parsed - v), 0.5e-6 + abs(v) * 1e-15, "\(v) -> \(ours)")
            // exactly 6 decimals, '.' separator
            XCTAssertEqual(ours.split(separator: ".").last?.count, 6, ours)
            XCTAssertFalse(ours.contains(","))
        }
    }

    func testFixedEdgeCases() {
        XCTAssertEqual(CSV.f6(0), "0.000000")
        XCTAssertEqual(CSV.f6(-0.0000001), "0.000000") // no "-0.000000"
        XCTAssertEqual(CSV.f6(-0.0000006), "-0.000001")
        XCTAssertEqual(CSV.f6(-1.5), "-1.500000")
        XCTAssertEqual(CSV.f6(123456.789012), "123456.789012")
        XCTAssertEqual(CSV.f8(46.771212345), "46.77121235")
        XCTAssertEqual(CSV.f8(-23.5), "-23.50000000")
        XCTAssertEqual(CSV.f6(.nan), "")
        XCTAssertEqual(CSV.f6(.infinity), "")
        XCTAssertEqual(CSV.ms(1_763_716_323_512.4), "1763716323512")
        XCTAssertEqual(CSV.ms(1_763_716_323_512.6), "1763716323513")
        XCTAssertEqual(CSV.fixed(1e15, decimals: 6), "1000000000000000.000000") // slow path, no trap
        XCTAssertEqual(CSV.bool(true), "1")
        XCTAssertEqual(CSV.bool(nil as Bool?), "")
    }

    func testEscape() {
        XCTAssertEqual(CSV.escape(nil), "")
        XCTAssertEqual(CSV.escape("cobblestones"), "cobblestones")
        XCTAssertEqual(CSV.escape("a,b"), "\"a,b\"")
        XCTAssertEqual(CSV.escape("say \"hi\""), "\"say \"\"hi\"\"\"")
        XCTAssertEqual(CSV.escape("two\nlines"), "\"two\nlines\"")
    }

    /// The schema is a contract with the backend — pin it to the spec text (§4).
    func testHeadersMatchSpec() {
        let expected: [StreamFile: String] = [
            .deviceMotion: "t_up,t_utc_ms,ua_x,ua_y,ua_z,g_x,g_y,g_z,rr_x,rr_y,rr_z,q_w,q_x,q_y,q_z,roll,pitch,yaw",
            .accelRaw: "t_up,t_utc_ms,x,y,z",
            .gyroRaw: "t_up,t_utc_ms,x,y,z",
            .magRaw: "t_up,t_utc_ms,x,y,z",
            .location: "t_up,t_utc_ms,lat,lon,alt,ell_alt,h_acc,v_acc,speed,speed_acc,course,course_acc,is_simulated",
            .heading: "t_up,t_utc_ms,mag_heading,true_heading,heading_acc,x,y,z",
            .altimeter: "t_up,t_utc_ms,rel_alt_m,pressure_kpa",
            .audioLevel: "t_up,t_utc_ms,avg_dbfs,peak_dbfs",
            .device: "t_up,t_utc_ms,battery_level,battery_state,thermal_state,low_power,free_disk_bytes,net_status,net_type",
            .labels: "t_up,t_utc_ms,type,value,note",
            .clock: "t_up,t_utc_ms,source",
        ]
        var all = expected
        // Additions documented in the README (extra files / trailing column):
        all[.activity] = "t_up,t_utc_ms,stationary,walking,running,automotive,cycling,unknown,confidence,start_utc_ms"
        all[.absAltitude] = "t_up,t_utc_ms,altitude_m,accuracy_m,precision_m"
        all[.audioSegments] = "t_up,t_utc_ms,event,file"
        XCTAssertEqual(Set(all.keys), Set(StreamFile.allCases), "every file's header is pinned")
        for (file, header) in all { XCTAssertEqual(file.header, header, file.rawValue) }
    }
}

final class TimeBaseTests: XCTestCase {
    func testConversionUsesLatestAnchor() {
        let clock = FakeClock(up: 1000, utcMs: 1_700_000_000_000)
        let tb = TimeBase(clock: clock)
        XCTAssertEqual(tb.utcMs(fromUptime: 1000), 1_700_000_000_000, accuracy: 1e-6)
        XCTAssertEqual(tb.utcMs(fromUptime: 1001.5), 1_700_000_001_500, accuracy: 1e-6)
        XCTAssertEqual(tb.uptime(fromUtcMs: 1_700_000_002_000), 1002, accuracy: 1e-9)
        XCTAssertEqual(tb.uptime(from: Date(timeIntervalSince1970: 1_699_999_999)), 999, accuracy: 1e-6)

        // Wall clock gets corrected by +250 ms (NTP); after re-anchoring the new offset applies.
        clock.advance(10)
        clock.jumpWall(250)
        tb.refreshAnchor()
        XCTAssertEqual(tb.utcMs(fromUptime: 1010), 1_700_000_010_250, accuracy: 1e-6)
    }

    func testAnchorUsesMidpointOfUptimeReads() {
        final class SteppingClock: ClockSource, @unchecked Sendable {
            var calls = 0
            func uptime() -> TimeInterval { calls += 1; return calls == 1 ? 10.0 : 10.002 }
            func nowUtcMs() -> Double { 5000 }
        }
        let a = TimeBase.sample(SteppingClock())
        XCTAssertEqual(a.up, 10.001, accuracy: 1e-9)
        XCTAssertEqual(a.utcMs, 5000)
    }
}

final class RingBufferTests: XCTestCase {
    func testOverwritesOldest() {
        var r = RingBuffer<Int>(capacity: 3)
        XCTAssertEqual(r.elements, [])
        XCTAssertNil(r.last)
        r.append(1); r.append(2)
        XCTAssertEqual(r.elements, [1, 2])
        r.append(3); r.append(4); r.append(5)
        XCTAssertEqual(r.elements, [3, 4, 5])
        XCTAssertEqual(r.last, 5)
        XCTAssertEqual(r.count, 3)
    }
}

final class WriterTests: XCTestCase {
    func testHeaderAppendFlushClose() throws {
        let dir = try makeTempDir()
        let url = dir.appendingPathComponent("x.csv")
        let w = try BufferedFileWriter(url: url, header: "a,b")
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "a,b\n", "header must be on disk immediately")
        w.append(line: "1,2")
        w.append(line: "3,4")
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "a,b\n", "buffered until flush")
        try w.flush()
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "a,b\n1,2\n3,4\n")
        w.append(line: "5,6")
        try w.close()
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "a,b\n1,2\n3,4\n5,6\n")
        XCTAssertEqual(w.bytesWritten, Int64("a,b\n1,2\n3,4\n5,6\n".utf8.count))
    }

    func testRefusesToOverwriteExistingFile() throws {
        let dir = try makeTempDir()
        let url = dir.appendingPathComponent("x.csv")
        try Data("old".utf8).write(to: url)
        XCTAssertThrowsError(try BufferedFileWriter(url: url, header: "a"))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "old")
    }

    func testConcurrentAppendsAreAllWrittenIntact() throws {
        let dir = try makeTempDir()
        let url = dir.appendingPathComponent("c.csv")
        let w = try BufferedFileWriter(url: url, header: "thread,i")
        let flushQ = DispatchQueue(label: "flush")
        let stop = Locked(false)
        flushQ.async { while !stop.current { try? w.flush(); usleep(500) } }
        DispatchQueue.concurrentPerform(iterations: 8) { th in
            for i in 0..<5000 { w.append(line: "\(th),\(i)") }
        }
        stop.withLock { $0 = true }
        flushQ.sync {}
        try w.close()
        let (h, rows) = try readCSV(url)
        XCTAssertEqual(h, ["thread", "i"])
        XCTAssertEqual(rows.count, 40_000)
        var seen = Set<String>()
        for r in rows {
            XCTAssertEqual(r.count, 2)
            seen.insert(r.joined(separator: ","))
        }
        XCTAssertEqual(seen.count, 40_000)
        // per-thread order preserved
        for th in 0..<8 {
            let mine = rows.filter { $0[0] == "\(th)" }.map { Int($0[1])! }
            XCTAssertEqual(mine, Array(0..<5000))
        }
    }

    /// Spec: flush at least every 1 s, so a crash loses at most ~1 s.
    func testSessionWriterFlushesPeriodicallyWithoutExplicitFlush() throws {
        let dir = try makeTempDir()
        let w = try SessionWriter(folder: dir.appendingPathComponent("s"))
        w.start()
        w.append(.accelRaw, "1.000000,1000,0.1,0.2,0.3")
        w.log(.info, "hello")
        // The 0.5 s timer must get it to disk without any explicit flush. Poll (slow CI simulators).
        let url = dir.appendingPathComponent("s/accel_raw.csv")
        let deadline = Date().addingTimeInterval(ciTimeout)
        var text = ""
        while Date() < deadline {
            text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            if text.contains("1000,0.1") { break }
            Thread.sleep(forTimeInterval: 0.05)
        }
        XCTAssertEqual(text, "t_up,t_utc_ms,x,y,z\n1.000000,1000,0.1,0.2,0.3\n")
        Thread.sleep(forTimeInterval: 0.6) // the log line is flushed by the same timer
        let log = try String(contentsOf: dir.appendingPathComponent("s/app_log.txt"), encoding: .utf8)
        XCTAssertTrue(log.contains("[INFO] hello"))
        w.close()
        w.close() // idempotent
    }
}

final class GapTrackerTests: XCTestCase {
    func testRatesGapsAndDrops() {
        var g = GapTracker(expectedHz: 100)
        for i in 0..<100 { g.add(Double(i) * 0.01) }       // 0.00 ... 0.99
        g.add(0.99 + 0.05)                                  // gap of 50 ms -> 4 dropped
        g.add(1.04 + 1.5)                                   // gap of 1.5 s -> 149 dropped, 1 gap > 1 s
        XCTAssertEqual(g.count, 102)
        XCTAssertEqual(g.maxGap, 1.5, accuracy: 1e-9)
        XCTAssertEqual(g.gapsOver1s, 1)
        XCTAssertEqual(g.droppedEstimate, 4 + 149)
        XCTAssertEqual(g.meanRateHz, 101.0 / 2.54, accuracy: 1e-6)
        g.add(2.0) // out of order
        XCTAssertEqual(g.nonMonotonic, 1)
        XCTAssertEqual(g.maxGap, 1.5, accuracy: 1e-9)
    }

    func testSignificantGapPerStream() {
        XCTAssertEqual(StreamID.accel.significantGap, 1)        // spec: gaps > 1 s are red
        XCTAssertEqual(StreamID.gps.significantGap, 3)          // 1 Hz GPS: ~1 s gaps are normal
        XCTAssertEqual(StreamID.barometer.significantGap, .infinity)
    }

    func testMonitorWindowRateAndAge() {
        let m = StreamMonitor(id: .accel)
        // 3 s of data at 50 Hz, then nothing
        for i in 0..<150 { let t = 100 + Double(i) * 0.02; m.record(t: t, arrival: t) }
        let s = m.snapshot(now: 103.0)
        XCTAssertEqual(s.rateHz, 50, accuracy: 0.5)
        XCTAssertEqual(s.age ?? -1, 103.0 - 102.98, accuracy: 1e-9)
        XCTAssertEqual(s.count, 150)
        // 5 s later: no samples in window -> rate 0
        let later = m.snapshot(now: 108)
        XCTAssertEqual(later.rateHz, 0)
        XCTAssertEqual(later.age ?? 0, 5.02, accuracy: 1e-9)
    }
}

final class GzipTests: XCTestCase {
    func testCRC32KnownVector() {
        XCTAssertEqual(CRC32.checksum(Data("123456789".utf8)), 0xCBF4_3926)
        XCTAssertEqual(CRC32.checksum(Data()), 0)
    }

    func testRoundTrip() throws {
        for size in [0, 1, 10, 1000, 100_000] {
            var rng = SystemRandomNumberGenerator()
            let text = (0..<size).map { _ in "0123456789,.-abc"[Int.random(in: 0..<16, using: &rng)] }
            let data = Data(String(text).utf8)
            let gz = try Gzip.compress(data)
            XCTAssertEqual(Array(gz.prefix(3)), [0x1f, 0x8b, 0x08])
            XCTAssertEqual(try Gzip.decompress(gz), data, "size \(size)")
        }
    }

    func testIncompressibleData() throws {
        var rng = SystemRandomNumberGenerator()
        let data = Data((0..<50_000).map { _ in UInt8.random(in: 0...255, using: &rng) })
        XCTAssertEqual(try Gzip.decompress(Gzip.compress(data)), data)
    }

    func testDetectsCorruption() throws {
        var gz = try Gzip.compress(Data("hello hello hello".utf8))
        gz[gz.count - 6] ^= 0xff // flip CRC byte
        XCTAssertThrowsError(try Gzip.decompress(gz))
    }
}

private extension String {
    subscript(i: Int) -> Character { self[index(startIndex, offsetBy: i)] }
}
