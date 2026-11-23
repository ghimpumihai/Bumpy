package com.chuds.sensorrecorder.recording

import com.chuds.sensorrecorder.core.ClockAnchor
import com.chuds.sensorrecorder.core.ClockSource
import com.chuds.sensorrecorder.core.Csv
import com.chuds.sensorrecorder.core.HealthInputs
import com.chuds.sensorrecorder.core.ISO8601
import com.chuds.sensorrecorder.core.Json
import com.chuds.sensorrecorder.core.Locked
import com.chuds.sensorrecorder.core.LogLevel
import com.chuds.sensorrecorder.core.SessionFileName
import com.chuds.sensorrecorder.core.SessionMetadata
import com.chuds.sensorrecorder.core.SessionSetup
import com.chuds.sensorrecorder.core.SessionStore
import com.chuds.sensorrecorder.core.SessionWriter
import com.chuds.sensorrecorder.core.StreamFile
import com.chuds.sensorrecorder.core.StreamId
import com.chuds.sensorrecorder.core.StreamMonitor
import com.chuds.sensorrecorder.core.TimeBase
import com.chuds.sensorrecorder.core.text
import com.chuds.sensorrecorder.sensors.AltimeterSource
import com.chuds.sensorrecorder.sensors.DeviceStatus
import com.chuds.sensorrecorder.sensors.DeviceStatusSource
import com.chuds.sensorrecorder.sensors.LocationCallbacks
import com.chuds.sensorrecorder.sensors.LocationSample
import com.chuds.sensorrecorder.sensors.LocationSource
import com.chuds.sensorrecorder.sensors.MotionCallbacks
import com.chuds.sensorrecorder.sensors.MotionSource
import com.chuds.sensorrecorder.sensors.Vec3Sample
import com.chuds.sensorrecorder.upload.BatchAccumulator
import com.chuds.sensorrecorder.upload.Gzip
import com.chuds.sensorrecorder.upload.IngestBatch
import com.chuds.sensorrecorder.upload.UploadQueue
import com.chuds.sensorrecorder.upload.UploadStatus
import java.io.File
import java.io.IOException
import java.util.Locale
import java.util.TimeZone
import java.util.UUID
import java.util.concurrent.ScheduledThreadPoolExecutor
import java.util.concurrent.TimeUnit
import kotlin.math.max
import kotlin.math.min

/**
 * One recording: owns the session folder, all writers, sensor wiring and the periodic timers.
 * Sensor callbacks arrive on background threads; public methods are called from the main thread; all
 * shared state is behind locks.
 *
 * The constructor creates the session folder, writers, `session.json` and the first clock anchor.
 */
