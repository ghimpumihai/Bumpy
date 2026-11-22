package com.chuds.sensorrecorder.core

import java.util.Locale

enum class HealthLevel(val label: String) { OK("OK"), WARN("WARN"), PROBLEM("PROBLEM") }

/** [key]: stable identity (e.g. `rate.gyro`) used to detect *new* problems for alerting/logging. */
data class HealthIssue(val level: HealthLevel, val key: String, val message: String)

/** iOS's four thermal states, which `device.csv` and the batches carry. */
enum class ThermalLevel(val id: String) { NOMINAL("nominal"), FAIR("fair"), SERIOUS("serious"), CRITICAL("critical") }

/** Everything the warning rules look at, captured at one instant. */
data class HealthInputs(
    val now: Double,
    val recordingStartUp: Double,
    val streams: Map<StreamId, StreamSnapshot> = emptyMap(),
    /** Last GPS fix arrival (uptime) and its accuracy. */
    val gpsLastFixUp: Double? = null,
    val gpsHorizontalAccuracy: Double? = null,
    /** Precise location is missing, revoked or switched off during recording. */
    val locationDegraded: String? = null,
    val lastWriteErrorUp: Double? = null,
    val lastWriteError: String? = null,
    val freeDiskBytes: Long? = null,
    val thermal: ThermalLevel = ThermalLevel.NOMINAL,
    val lowPowerMode: Boolean = false,
    val batteryLevel: Float = 1f, // -1 = unknown
    val batteryCharging: Boolean = true,
    val inBackground: Boolean = false,
    val returnedFromBackgroundUp: Double? = null,
    val uploadEnabled: Boolean = false,
    val uploadQueueCount: Int = 0,
    val uploadLastSuccessUp: Double? = null,
    val uploadEnabledSinceUp: Double? = null,
    val uploadLastError: String? = null,
)

/** Spec §7 "Warning rules", as in the iOS app. Pure function of [HealthInputs]. */
object HealthEvaluator {
    private const val MOTION_WARN_FRACTION = 0.9 // 90 Hz of 100
    private const val MOTION_PROBLEM_FRACTION = 0.5 // 50 Hz of 100
    private const val MOTION_MAX_AGE = 0.5
    private const val GPS_WARN_AGE = 5.0
    private const val GPS_PROBLEM_AGE = 15.0
    private const val GPS_WARN_ACCURACY = 20.0
    private const val DISK_WARN_BYTES = 1_000_000_000L
    private const val DISK_PROBLEM_BYTES = 300_000_000L
    private const val BATTERY_WARN = 0.20f
    private const val UPLOAD_QUEUE_WARN = 30
    private const val UPLOAD_STALE_SEC = 60.0
    private const val WRITE_ERROR_STICKY_SEC = 30.0
    private const val BACKGROUND_STICKY_SEC = 10.0
    private const val BAROMETER_WARN_AGE = 30.0

    /** A motion stream with no sample at all this long after start is a PROBLEM. */
    private const val MOTION_NO_DATA_GRACE = 1.5

    /** Extra settle time after the first full rate window before rates are judged. */
    private const val RATE_WINDOW_SETTLE = 0.5

