package com.chuds.sensorrecorder.core

import java.io.File
import kotlin.math.max
import kotlin.math.roundToLong

/** Logical data streams. [id] is the key in `session.json` stats (the iOS app's names). */
enum class StreamId(val id: String, val displayName: String, val expectedHz: Double?, val file: StreamFile) {
    DEVICE_MOTION("deviceMotion", "DeviceMotion", 100.0, StreamFile.DEVICE_MOTION),
    ACCEL("accel", "Accel raw", 100.0, StreamFile.ACCEL_RAW),
    GYRO("gyro", "Gyro raw", 100.0, StreamFile.GYRO_RAW),
    MAG("mag", "Magnetometer", 50.0, StreamFile.MAG_RAW),
    GPS("gps", "GPS", 1.0, StreamFile.LOCATION),
    HEADING("heading", "Heading", null, StreamFile.HEADING),
    BAROMETER("barometer", "Barometer", null, StreamFile.ALTIMETER),
    ABS_ALTITUDE("absAltitude", "Abs. altitude", null, StreamFile.ABS_ALTITUDE),
    ACTIVITY("activity", "Activity", null, StreamFile.ACTIVITY),
    DEVICE("device", "Device health", 0.2, StreamFile.DEVICE);

    val isMotion: Boolean get() = this == DEVICE_MOTION || this == ACCEL || this == GYRO || this == MAG

    /**
     * A gap longer than this means lost data. Spec: "> 1 s"; for 1 Hz GPS every gap is ~1 s, so it
     * uses 3 s; event-driven / slow streams never count as gaps.
     */
    val significantGap: Double
        get() = when {
            isMotion -> 1.0
            this == GPS -> 3.0
            this == DEVICE -> 15.0 // 3 missed polls
            else -> Double.POSITIVE_INFINITY
        }

    /** Window over which the "current" rate is measured (spec: 2 s for motion). */
    val rateWindow: Double get() = if (isMotion) 2.0 else 10.0

    companion object {
        fun of(id: String): StreamId? = entries.firstOrNull { it.id == id }
    }
}

/** Incremental gap statistics over a sequence of sample timestamps. Not thread-safe by itself. */
class GapTracker(val expectedHz: Double?) {
    var count = 0L
        private set
    var first: Double? = null
        private set
    var last: Double? = null
        private set
    var maxGap = 0.0
        private set
    var gapsOver1s = 0
        private set
    var droppedEstimate = 0L
        private set

    fun add(t: Double) {
        count++
        if (first == null) first = t
        val prev = last
        if (prev != null && t > prev) {
            val dt = t - prev
            maxGap = max(maxGap, dt)
            if (dt > 1) gapsOver1s++
            if (expectedHz != null && dt * expectedHz > 1.5) droppedEstimate += (dt * expectedHz).roundToLong() - 1
        }
        if (prev == null || t > prev) last = t
    }

    val meanRateHz: Double
        get() {
            val f = first ?: return 0.0
            val l = last ?: return 0.0
            return if (count > 1 && l > f) (count - 1) / (l - f) else 0.0
        }
}

data class StreamSnapshot(
    val id: StreamId,
    val count: Long,
    /** Rate over the stream's window ending now; 0 if fewer than 2 samples in the window. */
    val rateHz: Double,
    /** Seconds since the last sample arrived; null if nothing arrived yet. */
    val age: Double?,
    val available: Boolean,
)

/** Thread-safe live statistics for one stream. [record] is called from sensor threads. */
class StreamMonitor(val id: StreamId) {
    private val gaps = GapTracker(id.expectedHz)

    // Over twice the nominal rate: Android may deliver up to 2.2x the requested rate.
    private val recent = RingBuffer((id.rateWindow * (id.expectedHz ?: 10.0) * 2.2).toInt() + 16)
    private var lastArrival: Double? = null
    private var available = true

    /** [t]: sample timestamp (seconds since boot); [arrival]: uptime when we received it. */
    fun record(t: Double, arrival: Double) = synchronized(this) {
        gaps.add(t)
        recent.append(t)
        lastArrival = arrival
    }

    fun setAvailable(v: Boolean) = synchronized(this) { available = v }

    val sampleCount: Long get() = synchronized(this) { gaps.count }

    fun stats(fileBytes: Long?): SessionMetadata.StreamStats =
        synchronized(this) { SessionMetadata.StreamStats.of(gaps, fileBytes) }

    fun snapshot(now: Double): StreamSnapshot = synchronized(this) {
        val w = recent.elements.filter { it > now - id.rateWindow }
        val rate = if (w.size >= 2 && w.last() > w.first()) (w.size - 1) / (w.last() - w.first()) else 0.0
        StreamSnapshot(id, gaps.count, rate, lastArrival?.let { max(0.0, now - it) }, available)
    }
}

/**
 * Offline analysis of a session folder from its CSV files (used for recovered sessions). Reads only
 * the first column (`t_up`) of each file.
 */
object SessionAnalyzer {
    class Result {
        val streams = LinkedHashMap<StreamId, GapTracker>()
        var labelsCount = 0
        val fileSizes = LinkedHashMap<String, Long>()
        var totalBytes = 0L

        /** Latest sample timestamp (t_up) over all streams. */
        val lastSampleUp: Double? get() = streams.values.mapNotNull { it.last }.maxOrNull()

        val durationSec: Double
            get() {
                val start = streams.values.mapNotNull { it.first }.minOrNull() ?: return 0.0
                return (lastSampleUp ?: start) - start
            }

        fun asStats() = SessionMetadata.Stats(
            durationSec = durationSec,
            streams = streams.entries.associate { (id, t) ->
                id.id to SessionMetadata.StreamStats.of(t, fileSizes[id.file.fileName])
            },
            labelsCount = labelsCount, fileSizes = fileSizes, totalBytes = totalBytes,
            writeErrors = 0, uploadBatchesCreated = 0,
        )
    }

    fun analyze(folder: File): Result {
        val r = Result()
        for (f in folder.listFiles().orEmpty().filter { it.isFile }) {
            r.fileSizes[f.name] = f.length()
            r.totalBytes += f.length()
        }
        for (id in StreamId.entries) {
            val f = File(folder, id.file.fileName)
            if (!f.exists()) continue
            val tracker = GapTracker(id.expectedHz)
            runCatching { forEachFirstColumn(f) { tracker.add(it) } }
            r.streams[id] = tracker
        }
        val labels = File(folder, StreamFile.LABELS.fileName)
        if (labels.exists()) runCatching { r.labelsCount = max(0, labels.readLines().count { it.isNotEmpty() } - 1) }
        return r
    }

    /** Streams the file and parses the first comma-separated field of every data row. */
    fun forEachFirstColumn(file: File, body: (Double) -> Unit) {
        file.inputStream().buffered(1 shl 16).use { input ->
            val field = StringBuilder(32)
            var inHeader = true
            var inField = false
            while (true) {
                val c = input.read()
                if (c < 0) break
                when {
                    c == '\n'.code -> {
                        field.setLength(0)
                        inHeader = false
                        inField = true
                    }
                    inHeader || !inField -> {}
                    c == ','.code -> {
                        finite(field)?.let(body)
                        inField = false
                    }
                    field.length < 64 -> field.append(c.toChar())
                }
            }
        }
    }

    private fun finite(s: CharSequence): Double? =
        if (s.length in 1..63) s.toString().toDoubleOrNull()?.takeIf { it.isFinite() } else null
}
