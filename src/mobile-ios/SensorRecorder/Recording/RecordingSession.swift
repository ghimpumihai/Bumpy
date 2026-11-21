import Foundation

/// Labels written to `labels.csv` (spec §3.7). Raw values are the CSV `type` column.
enum LabelType: String, Sendable {
    case pothole, speedBump = "speed_bump", phoneMoved = "phone_moved"
    case surfaceStart = "surface_start", surfaceEnd = "surface_end"
    case segmentStart = "segment_start", segmentEnd = "segment_end"
    case syncTap = "sync_tap", note
}

enum SurfaceKind: String, CaseIterable, Identifiable, Sendable {
    case cobblestones, roughAsphalt = "rough_asphalt", smoothAsphalt = "smooth_asphalt", gravel, tramRails = "tram_rails"
    var id: String { rawValue }
    var shortName: String {
        switch self {
        case .cobblestones: return "Cobble"
        case .roughAsphalt: return "Rough"
        case .smoothAsphalt: return "Smooth"
        case .gravel: return "Gravel"
        case .tramRails: return "Rails"
        }
    }
}

enum SegmentKind: String, CaseIterable, Identifiable, Sendable {
    case winding, roundabout, stopAndGo = "stop_and_go", highway, idle
    var id: String { rawValue }
    var shortName: String {
        switch self {
        case .winding: return "Winding"
        case .roundabout: return "Rndabout"
        case .stopAndGo: return "Stop&Go"
        case .highway: return "Highway"
        case .idle: return "Idle"
        }
    }
}

struct LoggedLabel: Equatable, Sendable {
    let type: LabelType
    let value: String?
    let note: String?
    let tUp: TimeInterval
    let date: Date
}

/// One recording: owns the session folder, all writers, sensor wiring and the periodic timers.
/// Thread-safety: sensor callbacks arrive on background queues; public methods may be called
/// from the main thread; all shared state is behind locks.
final class RecordingSession: @unchecked Sendable {
    struct Dependencies {
        var motion: MotionSource
        var location: LocationSource?
        var altimeter: AltimeterSource?
        var activity: ActivitySource?
        var deviceStatus: DeviceStatusSource
        var uploadQueue: UploadQueue?
        var clock: ClockSource = SystemClock()
        var deviceId: String
        var appVersion: String
        var deviceInfo: SessionMetadata.Device
        var timezone: String = TimeZone.current.identifier
    }

    struct LatestValues {
        var gps: LocationSample?
        var gpsFixUp: TimeInterval?
        var activity: ActivitySample?
        var altimeter: AltimeterSample?
        var device: DeviceStatus = .unknown
        var inBackground = false
        var returnedFromBackgroundUp: TimeInterval?
    }

    struct LabelState {
        var count = 0
        var activeSurface: SurfaceKind?
        var activeSegments: Set<SegmentKind> = []
    }

    let id: UUID
    let folder: URL
    let startDate: Date
    let startUp: TimeInterval
    let timeBase: TimeBase
    let writer: SessionWriter
    let monitors: [StreamID: StreamMonitor]
    let live = LiveSignals()
    let track = TrackBuffer()
    let accumulator: BatchAccumulator
    let isSynthetic: Bool

    private let deps: Dependencies
    private let metadataBox: Locked<SessionMetadata>
    private let latestBox = Locked(LatestValues())
    private let labelBox = Locked(LabelState())
    private let timerQueue = DispatchQueue(label: "sensorrecorder.session-timers", qos: .utility)
    private var timers: [DispatchSourceTimer] = []
    /// Window start of the next upload batch. Touched by the batch timer and by stop() (final
    /// batch), so it is locked rather than relying on stop()'s timer-cancel ordering.
    private let lastBatchEndUp: Locked<TimeInterval>
    /// Batches built while upload is ON but not queued yet (enqueue failed: disk full, encode error),
    /// oldest first. Retried at the next batch tick; touched by the batch timer and by stop().
    private let unqueuedBatches = Locked<[IngestBatch]>([])
    private let stateBox = Locked((started: false, stopped: false))
    /// Set after the final close; later labels are refused instead of silently vanishing.
    private let writersClosed = Locked(false)