class RecordingSession(
    store: SessionStore,
    setup: SessionSetup,
    preflight: SessionMetadata.Preflight?,
    private val deps: Dependencies,
    val id: UUID = UUID.randomUUID(),
    autoStart: SessionMetadata.AutoStart? = null,
) {
    class Dependencies(
        val motion: MotionSource,
        val location: LocationSource?,
        val altimeter: AltimeterSource?,
        val deviceStatus: DeviceStatusSource,
        val uploadQueue: UploadQueue?,
        val clock: ClockSource,
        val deviceId: String,
        val appVersion: String,
        val deviceInfo: SessionMetadata.Device,
        val timezone: String = TimeZone.getDefault().id,
    )

    data class LatestValues(
        val gps: LocationSample? = null,
        val gpsFixUp: Double? = null,
        val device: DeviceStatus = DeviceStatus.UNKNOWN,
        val inBackground: Boolean = false,
        val returnedFromBackgroundUp: Double? = null,
    )

    /** Upper case, as the iOS app writes it. */
    val sessionId: String = id.toString().uppercase(Locale.ROOT)
    val timeBase = TimeBase(deps.clock)
    val startUp: Double
    val folder: File
    val writer: SessionWriter
    val track = TrackBuffer()
    private val monitors = StreamId.entries.associateWith { StreamMonitor(it) }
    private val accumulator = BatchAccumulator(sessionId, deps.deviceId)
    private val metadataBox: Locked<SessionMetadata>
    private val latestBox = Locked(LatestValues())
    private val timers = ScheduledThreadPoolExecutor(1) { r -> Thread(r, "sensorrecorder.session-timers").apply { isDaemon = true } }

    /** Window start of the next upload batch. Touched by the batch timer and by [stop] (final batch). */
    private val lastBatchEndUp: Locked<Double>

    /**
     * Batches built while upload is ON but not queued yet (enqueue failed: disk full), oldest first.
     * Retried at the next batch tick; touched by the batch timer and, after it ended, by [stop].
     */
    private val unqueuedBatches = ArrayList<IngestBatch>()

    /** Windows dropped from the live upload (`Stats.uploadWindowsNotQueued`); the session files keep them. */
    private var windowsNotQueued = 0

    private val stateLock = Any()
    private var started = false
    private var stopped = false

    val metadata: SessionMetadata get() = metadataBox.current
    val latest: LatestValues get() = latestBox.current
    val isRunning: Boolean get() = synchronized(stateLock) { started && !stopped }

    init {
        val anchor = timeBase.refreshAnchor()
        startUp = anchor.up
        lastBatchEndUp = Locked(anchor.up)
        folder = store.makeSessionFolder(anchor.utcMs, id)
        try {
            writer = SessionWriter(folder, uptime = { deps.clock.uptime() })
        } catch (e: IOException) {
            // Never leave a half-created folder behind (it would show as "unreadable" forever).
            folder.deleteRecursively()
            throw e
        }
        val meta = SessionMetadata(
            sessionId = sessionId, appVersion = deps.appVersion, device = deps.deviceInfo, timezone = deps.timezone,
            startedAtUtc = ISO8601.string(anchor.utcMs), startUptimeSec = anchor.up, endedAtUtc = null,
            vehicle = setup.vehicle, mount = setup.mount.copy(photoFile = null), people = setup.people,
            conditions = setup.conditions, syntheticSensors = deps.motion.isSynthetic, folderName = folder.name,
            deviceId = deps.deviceId, preflight = preflight, autoStart = autoStart,
        )
        metadataBox = Locked(meta)
        try {
            meta.write(File(folder, SessionFileName.METADATA))
        } catch (e: IOException) {
            writer.close()
            folder.deleteRecursively()
            throw e
        }
        writeClockRow(anchor, "start")
        queueSessionMetadata(meta, UploadQueue.MetaPhase.START)
        writer.log(LogLevel.INFO, "session $sessionId created: ${folder.name}, app ${deps.appVersion}, synthetic=${deps.motion.isSynthetic}")
        writer.onWriteError = { writer.log(LogLevel.PROBLEM, it) }
    }

    // Start / stop

    /** Starts every sensor stream and the periodic timers. Call on the main thread. */
    fun start() {
        synchronized(stateLock) {
            if (started) return
            started = true
        }
        writer.start()
        startMotion()
        startLocation()
        startAltimeter()
        // No Play Services (activity recognition), no fused absolute altitude: header-only files.
        monitors.getValue(StreamId.ACTIVITY).setAvailable(false)
        monitors.getValue(StreamId.ABS_ALTITUDE).setAvailable(false)
        timers.scheduleAtFixedRate(guarded("anchor") { writeClockRow(timeBase.refreshAnchor(), "periodic") }, ANCHOR_INTERVAL_S, ANCHOR_INTERVAL_S, TimeUnit.SECONDS)
        timers.scheduleAtFixedRate(guarded("device") { pollDevice() }, 0, DEVICE_INTERVAL_S, TimeUnit.SECONDS)
        timers.scheduleAtFixedRate(guarded("batch") { makeBatch() }, BATCH_INTERVAL_S, BATCH_INTERVAL_S, TimeUnit.SECONDS)
        writer.log(LogLevel.INFO, "recording started")
    }

    /** An exception that escapes a scheduled task silently cancels it; log it and keep ticking instead. */
    private fun guarded(name: String, body: () -> Unit) = Runnable {
        try {
            body()
        } catch (e: Throwable) {
            writer.log(LogLevel.ERROR, "$name timer: ${e.text}")
        }
    }

    /**
     * Stops everything, writes final stats into `session.json` and closes all files. Idempotent. Call on
     * the main thread.
     */
    fun stop(): SessionMetadata {
        synchronized(stateLock) {
            if (!started || stopped) return metadata
            stopped = true
        }
        timers.shutdown()
        timers.awaitTermination(10, TimeUnit.SECONDS)
        deps.motion.stop()
        deps.location?.stopRecording()
        deps.altimeter?.stop()

        try {
            makeBatch() // last partial window (and any batch that couldn't be queued earlier)
        } catch (e: Throwable) {
            writer.log(LogLevel.ERROR, "final batch: ${e.text}")
        }
        val notQueued = synchronized(unqueuedBatches) {
            val n = unqueuedBatches.size
            unqueuedBatches.clear()
            windowsNotQueued += n
            n
        }
        if (notQueued > 0) {
            // batchCount below counts only queued batches, so the backend doesn't wait for these.
            writer.log(LogLevel.WARN, "$notQueued upload batch window(s) could not be queued before Stop (the session files keep the data)")
        }
        val anchor = timeBase.refreshAnchor()
        writeClockRow(anchor, "stop")
        writer.log(LogLevel.INFO, "recording stopped")
        writer.flushNow()

        val meta = metadataBox.update { it.copy(endedAtUtc = ISO8601.string(anchor.utcMs), stats = buildStats(anchor.up)) }
        try {
            meta.write(File(folder, SessionFileName.METADATA))
        } catch (e: IOException) {
            writer.log(LogLevel.ERROR, "writing final session.json failed: ${e.text}")
        }
        queueSessionMetadata(meta, UploadQueue.MetaPhase.STOP, batchCount = accumulator.nextSeq)
        writer.close()
        return meta
    }

    /**
     * A Cancel of an automatic trip (D59). Call before [stop], which writes it into `session.json` and the
     * Stop copy.
     */
    fun markAutoCancelled(atUtc: String) {
        metadataBox.update { m -> m.copy(autoStart = m.autoStart?.copy(cancelledAtUtc = atUtc)) }
        writer.log(LogLevel.INFO, "automatic trip cancelled")
    }

    // Sensor wiring

    private fun monitor(id: StreamId) = monitors.getValue(id)

    private fun startMotion() {
        val a = deps.motion.availability
        monitor(StreamId.DEVICE_MOTION).setAvailable(a.deviceMotion)
        monitor(StreamId.ACCEL).setAvailable(a.accel)
        monitor(StreamId.GYRO).setAvailable(a.gyro)
        monitor(StreamId.MAG).setAvailable(a.mag)
        writer.log(LogLevel.INFO, "motion availability: dm=${a.deviceMotion} accel=${a.accel} gyro=${a.gyro} mag=${a.mag}")

        deps.motion.start(
            MotionCallbacks(
                deviceMotion = { s ->
                    val arrival = timeBase.uptimeNow()
                    val ua = s.userAccel
                    val g = s.gravity
                    val rr = s.rotationRate
                    val q = s.quaternion
                    writer.append(
                        StreamFile.DEVICE_MOTION,
                        Csv.row(
                            Csv.f6(s.t), Csv.ms(timeBase.utcMs(s.t)),
                            Csv.f6(ua.x), Csv.f6(ua.y), Csv.f6(ua.z), Csv.f6(g.x), Csv.f6(g.y), Csv.f6(g.z),
                            Csv.f6(rr.x), Csv.f6(rr.y), Csv.f6(rr.z),
                            Csv.f6(q.w), Csv.f6(q.x), Csv.f6(q.y), Csv.f6(q.z),
                            Csv.f6(s.roll), Csv.f6(s.pitch), Csv.f6(s.yaw),
                        ),
                    )
                    monitor(StreamId.DEVICE_MOTION).record(s.t, arrival)
                    accumulator.add(s)
                },
                accel = { s ->
                    xyz(s, StreamFile.ACCEL_RAW, StreamId.ACCEL)
                    accumulator.addAccel(s)
                },
                gyro = { s ->
                    xyz(s, StreamFile.GYRO_RAW, StreamId.GYRO)
                    accumulator.addGyro(s)
                },
                mag = { s ->
                    xyz(s, StreamFile.MAG_RAW, StreamId.MAG)
                    accumulator.addMag(s)
                },
                error = { writer.log(LogLevel.ERROR, it) },
            ),
        )
    }

    private fun xyz(s: Vec3Sample, file: StreamFile, id: StreamId) {
        val arrival = timeBase.uptimeNow()
        writer.append(file, Csv.row(Csv.f6(s.t), Csv.ms(timeBase.utcMs(s.t)), Csv.f6(s.v.x), Csv.f6(s.v.y), Csv.f6(s.v.z)))
        monitor(id).record(s.t, arrival)
    }

    private fun startLocation() {
        val loc = deps.location
        if (loc == null) {
            monitor(StreamId.GPS).setAvailable(false)
            monitor(StreamId.HEADING).setAvailable(false)
            return
        }
        loc.startRecording(
            LocationCallbacks(
                location = ::onLocation,
                heading = { s ->
                    val arrival = timeBase.uptimeNow()
                    val tUp = timeBase.uptime(s.utcMs)
                    writer.append(
                        StreamFile.HEADING,
                        Csv.row(
                            Csv.f6(tUp), Csv.ms(s.utcMs), Csv.f6(s.magneticHeading), Csv.f6(s.trueHeading),
                            Csv.f6(s.accuracy), Csv.f6(s.raw.x), Csv.f6(s.raw.y), Csv.f6(s.raw.z),
                        ),
                    )
                    monitor(StreamId.HEADING).record(tUp, arrival)
                    accumulator.add(s)
                },
                error = { writer.log(LogLevel.WARN, it) },
            ),
        )
    }

    private fun onLocation(s: LocationSample) {
        val arrival = timeBase.uptimeNow()
        // t_up from the fix's *age* at arrival (wall-clock difference measured now) rather than the possibly
        // 10 s old clock anchor, so a wall-clock step between anchors can't shift fixes by the step size.
        val tUp = arrival - max(0.0, (timeBase.nowUtcMs() - s.utcMs) / 1000)
        // A cached fix can be minutes old and from another place. Keep fixes up to STALE_FIX_MARGIN before
        // the start (real, just slightly early); log and drop older ones.
        if (tUp < startUp - STALE_FIX_MARGIN_S) {
            writer.log(LogLevel.INFO, String.format(Locale.US, "ignored cached GPS fix %.1f s older than session start", startUp - tUp))
            return
        }
        writer.append(
            StreamFile.LOCATION,
            Csv.row(
                Csv.f6(tUp), Csv.ms(s.utcMs), Csv.f8(s.lat), Csv.f8(s.lon), Csv.f6(s.alt), Csv.f6(s.ellAlt),
                Csv.f6(s.hAcc), Csv.f6(s.vAcc), Csv.f6(s.speed), Csv.f6(s.speedAcc),
                Csv.f6(s.course), Csv.f6(s.courseAcc), Csv.bool(s.isSimulated),
            ),
        )
        // Fixes from before the start are written but don't count for GPS rate/gap stats or freshness;
        // invalid fixes (hAcc < 0) never count as a fix.
        if (tUp >= startUp) {
            monitor(StreamId.GPS).record(tUp, arrival)
            if (s.hAcc >= 0) latestBox.update { it.copy(gps = s, gpsFixUp = min(arrival, tUp)) }
        }
        track.add(s)
        accumulator.add(s)
    }

    private fun startAltimeter() {
        val alt = deps.altimeter
        monitor(StreamId.BAROMETER).setAvailable(alt?.isAvailable == true)
        if (alt == null || !alt.isAvailable) return
        alt.start { s ->
            val arrival = timeBase.uptimeNow()
            writer.append(
                StreamFile.ALTIMETER,
                Csv.row(Csv.f6(s.t), Csv.ms(timeBase.utcMs(s.t)), Csv.f6(s.relativeAltitudeM), Csv.f6(s.pressureKPa)),
            )
            monitor(StreamId.BAROMETER).record(s.t, arrival)
            accumulator.add(s)
        }
    }

    private fun writeClockRow(a: ClockAnchor, source: String) {
        writer.append(StreamFile.CLOCK, Csv.row(Csv.f6(a.up), Csv.ms(a.utcMs), source))
    }

    private fun pollDevice() {
        val s = deps.deviceStatus.currentStatus()
        val now = timeBase.uptimeNow()
        writer.append(
            StreamFile.DEVICE,
            Csv.row(
                Csv.f6(now), Csv.ms(timeBase.utcMs(now)),
                if (s.batteryLevel < 0) "-1" else Csv.f6(s.batteryLevel.toDouble()),
                s.batteryState, s.thermal.id, Csv.bool(s.lowPowerMode),
                s.freeDiskBytes.toString(), s.networkStatus, s.networkType,
            ),
        )
        monitor(StreamId.DEVICE).record(now, now)
        val p = latestBox.current.device
        latestBox.update { it.copy(device = s) }
        if (p == DeviceStatus.UNKNOWN) return
        if (p.thermal != s.thermal) writer.log(LogLevel.WARN, "thermal state ${p.thermal.id} -> ${s.thermal.id}")
        if (p.lowPowerMode != s.lowPowerMode) {
            writer.log(if (s.lowPowerMode) LogLevel.PROBLEM else LogLevel.INFO, "low power mode ${if (s.lowPowerMode) "ON" else "off"}")
        }
        if (p.batteryState != s.batteryState) writer.log(LogLevel.INFO, "battery state ${p.batteryState} -> ${s.batteryState}")
        if (p.networkStatus != s.networkStatus) {
            writer.log(LogLevel.INFO, "network ${p.networkStatus} -> ${s.networkStatus} (${s.networkType})")
        }
    }

    /** Runs on the timer thread, and once from [stop] after the timers ended. */
    private fun makeBatch() {
        val end = timeBase.uptimeNow()
        val start = lastBatchEndUp.swap(end)
        val q = deps.uploadQueue
        if (q == null || !q.isEnabled) {
            // Upload OFF: drop the window (memory stays bounded; the session folder keeps everything)
            // without consuming a batchSeq.
            accumulator.discard()
            synchronized(unqueuedBatches) {
                windowsNotQueued += 1 + unqueuedBatches.size
                unqueuedBatches.clear()
            }
            return
        }
        val batch = accumulator.drain(start, timeBase.utcMs(start), latestBox.current.device)
        synchronized(unqueuedBatches) {
            unqueuedBatches.add(batch)
            if (unqueuedBatches.size > MAX_UNQUEUED_BATCHES) {
                val dropped = unqueuedBatches.size - MAX_UNQUEUED_BATCHES
                unqueuedBatches.subList(0, dropped).clear()
                windowsNotQueued += dropped
                writer.log(LogLevel.WARN, "$dropped upload batch window(s) could not be queued and were dropped from the live upload (the session files keep the data)")
            }
            // Oldest first; each batch gets its batchSeq only when it is actually queued (no holes).
            val createdUtcMs = timeBase.utcMs(end).toLong()
            while (unqueuedBatches.isNotEmpty()) {
                val b = unqueuedBatches.first().withSeq(accumulator.nextSeq)
                try {
                    val json = b.jsonData()
                    if (json.size > MAX_BATCH_JSON_BYTES) {
                        // The ingest function rejects bodies > 200 KB (02 §5): the data is safe on disk; say so.
                        writer.log(LogLevel.WARN, "upload batch ${b.batchSeq} is ${json.size / 1024} KB (> ${MAX_BATCH_JSON_BYTES / 1024} KB): the backend may reject it")
                    }
                    q.enqueue(Gzip.compress(json), b.sessionId, b.batchSeq, createdUtcMs)
                    accumulator.markQueued(b.batchSeq)
                    unqueuedBatches.removeAt(0)
                } catch (e: Exception) {
                    writer.log(LogLevel.WARN, "could not queue upload batch ${b.batchSeq} (${unqueuedBatches.size} window(s) waiting, retried in $BATCH_INTERVAL_S s): ${e.text}")
                    break
                }
            }
        }
    }

    /**
     * Spec §6.1: the current session.json goes through the same queue as the batches (Start copy before
     * batch 0, Stop copy, with `batchCount`, after the last batch). Only while upload is ON.
     */
    private fun queueSessionMetadata(meta: SessionMetadata, phase: UploadQueue.MetaPhase, batchCount: Int? = null) {
        val q = deps.uploadQueue ?: return
        if (!q.isEnabled) return
        try {
            q.enqueueSessionMetadata(sessionMetadataBody(meta, batchCount), sessionId, phase, timeBase.utcMs(timeBase.uptimeNow()).toLong())
        } catch (e: Exception) {
            writer.log(LogLevel.WARN, "could not queue session metadata (${phase.id}): ${e.text}")
        }
    }

    // Lifecycle

    /** Records real background/foreground transitions only (the first "foreground" of a trip is not one). */
    fun noteLifecycle(background: Boolean) {
        if (!isRunning || latestBox.current.inBackground == background) return
        val now = timeBase.uptimeNow()
        latestBox.update {
            it.copy(inBackground = background, returnedFromBackgroundUp = if (background) it.returnedFromBackgroundUp else now)
        }
        writer.log(LogLevel.WARN, if (background) "app went to background (recording continues)" else "app returned to foreground")
        writeClockRow(timeBase.refreshAnchor(), if (background) "background" else "foreground")
    }

    fun log(level: LogLevel, message: String) = writer.log(level, message)

    // Health

    fun healthInputs(now: Double): HealthInputs {
        val l = latestBox.current
        val we = writer.writeErrors
        val d = deps.deviceStatus.currentStatus()
        val st: UploadStatus? = deps.uploadQueue?.status
        return HealthInputs(
            now = now, recordingStartUp = startUp,
            streams = monitors.mapValues { it.value.snapshot(now) },
            gpsLastFixUp = l.gpsFixUp, gpsHorizontalAccuracy = l.gps?.hAcc,
            locationDegraded = deps.location?.degradedReason,
            lastWriteErrorUp = we.lastAtUp, lastWriteError = we.last,
            freeDiskBytes = d.freeDiskBytes, thermal = d.thermal, lowPowerMode = d.lowPowerMode,
            batteryLevel = d.batteryLevel, batteryCharging = d.isCharging,
            inBackground = l.inBackground, returnedFromBackgroundUp = l.returnedFromBackgroundUp,
            uploadEnabled = st?.enabled ?: false, uploadQueueCount = st?.queueCount ?: 0,
            uploadLastSuccessUp = st?.lastSuccessUp,
            uploadEnabledSinceUp = st?.enabledSinceUp?.let { max(it, startUp) },
            uploadLastError = st?.lastError,
        )
    }

    private fun buildStats(endUp: Double): SessionMetadata.Stats {
        val sizes = folder.listFiles().orEmpty().filter { it.isFile }.associate { it.name to it.length() }
        val streams = monitors.filter { (_, m) -> m.snapshot(endUp).available || m.sampleCount > 0 }
            .entries.associate { (id, m) -> id.id to m.stats(sizes[id.file.fileName]) }
        val dropped = synchronized(unqueuedBatches) { windowsNotQueued }
        return SessionMetadata.Stats(
            durationSec = endUp - startUp, streams = streams, labelsCount = 0, // no labels since D51
            fileSizes = sizes, totalBytes = sizes.values.sum(), writeErrors = writer.writeErrors.count,
            uploadBatchesCreated = accumulator.nextSeq, uploadWindowsNotQueued = dropped.takeIf { it > 0 },
        )
    }

    companion object {
        private const val ANCHOR_INTERVAL_S = 10L
        private const val DEVICE_INTERVAL_S = 5L
        private const val BATCH_INTERVAL_S = 2L

        /** Cached GPS fixes older than this before the session start are not recorded. */
        const val STALE_FIX_MARGIN_S = 5.0

        /** The ingest function rejects bodies over 200 KB (02 §5); warn a little before that. */
        private const val MAX_BATCH_JSON_BYTES = 180 * 1024

        /**
         * Unqueued batches kept for a retry (30 s of windows); older ones are dropped from the live upload
         * so memory stays bounded on a full disk (the session files still have the data).
         */
        const val MAX_UNQUEUED_BATCHES = 15

        /**
         * §6.1 body: session.json, plus `batchCount` in the Stop copy, plus `source: "live"`. The rater's
         * name is personal data and stays on the phone; `uploadWindowsNotQueued` is local only (D55).
         */
        fun sessionMetadataBody(meta: SessionMetadata, batchCount: Int?): ByteArray {
            val obj = meta.json().toMutableMap()
            obj["people"] = meta.people.json() - "raterName"
            obj["source"] = "live"
            meta.stats?.let { obj["stats"] = it.json() - "uploadWindowsNotQueued" }
            if (batchCount != null) obj["batchCount"] = batchCount
            return Json.write(obj).toByteArray()
        }
    }
}