    fun evaluate(i: HealthInputs): List<HealthIssue> {
        val out = ArrayList<HealthIssue>()
        fun warn(key: String, message: String) { out.add(HealthIssue(HealthLevel.WARN, key, message)) }
        fun problem(key: String, message: String) { out.add(HealthIssue(HealthLevel.PROBLEM, key, message)) }
        val elapsed = i.now - i.recordingStartUp

        for (id in listOf(StreamId.DEVICE_MOTION, StreamId.ACCEL, StreamId.GYRO, StreamId.MAG)) {
            val s = i.streams[id] ?: continue
            val expected = id.expectedHz ?: continue
            if (!s.available) continue
            val name = id.displayName
            val age = s.age
            if (age == null) {
                if (elapsed > MOTION_NO_DATA_GRACE) problem("stale.${id.id}", "$name: no data")
                continue
            }
            if (age > MOTION_MAX_AGE) {
                problem("stale.${id.id}", "$name: no sample for ${fmt1(age)} s")
                continue
            }
            // Only judge the rate once a full window has elapsed.
            if (elapsed < id.rateWindow + RATE_WINDOW_SETTLE) continue
            if (s.rateHz < expected * MOTION_PROBLEM_FRACTION) {
                problem("rate.${id.id}", "$name ${fmt1(s.rateHz)} Hz (< ${(expected * MOTION_PROBLEM_FRACTION).toInt()})")
            } else if (s.rateHz < expected * MOTION_WARN_FRACTION) {
                warn("rate.${id.id}", "$name ${fmt1(s.rateHz)} Hz (< ${(expected * MOTION_WARN_FRACTION).toInt()})")
            }
        }

        val gpsAge = i.now - (i.gpsLastFixUp ?: i.recordingStartUp)
        if (gpsAge > GPS_PROBLEM_AGE) problem("gps.nofix", "GPS: no fix for ${gpsAge.toInt()} s")
        else if (gpsAge > GPS_WARN_AGE) warn("gps.nofix", "GPS: no fix for ${gpsAge.toInt()} s")
        val acc = i.gpsHorizontalAccuracy
        if (acc != null && i.gpsLastFixUp != null && acc > GPS_WARN_ACCURACY) {
            warn("gps.accuracy", "GPS accuracy ${acc.toInt()} m (> ${GPS_WARN_ACCURACY.toInt()})")
        }

        i.streams[StreamId.BAROMETER]?.takeIf { it.available }?.let { b ->
            val age = b.age ?: elapsed
            if (age > BAROMETER_WARN_AGE) warn("baro.stale", "Barometer: no data for ${age.toInt()} s")
        }

        i.locationDegraded?.let { problem("gps.permission", it) }

        if (i.lastWriteErrorUp != null && i.now - i.lastWriteErrorUp < WRITE_ERROR_STICKY_SEC) {
            problem("disk.write", "Disk write error: ${i.lastWriteError ?: "unknown"}")
        }
        val free = i.freeDiskBytes
        if (free != null && free >= 0) {
            if (free < DISK_PROBLEM_BYTES) {
                problem("disk.free", "Free disk ${ByteFormat.string(free)} (< ${ByteFormat.string(DISK_PROBLEM_BYTES)})")
            } else if (free < DISK_WARN_BYTES) {
                warn("disk.free", "Free disk ${ByteFormat.string(free)} (< ${ByteFormat.string(DISK_WARN_BYTES)})")
            }
        }

        when (i.thermal) {
            ThermalLevel.CRITICAL -> problem("thermal", "Thermal CRITICAL: phone is throttling")
            ThermalLevel.SERIOUS -> warn("thermal", "Thermal serious: cool the phone")
            else -> {}
        }
        if (i.lowPowerMode) problem("lowpower", "Battery Saver is ON: turn it off")
        if (i.batteryLevel >= 0 && i.batteryLevel < BATTERY_WARN && !i.batteryCharging) {
            warn("battery", "Battery ${(i.batteryLevel * 100).toInt()} % and not charging")
        }

        if (i.inBackground) {
            warn("background", "App is in background (still recording)")
        } else if (i.returnedFromBackgroundUp != null && i.now - i.returnedFromBackgroundUp < BACKGROUND_STICKY_SEC) {
            warn("background", "App was in background (recording continued)")
        }

        // Upload: never PROBLEM, the data is safe on disk.
        if (i.uploadEnabled) {
            if (i.uploadQueueCount > UPLOAD_QUEUE_WARN) warn("upload.queue", "Upload queue ${i.uploadQueueCount} batches")
            val reference = i.uploadLastSuccessUp ?: i.uploadEnabledSinceUp ?: i.recordingStartUp
            if (i.now - reference > UPLOAD_STALE_SEC) {
                val what = if (i.uploadLastSuccessUp == null) "no successful upload yet"
                else "last upload OK ${(i.now - reference).toInt()} s ago"
                warn("upload.stale", "Upload: $what${i.uploadLastError?.let { " ($it)" } ?: ""}")
            }
        }

        return out.sortedWith(compareByDescending<HealthIssue> { it.level }.thenBy { it.key })
    }

    private fun fmt1(v: Double) = String.format(Locale.US, "%.1f", v)
}