    static let anchorInterval: TimeInterval = 10
    /// Cached GPS fixes older than this before the session start are not recorded.
    static let staleFixMargin: TimeInterval = 5
    /// The ingest function rejects bodies over 200 KB (02 §5); warn a little before that.
    static let maxBatchJSONBytes = 180 * 1024
    static let deviceInterval: TimeInterval = 5
    static let batchInterval: TimeInterval = 2
    /// Unqueued batches kept for a retry (30 s of windows); older ones are dropped from the live
    /// upload so memory stays bounded on a full disk (the session files still have the data).
    static let maxUnqueuedBatches = 15

    var metadata: SessionMetadata { metadataBox.current }
    var shortId: String { SessionStore.shortId(id) }
    var labels: LabelState { labelBox.current }
    var latest: LatestValues { latestBox.current }

    /// Creates the session folder, writers, `session.json` and the first clock anchor.
    init(store: SessionStore, setup: SessionSetup, preflight: SessionMetadata.Preflight?, deps: Dependencies,
         id: UUID = UUID()) throws {
        self.id = id
        self.deps = deps
        timeBase = TimeBase(clock: deps.clock)
        let anchor = timeBase.refreshAnchor()
        startUp = anchor.up
        lastBatchEndUp = Locked(anchor.up)
        startDate = Date(timeIntervalSince1970: anchor.utcMs / 1000)
        let folder = try store.makeSessionFolder(start: startDate, id: id)
        self.folder = folder
        do {
            writer = try SessionWriter(folder: folder, uptime: { deps.clock.uptime() })
        } catch {
            // Never leave a half-created folder behind (it would show as "unreadable" forever).
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
        isSynthetic = deps.motion.isSynthetic
        var m: [StreamID: StreamMonitor] = [:]
        for s in StreamID.allCases { m[s] = StreamMonitor(id: s) }
        monitors = m
        accumulator = BatchAccumulator(sessionId: id.uuidString, deviceId: deps.deviceId)

        var mount = setup.mount
        if let jpeg = setup.mountPhotoJPEG {
            do {
                try jpeg.write(to: folder.appendingPathComponent(SessionFileName.mountPhoto), options: .atomic)
                mount.photoFile = SessionFileName.mountPhoto
            } catch {
                mount.photoFile = nil
                appLogger.error("mount photo not saved: \(error.localizedDescription, privacy: .public)")
            }
        } else {
            mount.photoFile = nil
        }

        let meta = SessionMetadata(
            sessionId: id.uuidString, appVersion: deps.appVersion, device: deps.deviceInfo,
            timezone: deps.timezone, startedAtUtc: ISO8601.string(startDate), startUptimeSec: anchor.up,
            endedAtUtc: nil, vehicle: setup.vehicle, mount: mount, people: setup.people,
            conditions: setup.conditions,
            requestedRatesHz: SessionMetadata.requestedRates,
            recovered: false, recoveredAtUtc: nil, syntheticSensors: deps.motion.isSynthetic,
            folderName: folder.lastPathComponent, deviceId: deps.deviceId, preflight: preflight, stats: nil)
        metadataBox = Locked(meta)
        do {
            try meta.write(to: folder.appendingPathComponent(SessionFileName.metadata))
        } catch {
            writer.close()
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
        writeClockRow(anchor, source: "start")
        queueSessionMetadata(meta, phase: .start)
        writer.log(.info, "session \(id.uuidString) created: \(folder.lastPathComponent), app \(deps.appVersion), synthetic=\(deps.motion.isSynthetic)")
        writer.onWriteError = { [weak self] msg in
            self?.writer.log(.problem, msg)
        }
    }

    // MARK: - Start / stop

    /// Starts every sensor stream and the periodic timers. Call on the main thread.
    func start() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard stateBox.withLock({ s -> Bool in
            guard !s.started else { return false }
            s.started = true
            return true
        }) else { return }
        writer.start()
        startMotion()
        startLocation()
        startAltimeter()
        startActivity()
        startTimers()
        writer.log(.info, "recording started")
    }

    /// Stops everything, writes final stats into `session.json` and closes all files.
    /// Idempotent. Call on the main thread.
    @discardableResult
    func stop() -> SessionMetadata {
        dispatchPrecondition(condition: .onQueue(.main))
        let shouldStop = stateBox.withLock { s -> Bool in
            guard s.started, !s.stopped else { return false }
            s.stopped = true
            return true
        }
        guard shouldStop else { return metadata }

        timerQueue.sync {
            timers.forEach { $0.cancel() }
            timers.removeAll()
        }
        endAllToggles(note: "auto at stop")
        deps.motion.stop()
        deps.location?.stopRecording()
        deps.altimeter?.stop()
        deps.activity?.stop()

        makeBatch() // last partial window (and any batch that couldn't be queued earlier)
        let notQueued = unqueuedBatches.withLock { w -> Int in defer { w.removeAll() }; return w.count }
        if notQueued > 0 {
            // batchCount below counts only queued batches, so the backend doesn't wait for these.
            writer.log(.warn, "\(notQueued) upload batch window(s) could not be queued before Stop (the session files keep the data)")
        }
        let anchor = timeBase.refreshAnchor()
        writeClockRow(anchor, source: "stop")
        writer.log(.info, "recording stopped")
        writer.flushNow()

        var meta = metadataBox.current
        meta.endedAtUtc = ISO8601.string(Date(timeIntervalSince1970: anchor.utcMs / 1000))
        meta.stats = buildStats(endUp: anchor.up)
        metadataBox.withLock { $0 = meta }
        do {
            try meta.write(to: folder.appendingPathComponent(SessionFileName.metadata))
        } catch {
            writer.log(.error, "writing final session.json failed: \(error.localizedDescription)")
        }
        queueSessionMetadata(meta, phase: .stop, batchCount: accumulator.batchesCreated)
        writer.close()
        writersClosed.withLock { $0 = true }
        return meta
    }

    var isRunning: Bool { stateBox.withLock { $0.started && !$0.stopped } }

    // MARK: - Sensor wiring

    private func startMotion() {
        let avail = deps.motion.availability
        monitors[.deviceMotion]?.setAvailable(avail.deviceMotion)
        monitors[.accel]?.setAvailable(avail.accel)
        monitors[.gyro]?.setAvailable(avail.gyro)
        monitors[.mag]?.setAvailable(avail.mag)
        writer.log(.info, "motion availability: dm=\(avail.deviceMotion) accel=\(avail.accel) gyro=\(avail.gyro) mag=\(avail.mag)")

        let tb = timeBase, w = writer, mon = monitors, live = live, acc = accumulator
        var cb = MotionCallbacks()
        cb.deviceMotion = { s in
            let arrival = tb.uptimeNow()
            let ua = s.userAccel, g = s.gravity, rr = s.rotationRate, q = s.quaternion
            w.append(.deviceMotion, CSV.row([
                CSV.f6(s.t), CSV.ms(tb.utcMs(fromUptime: s.t)),
                CSV.f6(ua.x), CSV.f6(ua.y), CSV.f6(ua.z),
                CSV.f6(g.x), CSV.f6(g.y), CSV.f6(g.z),
                CSV.f6(rr.x), CSV.f6(rr.y), CSV.f6(rr.z),
                CSV.f6(q.w), CSV.f6(q.x), CSV.f6(q.y), CSV.f6(q.z),
                CSV.f6(s.roll), CSV.f6(s.pitch), CSV.f6(s.yaw),
            ]))
            mon[.deviceMotion]?.record(t: s.t, arrival: arrival)
            live.add(s)
            acc.add(s)
        }
        cb.accel = { s in
            let arrival = tb.uptimeNow()
            w.append(.accelRaw, Self.xyzRow(s, tb))
            mon[.accel]?.record(t: s.t, arrival: arrival)
            acc.addAccel(s)
        }
        cb.gyro = { s in
            let arrival = tb.uptimeNow()
            w.append(.gyroRaw, Self.xyzRow(s, tb))
            mon[.gyro]?.record(t: s.t, arrival: arrival)
            acc.addGyro(s)
        }
        cb.mag = { s in
            let arrival = tb.uptimeNow()
            w.append(.magRaw, Self.xyzRow(s, tb))
            mon[.mag]?.record(t: s.t, arrival: arrival)
            acc.addMag(s)
        }
        cb.error = { msg in w.log(.error, msg) }
        deps.motion.start(cb)
    }

    private static func xyzRow(_ s: Vec3Sample, _ tb: TimeBase) -> String {
        CSV.row([CSV.f6(s.t), CSV.ms(tb.utcMs(fromUptime: s.t)), CSV.f6(s.v.x), CSV.f6(s.v.y), CSV.f6(s.v.z)])
    }

    private func startLocation() {
        guard let loc = deps.location else {
            monitors[.gps]?.setAvailable(false)
            monitors[.heading]?.setAvailable(false)
            return
        }
        let tb = timeBase, w = writer, mon = monitors, acc = accumulator, latest = latestBox, track = track
        var cb = LocationCallbacks()
        let sessionStartUp = startUp
        cb.location = { s in
            let arrival = tb.uptimeNow()
            // Spec: location t_up is derived from the fix's UTC timestamp. Use the fix's *age* at
            // arrival (wall-clock difference measured now) rather than the possibly 10 s old clock
            // anchor, so a wall-clock step between anchors can't shift fixes by the step size.
            let ageSec = max(0, (tb.nowUtcMs() - s.utcMs) / 1000)
            let tUp = arrival - ageSec
            // CoreLocation first delivers its cached last fix, which can be minutes old and from
            // another place. Keep fixes up to `staleFixMargin` before start (real, just slightly
            // early); log and drop older ones.
            if tUp < sessionStartUp - Self.staleFixMargin {
                w.log(.info, String(format: "ignored cached GPS fix %.1f s older than session start", sessionStartUp - tUp))
                return
            }
            w.append(.location, CSV.row([
                CSV.f6(tUp), CSV.ms(s.utcMs),
                CSV.f8(s.lat), CSV.f8(s.lon), CSV.f6(s.alt), CSV.f6(s.ellAlt),
                CSV.f6(s.hAcc), CSV.f6(s.vAcc), CSV.f6(s.speed), CSV.f6(s.speedAcc),
                CSV.f6(s.course), CSV.f6(s.courseAcc), CSV.bool(s.isSimulated),
            ]))
            // Fixes from before the start (cached first delivery) are written but don't count for
            // GPS rate/gap stats or freshness; invalid fixes (hAcc < 0) never count as a fix.
            if tUp >= sessionStartUp {
                mon[.gps]?.record(t: tUp, arrival: arrival)
                if s.hAcc >= 0 { latest.withLock { $0.gps = s; $0.gpsFixUp = min(arrival, tUp) } }
            }
            track.add(s)
            acc.add(s)
        }
        cb.heading = { s in
            let arrival = tb.uptimeNow()
            let tUp = tb.uptime(fromUtcMs: s.utcMs)
            w.append(.heading, CSV.row([
                CSV.f6(tUp), CSV.ms(s.utcMs), CSV.f6(s.magneticHeading), CSV.f6(s.trueHeading),
                CSV.f6(s.accuracy), CSV.f6(s.raw.x), CSV.f6(s.raw.y), CSV.f6(s.raw.z),
            ]))
            mon[.heading]?.record(t: tUp, arrival: arrival)
            acc.add(s)
        }
        cb.error = { msg in w.log(.warn, msg) }
        loc.startRecording(cb)
    }

    private func startAltimeter() {
        guard let alt = deps.altimeter else {
            monitors[.barometer]?.setAvailable(false)
            monitors[.absAltitude]?.setAvailable(false)
            return
        }
        monitors[.barometer]?.setAvailable(alt.isRelativeAvailable)
        monitors[.absAltitude]?.setAvailable(alt.isAbsoluteAvailable)
        let tb = timeBase, w = writer, mon = monitors, acc = accumulator, latest = latestBox
        var cb = AltimeterCallbacks()
        cb.relative = { s in
            let arrival = tb.uptimeNow()
            w.append(.altimeter, CSV.row([CSV.f6(s.t), CSV.ms(tb.utcMs(fromUptime: s.t)),
                                          CSV.f6(s.relativeAltitudeM), CSV.f6(s.pressureKPa)]))
            mon[.barometer]?.record(t: s.t, arrival: arrival)
            latest.withLock { $0.altimeter = s }
            acc.add(s)
        }
        cb.absolute = { s in
            let arrival = tb.uptimeNow()
            w.append(.absAltitude, CSV.row([CSV.f6(s.t), CSV.ms(tb.utcMs(fromUptime: s.t)),
                                            CSV.f6(s.altitudeM), CSV.f6(s.accuracyM), CSV.f6(s.precisionM)]))
            mon[.absAltitude]?.record(t: s.t, arrival: arrival)
            acc.add(s)
        }
        cb.error = { msg in w.log(.warn, msg) }
        alt.start(cb)
    }

    private func startActivity() {
        guard let act = deps.activity, act.isAvailable else {
            monitors[.activity]?.setAvailable(false)
            return
        }
        let tb = timeBase, w = writer, mon = monitors, latest = latestBox, acc = accumulator
        act.start { s in
            let arrival = tb.uptimeNow()
            w.append(.activity, CSV.row([
                CSV.f6(s.t), CSV.ms(tb.utcMs(fromUptime: s.t)),
                CSV.bool(s.stationary), CSV.bool(s.walking), CSV.bool(s.running),
                CSV.bool(s.automotive), CSV.bool(s.cycling), CSV.bool(s.unknown),
                String(s.confidence), CSV.ms(s.startUtcMs),
            ]))
            mon[.activity]?.record(t: s.t, arrival: arrival)
            latest.withLock { $0.activity = s }
            acc.add(s)
        }
    }

    private func startTimers() {
        func make(_ interval: TimeInterval, fireNow: Bool, _ body: @escaping () -> Void) {
            let t = DispatchSource.makeTimerSource(queue: timerQueue)
            t.schedule(deadline: fireNow ? .now() : .now() + interval, repeating: interval, leeway: .milliseconds(20))
            t.setEventHandler(handler: body)
            timers.append(t)
            t.resume()
        }
        timerQueue.sync {
            make(Self.anchorInterval, fireNow: false) { [weak self] in
                guard let self else { return }
                self.writeClockRow(self.timeBase.refreshAnchor(), source: "periodic")
            }
            make(Self.deviceInterval, fireNow: true) { [weak self] in self?.pollDevice() }
            make(Self.batchInterval, fireNow: false) { [weak self] in self?.makeBatch() }
        }
    }

    private func writeClockRow(_ a: ClockAnchor, source: String) {
        writer.append(.clock, CSV.row([CSV.f6(a.up), CSV.ms(a.utcMs), source]))
    }

    private func pollDevice() {
        let s = deps.deviceStatus.currentStatus()
        let now = timeBase.uptimeNow()
        writer.append(.device, CSV.row([
            CSV.f6(now), CSV.ms(timeBase.utcMs(fromUptime: now)),
            s.batteryLevel < 0 ? "-1" : CSV.f6(Double(s.batteryLevel)), // §4: 6 decimals everywhere
            s.batteryState, s.thermal.rawValue, CSV.bool(s.lowPowerMode),
            String(s.freeDiskBytes), s.networkStatus, s.networkType,
        ]))
        monitors[.device]?.record(t: now, arrival: now)
        let previous = latestBox.withLock { l -> DeviceStatus in
            let p = l.device
            l.device = s
            return p
        }
        if previous != .unknown {
            if previous.thermal != s.thermal { writer.log(.warn, "thermal state \(previous.thermal.rawValue) -> \(s.thermal.rawValue)") }
            if previous.lowPowerMode != s.lowPowerMode { writer.log(s.lowPowerMode ? .problem : .info, "low power mode \(s.lowPowerMode ? "ON" : "off")") }
            if previous.batteryState != s.batteryState { writer.log(.info, "battery state \(previous.batteryState) -> \(s.batteryState)") }
            if previous.networkStatus != s.networkStatus { writer.log(.info, "network \(previous.networkStatus) -> \(s.networkStatus) (\(s.networkType))") }
        }
    }

    private func makeBatch() {
        let end = timeBase.uptimeNow()
        let start = lastBatchEndUp.withLock { v -> TimeInterval in
            let s = v
            v = end
            return s
        }
        // Upload OFF: drop the window (memory stays bounded; the session folder keeps everything) without
        // consuming a batchSeq. Upload ON: build, check size, queue.
        guard let q = deps.uploadQueue, q.isEnabled else {
            accumulator.discard()
            unqueuedBatches.withLock { $0.removeAll() }
            return
        }
        let batch = accumulator.drain(t0Up: start, t0UtcMs: timeBase.utcMs(fromUptime: start), device: latestBox.current.device)
        var waiting = unqueuedBatches.withLock { w -> [IngestBatch] in
            w.append(batch)
            defer { w.removeAll() }
            return w
        }
        if waiting.count > Self.maxUnqueuedBatches {
            let dropped = waiting.count - Self.maxUnqueuedBatches
            waiting.removeFirst(dropped)
            writer.log(.warn, "\(dropped) upload batch window(s) could not be queued and were dropped from the live upload (the session files keep the data)")
        }
        // Oldest first; each batch gets its batchSeq only when it is actually queued (no holes).
        let createdUtcMs = Int64(timeBase.utcMs(fromUptime: end))
        while var b = waiting.first {
            b.batchSeq = accumulator.nextSeq
            do {
                let json = try b.jsonData()
                if json.count > Self.maxBatchJSONBytes {
                    // The ingest function rejects bodies > 200 KB (02 §5): the data is safe on disk; say so.
                    writer.log(.warn, "upload batch \(b.batchSeq) is \(json.count / 1024) KB (> \(Self.maxBatchJSONBytes / 1024) KB): the backend may reject it")
                }
                try q.enqueue(gzippedBody: Gzip.compress(json), sessionId: b.sessionId, seq: b.batchSeq, createdUtcMs: createdUtcMs)
                accumulator.markQueued(seq: b.batchSeq)
                waiting.removeFirst()
            } catch {
                writer.log(.warn, "could not queue upload batch \(b.batchSeq) (\(waiting.count) window(s) waiting, retried in \(Int(Self.batchInterval)) s): \(error.localizedDescription)")
                break
            }
        }
        unqueuedBatches.withLock { $0 = waiting + $0 }
    }

    /// §6.1 body: session.json, plus `batchCount` in the Stop copy, plus `source: "live"` (the
    /// replay tool rewrites it, 02 §5). The rater's name is personal data and stays on the phone:
    /// it is removed from the cloud copy (the local session.json keeps it).
    static func sessionMetadataBody(_ meta: SessionMetadata, batchCount: Int?) throws -> Data {
        guard var obj = try JSONSerialization.jsonObject(with: meta.jsonData()) as? [String: Any] else {
            throw CocoaError(.coderInvalidValue)
        }
        if var people = obj["people"] as? [String: Any] {
            people.removeValue(forKey: "raterName")
            obj["people"] = people
        }
        obj["source"] = "live"
        if let batchCount { obj["batchCount"] = batchCount }
        return try JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys, .withoutEscapingSlashes])
    }

    /// Spec §6.1: the current session.json goes through the same queue as the batches (Start copy
    /// before batch 0, Stop copy — with `batchCount` — after the last batch). Only while upload is ON.
    private func queueSessionMetadata(_ meta: SessionMetadata, phase: UploadQueue.MetaPhase, batchCount: Int? = nil) {
        guard let q = deps.uploadQueue, q.isEnabled else { return }
        do {
            let json = try Self.sessionMetadataBody(meta, batchCount: batchCount)
            try q.enqueueSessionMetadata(json: json, sessionId: id.uuidString, phase: phase,
                                         createdUtcMs: Int64(timeBase.utcMs(fromUptime: timeBase.uptimeNow())))
        } catch {
            writer.log(.warn, "could not queue session metadata (\(phase.rawValue)): \(error.localizedDescription)")
        }
    }

    // MARK: - Labels

    /// One line per label: newlines in free text would break line-based readers and crash repair.
    static func sanitize(_ s: String?) -> String? {
        guard let s else { return nil }
        let flat = s.replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
        let trimmed = flat.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }

    @discardableResult
    func addLabel(_ type: LabelType, value rawValue: String? = nil, note rawNote: String? = nil) -> LoggedLabel {
        let value = Self.sanitize(rawValue), note = Self.sanitize(rawNote)
        let t = timeBase.uptimeNow()
        let label = LoggedLabel(type: type, value: value, note: note, tUp: t, date: timeBase.date(fromUptime: t))
        guard !writersClosed.current else {
            appLogger.error("label \(type.rawValue, privacy: .public) after session close was not recorded")
            return label
        }
        writer.append(.labels, CSV.row([CSV.f6(t), CSV.ms(timeBase.utcMs(fromUptime: t)), type.rawValue,
                                        CSV.escape(value), CSV.escape(note)]))
        accumulator.addLabel(t: t, type: type.rawValue, value: value, note: note)
        labelBox.withLock { $0.count += 1 }
        return label
    }

    /// Surfaces are mutually exclusive: starting one ends the previous.
    @discardableResult
    func toggleSurface(_ kind: SurfaceKind) -> LoggedLabel {
        let current = labelBox.current.activeSurface
        if current == kind {
            labelBox.withLock { $0.activeSurface = nil }
            return addLabel(.surfaceEnd, value: kind.rawValue)
        }
        if let current {
            addLabel(.surfaceEnd, value: current.rawValue)
        }
        labelBox.withLock { $0.activeSurface = kind }
        return addLabel(.surfaceStart, value: kind.rawValue)
    }

    /// Driving segments are independent toggles (e.g. winding + stop&go).
    @discardableResult
    func toggleSegment(_ kind: SegmentKind) -> LoggedLabel {
        let active = labelBox.current.activeSegments.contains(kind)
        labelBox.withLock { s in
            if active { s.activeSegments.remove(kind) } else { s.activeSegments.insert(kind) }
        }
        return addLabel(active ? .segmentEnd : .segmentStart, value: kind.rawValue)
    }

    private func endAllToggles(note: String) {
        let s = labelBox.current
        if let surface = s.activeSurface { addLabel(.surfaceEnd, value: surface.rawValue, note: note) }
        for seg in s.activeSegments.sorted(by: { $0.rawValue < $1.rawValue }) {
            addLabel(.segmentEnd, value: seg.rawValue, note: note)
        }
        labelBox.withLock { $0.activeSurface = nil; $0.activeSegments = [] }
    }

    // MARK: - Lifecycle

    /// Records real background/foreground transitions only. The scene also turns inactive → active
    /// without ever being backgrounded (Control Center, Notification Center, system alerts, call
    /// banners): those must not log a WARN, add a `foreground` clock row or show the banner.
    func noteLifecycle(background: Bool) {
        guard isRunning else { return }
        let now = timeBase.uptimeNow()
        let changed = latestBox.withLock { l -> Bool in
            guard l.inBackground != background else { return false }
            l.inBackground = background
            if !background { l.returnedFromBackgroundUp = now }
            return true
        }
        guard changed else { return }
        writer.log(.warn, background ? "app went to background (recording continues)" : "app returned to foreground")
        writeClockRow(timeBase.refreshAnchor(), source: background ? "background" : "foreground")
    }

    func log(_ level: LogLevel, _ message: String) { writer.log(level, message) }

    // MARK: - Health

    func healthInputs(now: TimeInterval) -> HealthInputs {
        var i = HealthInputs(now: now, recordingStartUp: startUp)
        for (id, m) in monitors { i.streams[id] = m.snapshot(now: now) }
        let l = latestBox.current
        i.gpsLastFixUp = l.gpsFixUp
        i.gpsHorizontalAccuracy = l.gps?.hAcc
        i.locationDegraded = deps.location?.degradedReason
        let we = writer.writeErrors
        i.lastWriteErrorUp = we.lastAtUp
        i.lastWriteError = we.last
        let d = deps.deviceStatus.currentStatus()
        i.freeDiskBytes = d.freeDiskBytes
        i.thermal = d.thermal
        i.lowPowerMode = d.lowPowerMode
        i.batteryLevel = d.batteryLevel
        i.batteryCharging = d.isCharging
        i.inBackground = l.inBackground
        i.returnedFromBackgroundUp = l.returnedFromBackgroundUp
        if let q = deps.uploadQueue {
            let st = q.status
            i.uploadEnabled = st.enabled
            i.uploadQueueCount = st.queueCount
            i.uploadLastSuccessUp = st.lastSuccessUp
            i.uploadEnabledSinceUp = st.enabledSinceUp.map { max($0, startUp) }
            i.uploadLastError = st.lastError
        }
        return i
    }

    var uploadStatus: UploadStatus? { deps.uploadQueue?.status }
    var deviceStatus: DeviceStatus { deps.deviceStatus.currentStatus() }

    // MARK: - Stats

    private func buildStats(endUp: TimeInterval) -> SessionMetadata.Stats {
        let fm = FileManager.default
        var sizes: [String: Int64] = [:]
        var total: Int64 = 0
        if let files = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) {
            for f in files {
                let s = fm.fileSize(f)
                sizes[f.lastPathComponent] = s
                total += s
            }
        }
        var streams: [String: SessionMetadata.StreamStats] = [:]
        for (id, m) in monitors {
            let t = m.tracker
            let snap = m.snapshot(now: endUp)
            guard snap.available || t.count > 0 else { continue }
            streams[id.rawValue] = .init(samples: t.count, meanRateHz: t.meanRateHz, maxGapSec: t.maxGap,
                                         gapsOver1s: t.gapsOver1s, droppedEstimate: t.droppedEstimate,
                                         fileBytes: sizes[id.file.fileName])
        }
        let l = labelBox.current
        return .init(durationSec: endUp - startUp, streams: streams, labelsCount: l.count,
                     fileSizes: sizes, totalBytes: total,
                     writeErrors: writer.writeErrors.count, uploadBatchesCreated: accumulator.batchesCreated)
    }
}
