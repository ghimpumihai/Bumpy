package com.chuds.sensorrecorder.upload

import com.chuds.sensorrecorder.core.Csv
import com.chuds.sensorrecorder.core.DoubleList
import com.chuds.sensorrecorder.core.ISO8601
import com.chuds.sensorrecorder.core.Json
import com.chuds.sensorrecorder.sensors.AltimeterSample
import com.chuds.sensorrecorder.sensors.DeviceMotionSample
import com.chuds.sensorrecorder.sensors.DeviceStatus
import com.chuds.sensorrecorder.sensors.HeadingSample
import com.chuds.sensorrecorder.sensors.LocationSample
import com.chuds.sensorrecorder.sensors.Vec3Sample

/**
 * `POST /api/ingest` body (spec §6), schemaVersion 1: the iOS app's JSON, key for key. Columnar arrays
 * keep payloads small; every `t` array is seconds relative to `t0Up`.
 *
 * Integers (`batchSeq`, `t0UtcMs`, `tUtcMs`) stay Int/Long here: the validator rejects `1.0`.
 */
class IngestBatch(
    val sessionId: String,
    val deviceId: String,
    val batchSeq: Int,
    val t0UtcMs: Long,
    val t0Up: Double,
    private val blocks: Map<String, Any?>,
) {
    fun withSeq(seq: Int) = IngestBatch(sessionId, deviceId, seq, t0UtcMs, t0Up, blocks)

    fun json(): Map<String, Any?> = blocks + mapOf(
        "schemaVersion" to 1,
        "eventType" to "sensor_batch",
        "source" to "live",
        "sessionId" to sessionId,
        "deviceId" to deviceId,
        "batchSeq" to batchSeq,
        "t0Utc" to ISO8601.string(t0UtcMs),
        "t0Up" to t0Up,
        "t0UtcMs" to t0UtcMs,
        "units" to UNITS,
        "fieldUnits" to FIELD_UNITS,
        "labels" to emptyList<Any>(), // required by the contract, always empty since D51
        // No Android equivalent without Play Services; nothing in the backend reads them.
        "absAltitude" to mapOf("t" to emptyList<Any>(), "altitudeM" to emptyList<Any>(),
            "accuracyM" to emptyList<Any>(), "precisionM" to emptyList<Any>()),
        "activity" to emptyList<Any>(),
    )

    fun jsonData(): ByteArray = Json.write(json()).toByteArray()

    companion object {
        val UNITS = mapOf("accel" to "g", "gyro" to "rad/s", "speed" to "m/s", "pressure" to "kPa")

        val FIELD_UNITS = mapOf(
            "t" to "s (relative to t0Up)", "t0Up" to "s since boot", "t0UtcMs" to "ms since Unix epoch (UTC)",
            "deviceMotion.ua" to "g", "deviceMotion.g" to "g", "deviceMotion.rr" to "rad/s", "deviceMotion.q" to "unitless quaternion",
            "accelRaw" to "g", "gyroRaw" to "rad/s",
            "location.tUtcMs" to "ms since Unix epoch (UTC)", "location.lat" to "deg", "location.lon" to "deg",
            "location.alt" to "m", "location.hAcc" to "m", "location.speed" to "m/s (-1 = invalid)",
            "location.speedAcc" to "m/s", "location.course" to "deg (-1 = invalid)",
            "altimeter.relAltM" to "m", "altimeter.pressureKpa" to "kPa",
            "device.battery" to "fraction 0-1 (-1 = unknown)", "device.freeDiskBytes" to "bytes",
            "deviceMotion.roll" to "rad", "deviceMotion.pitch" to "rad", "deviceMotion.yaw" to "rad",
            "magRaw" to "µT", "heading.magHeading" to "deg", "heading.trueHeading" to "deg (-1 = invalid)",
            "heading.headingAcc" to "deg (-1 = invalid)", "heading.xyz" to "µT", "heading.tUtcMs" to "ms since Unix epoch (UTC)",
            "absAltitude.altitudeM" to "m", "absAltitude.accuracyM" to "m", "absAltitude.precisionM" to "m",
            "activity.t" to "s (relative to t0Up)", "activity.confidence" to "0 low, 1 medium, 2 high",
            "activity.startUtcMs" to "ms since Unix epoch (UTC)",
            "location.ellAlt" to "m", "location.vAcc" to "m (-1 = invalid)", "location.courseAcc" to "deg (-1 = invalid)",
        )
    }
}

