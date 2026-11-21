import XCTest
@testable import SensorRecorder

final class WfFilterTests: XCTestCase {
    /// ISO 2631-1 Wf weighting factors (Table 3 of the standard, ×1000): 0.1 Hz → 695, 0.2 Hz → ~1000,
    /// 0.63 Hz → ~0.4–0.5 region. The design must reproduce the analog weighting closely at fs = 10 Hz.
    func testFrequencyResponseMatchesISOWeighting() {
        let wf = WfFilter(fs: 10)
        XCTAssertEqual(wf.magnitude(at: 0.1), 0.695, accuracy: 0.02)
        XCTAssertEqual(wf.magnitude(at: 0.2), 0.99, accuracy: 0.03)
        XCTAssertLessThan(wf.magnitude(at: 0.02), 0.1)   // strong attenuation of drift
        XCTAssertLessThan(wf.magnitude(at: 2.0), 0.15)   // road vibration is not "sickness"
        // peak of Wf is ~1.0 in the 0.125–0.25 Hz band
        let peak = stride(from: 0.05, through: 1.0, by: 0.005).map { wf.magnitude(at: $0) }.max()!
        XCTAssertEqual(peak, 1.0, accuracy: 0.06)
    }

    func testTimeDomainSineAmplitude() {
        var wf = WfFilter(fs: 10)
        let f = 0.2, amp = 1.0
        var out: [Double] = []
        for n in 0..<3000 { out.append(wf.process(amp * sin(2 * .pi * f * Double(n) / 10))) }
        let tail = out.suffix(500)
        let peak = tail.map(abs).max()!
        XCTAssertEqual(peak, WfFilter(fs: 10).magnitude(at: f) * amp, accuracy: 0.02)
    }
}

final class LiveSignalsTests: XCTestCase {
    private func sample(t: Double, ua: Vec3, g: Vec3) -> DeviceMotionSample {
        DeviceMotionSample(t: t, userAccel: ua, gravity: g, rotationRate: .zero,
                           quaternion: Quaternion(w: 1, x: 0, y: 0, z: 0), roll: 0, pitch: 0, yaw: 0)
    }

    func testProjectionFlatPhone() {
        // Phone flat, screen up: gravity = -z. CoreMotion reports minus the phone's acceleration, so
        // ua.z = -0.3 is the phone accelerating up at 0.3 g, and ua.x = +0.1 is it accelerating
        // towards -x, the vehicle's left.
        let p = LiveSignals.project(sample(t: 0, ua: Vec3(x: 0.1, y: 0.05, z: -0.3), g: Vec3(x: 0, y: 0, z: -1)))
        XCTAssertEqual(p.vertical, 0.3, accuracy: 1e-12)
        XCTAssertEqual(p.lateral, 0.1, accuracy: 1e-12)
    }

    func testProjectionTiltedPhone() {
        // Phone upright in portrait facing the driver (gravity = -y): up = +y, device +x = the vehicle's right.
        let p = LiveSignals.project(sample(t: 0, ua: Vec3(x: -0.2, y: -0.4, z: 0.1), g: Vec3(x: 0, y: -1, z: 0)))
        XCTAssertEqual(p.vertical, 0.4, accuracy: 1e-12)
        XCTAssertEqual(p.lateral, -0.2, accuracy: 1e-12) // accelerating to the right
    }

    func testFreeFallReadsMinusOneG() {
        // Screen up in free fall: the accelerometer reads 0, so userAcceleration = 0 - gravity = +1 g on z.
        let p = LiveSignals.project(sample(t: 0, ua: Vec3(x: 0, y: 0, z: 1), g: Vec3(x: 0, y: 0, z: -1)))
        XCTAssertEqual(p.vertical, -1, accuracy: 1e-12)
    }

    func testLeftTurnIsPositiveLateral() {
        // A left turn pushes the phone towards the vehicle's left (-x when flat, top to the front);
        // CoreMotion reports the opposite, +x. The backend (dsp.py) also has lateral positive to the left.
        let p = LiveSignals.project(sample(t: 0, ua: Vec3(x: 0.2, y: 0, z: 0), g: Vec3(x: 0, y: 0, z: -1)))
        XCTAssertEqual(p.lateral, 0.2, accuracy: 1e-12)
    }