internal fun round6(v: Double): Double = if (v.isFinite()) Csv.roundHalfAway(v * 1e6) / 1e6 else 0.0
internal fun round8(v: Double): Double = if (v.isFinite()) Csv.roundHalfAway(v * 1e8) / 1e8 else 0.0

/** For the fields where -1 means "invalid" (speed, course, accuracies, battery). */
internal fun round6OrInvalid(v: Double): Double = if (v.isFinite()) round6(v) else -1.0

private fun allFinite(vararg v: Double) = v.all { it.isFinite() }

/**
 * Collects the samples of the current 2 s window (an in-memory copy; disk files remain the source of
 * truth). Thread-safe: `add*` is called from sensor threads, [drain] from the batch timer.
 */
class BatchAccumulator(val sessionId: String, val deviceId: String) {
    private class Pending {
        val dm = ArrayList<DeviceMotionSample>()
        val accel = ArrayList<Vec3Sample>()
        val gyro = ArrayList<Vec3Sample>()
        val mag = ArrayList<Vec3Sample>()
        val location = ArrayList<LocationSample>()
        val heading = ArrayList<HeadingSample>()
        val altimeter = ArrayList<AltimeterSample>()
    }

    private val lock = Any()
    private var pending = Pending()
    private var seq = 0

    fun add(s: DeviceMotionSample) { synchronized(lock) { pending.dm.add(s) } }
    fun addAccel(s: Vec3Sample) { synchronized(lock) { pending.accel.add(s) } }
    fun addGyro(s: Vec3Sample) { synchronized(lock) { pending.gyro.add(s) } }
    fun addMag(s: Vec3Sample) { synchronized(lock) { pending.mag.add(s) } }
    fun add(s: LocationSample) { synchronized(lock) { pending.location.add(s) } }
    fun add(s: HeadingSample) { synchronized(lock) { pending.heading.add(s) } }
    fun add(s: AltimeterSample) { synchronized(lock) { pending.altimeter.add(s) } }

    /**
     * Batches durably queued so far (the §6.1 `batchCount`, numbers `0 until nextSeq`) and the number
     * the next queued batch gets.
     */
    val nextSeq: Int get() = synchronized(lock) { seq }

    /**
     * Call once batch [queued] is durably in the upload queue: only then is its number used. A batch
     * that could not be queued (disk full) leaves no hole, so `batchCount` is exact (spec §6.2).
     */
    fun markQueued(queued: Int) = synchronized(lock) { if (seq == queued) seq++ }

    /** Drops the current window without consuming a sequence number (upload OFF). */
    fun discard() = synchronized(lock) { pending = Pending() }