    /// A deterministic ±2 ms jitter, as CoreMotion's timestamps have around the nominal 100 Hz.
    private func jitteredTimes(seconds: Double) -> [Double] {
        var seed: UInt64 = 42
        return (0..<Int(seconds * 100)).map { n in
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            let u = Double(seed >> 11) / Double(1 << 53) // [0, 1)
            return Double(n) * 0.01 + (u - 0.5) * 0.004
        }
    }

    func testLiveMSDVWithJitteredTimestampsMatchesTheWeighting() {
        // 300 s of 0.1 g vertical sway at 0.2 Hz: MSDV = a·|Wf(0.2 Hz)|/√2·√T. Blocks that restarted at
        // their last sample took 11 samples whenever the clock jittered and read ~6 % low.
        let live = LiveSignals()
        let amp = 0.1, f = 0.2, seconds = 300.0
        for t in jitteredTimes(seconds: seconds) {
            live.add(sample(t: t, ua: Vec3(x: 0, y: 0, z: -amp * sin(2 * .pi * f * t)), g: Vec3(x: 0, y: 0, z: -1)))
        }
        let expected = amp * LiveSignals.g * WfFilter(fs: 10).magnitude(at: f) / 2.0.squareRoot() * seconds.squareRoot()
        XCTAssertEqual(live.snapshot().msdv / expected, 1, accuracy: 0.02)
        XCTAssertEqual(live.snapshot().lateral.count, 600) // 10 Hz blocks (ring holds 60 s)
    }

    func testRoughnessBandIsTheBackends() {
        // scipy.signal.sosfreqz of the backend's SOS_BAND
        let band = RoughnessBand()
        XCTAssertEqual(band.magnitude(at: 10), 0.999999914489249, accuracy: 1e-9)
        XCTAssertEqual(band.magnitude(at: 25), 0.9687437975974774, accuracy: 1e-9)
        XCTAssertEqual(band.magnitude(at: 0.5), 0.058147542080446604, accuracy: 1e-9)
    }

    func testRoughnessNowMatchesTheBackend() {
        // 60 s of a vertical sine with RMS 1 m/s²; the backend's band-pass + 5 s EMA (computed with
        // scipy) gives 1.0008 at 10 Hz and 0.0586 at 0.5 Hz, which is sway, not roughness.
        for (f, expected) in [(10.0, 1.0008316430477706), (0.5, 0.05856751893422164)] {
            let live = LiveSignals()
            let amp = 2.0.squareRoot() / LiveSignals.g
            for n in 0..<6000 {
                let t = Double(n) * 0.01
                live.add(sample(t: t, ua: Vec3(x: 0, y: 0, z: -amp * sin(2 * .pi * f * t)), g: Vec3(x: 0, y: 0, z: -1)))
            }
            XCTAssertEqual(live.snapshot().roughnessRms, expected, accuracy: 0.002, "\(f) Hz")
        }
    }

    func testBuffersRoughnessAndMSDV() {
        let live = LiveSignals()
        // 60 s at 100 Hz of 0.2 Hz vertical sway with 0.1 g amplitude
        for n in 0..<6000 {
            let t = Double(n) * 0.01
            live.add(sample(t: t, ua: Vec3(x: 0, y: 0, z: 0.1 * sin(2 * .pi * 0.2 * t)), g: Vec3(x: 0, y: 0, z: -1)))
        }
        let s = live.snapshot()
        XCTAssertEqual(s.vertical.count, 1000)
        XCTAssertGreaterThanOrEqual(s.lateral.count, 598) // 10 Hz decimation of 60 s (ring holds 600)
        XCTAssertGreaterThan(s.roughnessRms, 0)
        // Expected MSDV ≈ a_rms_weighted * sqrt(T): 0.1 g * 9.81 * ~0.99 / sqrt(2) * sqrt(60) ≈ 5.3 (minus filter settling)
        XCTAssertEqual(s.msdv, 5.3, accuracy: 0.8)
    }