    /**
     * Takes everything collected since the previous drain and builds a batch numbered [nextSeq]. The
     * number is consumed only by [markQueued]. [t0Up] is the window start.
     *
     * Non-finite values: the CSV writes an empty field, but the contract accepts only finite numbers,
     * never null, and one bad value rejects the whole batch. So a value with an "invalid" marker gets
     * -1 (a non-finite altitude also sets `vAcc` to -1); any other sample with a non-finite value, or a
     * fix outside lat ±90 / lon ±180, is left out rather than sent as a made-up 0. Arrays stay aligned,
     * and the session folder keeps the row.
     */
    fun drain(t0Up: Double, t0UtcMs: Double, device: DeviceStatus): IngestBatch {
        val (p, n) = synchronized(lock) {
            val out = pending
            pending = Pending()
            out to seq
        }
        val rel = { t: Double -> round6(t - t0Up) }

        val dm = List(DM_COLUMNS.size) { DoubleList() }
        for (s in p.dm) {
            val v = doubleArrayOf(
                s.t, s.userAccel.x, s.userAccel.y, s.userAccel.z, s.gravity.x, s.gravity.y, s.gravity.z,
                s.rotationRate.x, s.rotationRate.y, s.rotationRate.z,
                s.quaternion.w, s.quaternion.x, s.quaternion.y, s.quaternion.z, s.roll, s.pitch, s.yaw,
            )
            if (!allFinite(*v)) continue
            dm[0].add(rel(s.t))
            for (i in 1 until v.size) dm[i].add(round6(v[i]))
        }

        val altT = DoubleList()
        val altRel = DoubleList()
        val altKpa = DoubleList()
        for (s in p.altimeter) {
            if (!allFinite(s.t, s.relativeAltitudeM, s.pressureKPa)) continue
            altT.add(rel(s.t))
            altRel.add(round6(s.relativeAltitudeM))
            altKpa.add(round6(s.pressureKPa))
        }

        val battery = device.batteryLevel.toDouble()
        return IngestBatch(
            sessionId, deviceId, n, if (t0UtcMs.isFinite()) Csv.roundHalfAway(t0UtcMs) else 0L, round6(t0Up),
            mapOf(
                "deviceMotion" to DM_COLUMNS.zip(dm).toMap(),
                "accelRaw" to xyz(p.accel, rel),
                "gyroRaw" to xyz(p.gyro, rel),
                "magRaw" to xyz(p.mag, rel),
                "location" to p.location.mapNotNull(::location),
                "heading" to p.heading.mapNotNull(::heading),
                "altimeter" to mapOf("t" to altT, "relAltM" to altRel, "pressureKpa" to altKpa),
                "device" to mapOf(
                    "battery" to if (battery.isFinite()) round6(battery) else -1.0,
                    "thermal" to device.thermal.id, "lowPower" to device.lowPowerMode,
                    "batteryState" to device.batteryState, "freeDiskBytes" to device.freeDiskBytes,
                    "netStatus" to device.networkStatus, "netType" to device.networkType,
                ),
            ),
        )
    }

    private fun location(s: LocationSample): Map<String, Any?>? {
        if (!s.utcMs.isFinite() || s.lat !in -90.0..90.0 || s.lon !in -180.0..180.0) return null
        return mapOf(
            "tUtcMs" to Csv.roundHalfAway(s.utcMs), "lat" to round8(s.lat), "lon" to round8(s.lon), "alt" to round6(s.alt),
            "hAcc" to round6OrInvalid(s.hAcc), "speed" to round6OrInvalid(s.speed),
            "speedAcc" to round6OrInvalid(s.speedAcc), "course" to round6OrInvalid(s.course),
            "isSimulated" to s.isSimulated, "ellAlt" to round6(s.ellAlt),
            "vAcc" to if (allFinite(s.alt, s.ellAlt)) round6OrInvalid(s.vAcc) else -1.0,
            "courseAcc" to round6OrInvalid(s.courseAcc),
        )
    }

    private fun heading(s: HeadingSample): Map<String, Any?>? {
        if (!allFinite(s.utcMs, s.magneticHeading, s.raw.x, s.raw.y, s.raw.z)) return null
        return mapOf(
            "tUtcMs" to Csv.roundHalfAway(s.utcMs), "magHeading" to round6(s.magneticHeading),
            "trueHeading" to round6OrInvalid(s.trueHeading), "headingAcc" to round6OrInvalid(s.accuracy),
            "x" to round6(s.raw.x), "y" to round6(s.raw.y), "z" to round6(s.raw.z),
        )
    }

    private fun xyz(samples: List<Vec3Sample>, rel: (Double) -> Double): Map<String, DoubleList> {
        val t = DoubleList()
        val x = DoubleList()
        val y = DoubleList()
        val z = DoubleList()
        for (s in samples) {
            if (!allFinite(s.t, s.v.x, s.v.y, s.v.z)) continue
            t.add(rel(s.t))
            x.add(round6(s.v.x))
            y.add(round6(s.v.y))
            z.add(round6(s.v.z))
        }
        return mapOf("t" to t, "x" to x, "y" to y, "z" to z)
    }

    private companion object {
        val DM_COLUMNS = listOf(
            "t", "ua_x", "ua_y", "ua_z", "g_x", "g_y", "g_z", "rr_x", "rr_y", "rr_z",
            "q_w", "q_x", "q_y", "q_z", "roll", "pitch", "yaw",
        )
    }
}