    func testTrackThinning() {
        let tr = TrackBuffer()
        let base = LocationSample(utcMs: 0, lat: 46.77, lon: 23.62, alt: 0, ellAlt: 0, hAcc: 5, vAcc: 5, speed: 10,
                                  speedAcc: 1, course: 0, courseAcc: 0, isSimulated: nil)
        tr.add(base)
        var near = base; near.lat += 0.00001 // ~1 m
        tr.add(near)
        var far = base; far.lat += 0.0001     // ~11 m
        tr.add(far)
        var junk = base; junk.lat += 0.01; junk.hAcc = 500
        tr.add(junk)
        XCTAssertEqual(tr.current.points.count, 2)
    }
}

/// End-to-end: a real RecordingSession with synthetic 100 Hz motion and fake GPS/baro/audio/activity,
/// writing to a temp folder. Verifies the files a backend would read.
final class RecordingSessionIntegrationTests: XCTestCase {
    func testThreeSecondRecordingProducesValidSession() throws {
        let root = try makeTempDir()
        let store = SessionStore(root: root.appendingPathComponent("sessions"))
        let transport = MockTransport()
        // Upload ON (loop not started): batches are queued to disk and can be inspected.
        let uploadQueue = UploadQueue(directory: root.appendingPathComponent("upload_queue"), transport: transport,
                                      config: { UploadConfig(baseURL: URL(string: "https://api.test"), deviceKey: "k") })
        let deps = RecordingSession.Dependencies(
            motion: SyntheticMotionSource(), location: FakeLocationSource(), altimeter: FakeAltimeter(),
            activity: FakeActivity(), audio: FakeAudio(), deviceStatus: FakeDeviceStatus(), uploadQueue: uploadQueue,
            deviceId: "DEV-1", appVersion: "1.0.0 (1) test",
            deviceInfo: .init(model: "iPhone15,2", name: "iPhone 14 Pro", iosVersion: "18.1"))
        var setup = SessionSetup()
        setup.mountPhotoJPEG = Data([0xff, 0xd8, 0xff, 0xd9])
        // Timing assertions are bounded by measured wall time, never by fixed tolerances: CI
        // simulators can be several times slower than a dev Mac (a ±0.6 s check failed there).
        let wallStart = ProcessInfo.processInfo.systemUptime
        let session = try RecordingSession(store: store, setup: setup, preflight: nil, deps: deps)

        // session.json exists from the start with endedAtUtc == null
        let metaURL = session.folder.appendingPathComponent("session.json")
        let initial = try SessionMetadata.load(from: metaURL)
        XCTAssertNil(initial.endedAtUtc)
        XCTAssertTrue(initial.syntheticSensors)
        XCTAssertEqual(initial.mount.photoFile, "mount.jpg")

        let started = expectation(description: "ran")
        DispatchQueue.main.async {
            session.start()
            session.addLabel(.syncTap)
            session.toggleSurface(.cobblestones)
            session.toggleSurface(.gravel)      // ends cobblestones, starts gravel
            session.toggleSegment(.winding)
            session.addLabel(.note, value: nil, note: "bump, then \"silence\"")
            started.fulfill()
        }
        wait(for: [started], timeout: ciTimeout)
        Thread.sleep(forTimeInterval: 3.2)

        // Health inputs while running: every motion stream is available and delivering
        // (rate thresholds depend on the machine's timer accuracy and are unit-tested in
        // HealthEvaluatorTests with exact inputs instead).
        let inputs = session.healthInputs(now: ProcessInfo.processInfo.systemUptime)
        for id in [StreamID.deviceMotion, .accel, .gyro, .mag] {
            let snap = try XCTUnwrap(inputs.streams[id])
            XCTAssertTrue(snap.available, id.rawValue)
            XCTAssertGreaterThan(snap.count, 0, id.rawValue)
        }
        XCTAssertNotNil(inputs.gpsLastFixUp)

        let stopped = expectation(description: "stopped")
        var finalMeta: SessionMetadata?
        DispatchQueue.main.async {
            finalMeta = session.stop()
            session.stop() // idempotent
            stopped.fulfill()
        }
        wait(for: [stopped], timeout: ciTimeout)

        let folder = session.folder
        let meta = try XCTUnwrap(finalMeta)
        XCTAssertNotNil(meta.endedAtUtc)
        XCTAssertEqual(try SessionMetadata.load(from: metaURL), meta)
        let wallEnd = ProcessInfo.processInfo.systemUptime
        let stats = try XCTUnwrap(meta.stats)
        XCTAssertGreaterThanOrEqual(stats.durationSec, 3.2 - 0.01, "at least the time we recorded for")
        XCTAssertLessThanOrEqual(stats.durationSec, wallEnd - wallStart + 0.01, "never longer than the test itself")
        XCTAssertEqual(stats.audioFiles, ["audio_000.m4a"])
        XCTAssertGreaterThan(stats.uploadBatchesCreated, 1)

        // Motion CSVs: ~100 Hz, monotonic t_up, t_utc_ms consistent with the clock anchors
        let clock = try readCSV(folder.appendingPathComponent("clock.csv"))
        XCTAssertEqual(clock.header, ["t_up", "t_utc_ms", "source"])
        XCTAssertEqual(clock.rows.first?[2], "start")
        XCTAssertEqual(clock.rows.last?[2], "stop")
        XCTAssertTrue(clock.rows.contains { $0[2] == "audio_start" })
        let anchorUp = Double(clock.rows[0][0])!, anchorMs = Double(clock.rows[0][1])!

        for file in ["device_motion.csv", "accel_raw.csv", "gyro_raw.csv", "mag_raw.csv"] {
            let csv = try readCSV(folder.appendingPathComponent(file))
            XCTAssertEqual(csv.header.count, csv.rows.first?.count, file)
            XCTAssertGreaterThan(csv.rows.count, 10, file)
            XCTAssertTrue(csv.rows.allSatisfy { $0.count == csv.header.count }, "\(file): every row complete")
            let t = csv.rows.map { Double($0[0])! }
            XCTAssertEqual(t, t.sorted(), "\(file) t_up must be monotonic")
            for row in csv.rows.prefix(50) {
                let up = Double(row[0])!, ms = Double(row[1])!
                XCTAssertEqual(ms, anchorMs + (up - anchorUp) * 1000, accuracy: 2, "\(file) t_utc_ms")
                XCTAssertEqual(row[0].split(separator: ".").last?.count, 6)
            }
            let stat = try XCTUnwrap(stats.streams[StreamID.allCases.first { $0.file.fileName == file }!.rawValue])
            XCTAssertEqual(stat.samples, Int64(csv.rows.count), file)
        }

        let dm = try readCSV(folder.appendingPathComponent("device_motion.csv"))
        XCTAssertEqual(dm.header.count, 18)
        // Live plot buffer saw exactly the samples written (capped at its 10 s capacity)
        XCTAssertEqual(session.live.snapshot().vertical.count, min(1000, dm.rows.count))

        let loc = try readCSV(folder.appendingPathComponent("location.csv"))
        XCTAssertGreaterThanOrEqual(loc.rows.count, 3)
        XCTAssertEqual(loc.rows.first?[2], "46.77131000") // 8 decimals
        XCTAssertEqual(loc.rows.first?[12], "0")

        XCTAssertGreaterThanOrEqual(try readCSV(folder.appendingPathComponent("altimeter.csv")).rows.count, 3)
        XCTAssertGreaterThanOrEqual(try readCSV(folder.appendingPathComponent("abs_altitude.csv")).rows.count, 3)
        XCTAssertGreaterThanOrEqual(try readCSV(folder.appendingPathComponent("heading.csv")).rows.count, 3)
        XCTAssertEqual(try readCSV(folder.appendingPathComponent("activity.csv")).rows.first?[5], "1") // automotive
        XCTAssertGreaterThan(try readCSV(folder.appendingPathComponent("audio_level.csv")).rows.count, 20)
        XCTAssertEqual(try readCSV(folder.appendingPathComponent("audio_segments.csv")).rows.first?[2], "start")
        XCTAssertGreaterThanOrEqual(try readCSV(folder.appendingPathComponent("device.csv")).rows.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("mount.jpg").path))

        // Labels in order, toggles auto-closed at stop, free text escaped
        let labelsText = try String(contentsOf: folder.appendingPathComponent("labels.csv"), encoding: .utf8)
        let types = labelsText.split(separator: "\n").dropFirst().map { line -> String in
            String(line.split(separator: ",", omittingEmptySubsequences: false)[2])
        }
        XCTAssertEqual(types, ["sync_tap", "surface_start", "surface_end", "surface_start", "segment_start", "note",
                               "surface_end", "segment_end"])
        XCTAssertTrue(labelsText.contains(",note,,\"bump, then \"\"silence\"\"\"\n"))
        XCTAssertTrue(labelsText.contains(",surface_end,gravel,auto at stop\n"))
        XCTAssertEqual(stats.labelsCount, 8)

        // Upload queue, in send order: Start metadata, batches 0..n-1, Stop metadata with batchCount = n (§6.1)
        let all = uploadQueue.pendingFiles()
        let kinds = all.compactMap { UploadQueue.parseItem(fileName: $0.lastPathComponent)?.item }
        XCTAssertEqual(kinds.first, .sessionMeta(phase: .start), "Start copy is sent before batch 0")
        XCTAssertEqual(kinds.last, .sessionMeta(phase: .stop), "Stop copy is sent after the last batch")
        let files = all.filter { UploadQueue.parse(fileName: $0.lastPathComponent) != nil }
        XCTAssertEqual(files.count, stats.uploadBatchesCreated)
        let stopMeta = try XCTUnwrap(JSONSerialization.jsonObject(with: Gzip.decompress(Data(contentsOf: all.last!))) as? [String: Any])
        XCTAssertEqual(stopMeta["batchCount"] as? Int, files.count)
        XCTAssertEqual(stopMeta["sessionId"] as? String, session.id.uuidString)
        XCTAssertNotNil(stopMeta["endedAtUtc"] as? String)
        let startMeta = try XCTUnwrap(JSONSerialization.jsonObject(with: Gzip.decompress(Data(contentsOf: all.first!))) as? [String: Any])
        XCTAssertTrue(startMeta["endedAtUtc"] is NSNull)
        XCTAssertNil(startMeta["batchCount"])
        var seqs: [Int] = []
        var totalDM = 0
        for f in files {
            let json = try JSONSerialization.jsonObject(with: Gzip.decompress(Data(contentsOf: f))) as! [String: Any]
            XCTAssertEqual(json["sessionId"] as? String, session.id.uuidString)
            seqs.append(json["batchSeq"] as! Int)
            totalDM += ((json["deviceMotion"] as! [String: [Double]])["t"]!).count
        }
        XCTAssertEqual(seqs, Array(0..<files.count))
        XCTAssertEqual(totalDM, dm.rows.count, "every device-motion sample is in exactly one batch")

        // app_log contains lifecycle entries
        let log = try String(contentsOf: folder.appendingPathComponent("app_log.txt"), encoding: .utf8)
        XCTAssertTrue(log.contains("recording started"))
        XCTAssertTrue(log.contains("recording stopped"))

        // Offline analysis of the folder agrees with the live stats
        let analysis = SessionAnalyzer.analyze(folder: folder)
        XCTAssertEqual(analysis.streams[.accel]?.count, stats.streams["accel"]?.samples)
    }

    func testAudioFailureIsReportedAsProblem() throws {
        let root = try makeTempDir()
        let audio = FakeAudio()
        audio.failToStart = true
        let deps = RecordingSession.Dependencies(
            motion: SyntheticMotionSource(), location: nil, altimeter: nil, activity: nil, audio: audio,
            deviceStatus: FakeDeviceStatus(), uploadQueue: nil, deviceId: "D", appVersion: "t",
            deviceInfo: .init(model: "x", name: "x", iosVersion: "x"))
        let session = try RecordingSession(store: SessionStore(root: root), setup: SessionSetup(), preflight: nil, deps: deps)
        let e = expectation(description: "start")
        DispatchQueue.main.async { session.start(); e.fulfill() }
        wait(for: [e], timeout: ciTimeout)
        Thread.sleep(forTimeInterval: 0.5)
        let issues = HealthEvaluator.evaluate(session.healthInputs(now: ProcessInfo.processInfo.systemUptime))
        XCTAssertTrue(issues.contains { $0.key == "audio.off" && $0.level == .problem })
        let e2 = expectation(description: "stop")
        DispatchQueue.main.async { session.stop(); e2.fulfill() }
        wait(for: [e2], timeout: ciTimeout)
        let log = try String(contentsOf: session.folder.appendingPathComponent("app_log.txt"), encoding: .utf8)
        XCTAssertTrue(log.contains("[PROBLEM] audio recording FAILED to start"))
    }
}
