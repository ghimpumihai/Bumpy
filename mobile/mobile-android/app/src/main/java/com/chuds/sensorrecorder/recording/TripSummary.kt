package com.chuds.sensorrecorder.recording

import com.chuds.sensorrecorder.core.SessionMetadata
import com.chuds.sensorrecorder.core.StreamId
import com.chuds.sensorrecorder.sensors.LocationSample
import java.util.Locale
import kotlin.math.cos
import kotlin.math.floor
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt
import kotlin.math.sqrt

/** "Did we get good data?" for one session (spec §7 Screen 5). */
class SessionVerdict(metadata: SessionMetadata) {
    private val streams = metadata.stats?.streams ?: emptyMap()
    private val gaps = streams.mapNotNull { (key, s) ->
        StreamId.of(key)?.takeIf { s.maxGapSec > it.significantGap }?.displayName
    }.sorted()

    /** Streams the drive is pointless without (spec P0 motion + GPS), with no samples. */
    private val missing = listOf(StreamId.DEVICE_MOTION, StreamId.ACCEL, StreamId.GYRO, StreamId.GPS)
        .filter { (streams[it.id]?.samples ?: 0L) == 0L }.map { it.displayName }
    private val writeErrors = metadata.stats?.writeErrors ?: 0

    val ok: Boolean get() = gaps.isEmpty() && missing.isEmpty() && writeErrors == 0

    val text: String
        get() = if (ok) "All streams OK" else listOfNotNull(
            if (missing.isEmpty()) null else "no data: " + missing.joinToString(", "),
            if (gaps.isEmpty()) null else "gaps: " + gaps.joinToString(", "),
            if (writeErrors == 0) null else "$writeErrors write errors",
        ).joinToString(" · ")
}

/** What the recap shows about a finished trip, derived from its `session.json` stats. */
class TripSummary(metadata: SessionMetadata) {
    /** Share of the trip for which motion and GPS both delivered data, 0–100; null without stats. */
    val qualityPercent: Int?

    /** Why quality is poor (red on the recap); null when the data is good. */
    val problem: String?
    val durationSec: Double = metadata.stats?.durationSec ?: 0.0
    val isPoor: Boolean get() = problem != null

    init {
        val stats = metadata.stats
        if (stats == null || stats.durationSec <= 0) {
            qualityPercent = null
            problem = null
        } else {
            // Coverage = samples received / samples expected at the nominal rate. Gaps lower it; a stream
            // missing entirely gives 0.
            val (worst, coverage) = listOf(StreamId.DEVICE_MOTION, StreamId.GPS).map { id ->
                val samples = (stats.streams[id.id]?.samples ?: 0L).toDouble()
                id to min(1.0, samples / (stats.durationSec * id.expectedHz!!))
            }.minBy { it.second }
            val percent = (coverage * 100).roundToInt()
            qualityPercent = percent
            val verdict = SessionVerdict(metadata)
            problem = when {
                stats.writeErrors > 0 -> "${stats.writeErrors} write errors on the phone."
                percent < GOOD_QUALITY -> {
                    val missing = TripFormat.gap((1 - coverage) * stats.durationSec)
                    if (worst == StreamId.GPS) "GPS dropped for $missing. Motion data is complete."
                    else "Motion dropped for $missing. GPS is complete."
                }
                !verdict.ok -> verdict.text.replaceFirstChar { it.uppercase() } + "."
                else -> null
            }
        }
    }

    companion object {
        /** Below this the recap shows the number in red with the reason. */
        const val GOOD_QUALITY = 90

        /** Track length from the (≥ 5 m thinned) live track; the on-screen estimate, not the backend's. */
        fun distanceMeters(points: List<TrackBuffer.Point>): Double =
            points.zipWithNext { a, b -> TrackBuffer.distanceM(a, b) }.sum()
    }
}

object TripFormat {
    /** `12 s`, `1 min 40 s`, `12 min`. */
    fun gap(seconds: Double): String {
        val s = max(0, seconds.roundToInt())
        if (s < 60) return "$s s"
        val m = s / 60
        val r = s % 60
        return if (m >= 10 || r == 0) "$m min" else "$m min $r s"
    }

    /** `42 min`, `1 h 05 min`, `40 s`. */
    fun duration(seconds: Double): String {
        val s = max(0, seconds.roundToInt())
        if (s < 60) return "$s s"
        val m = s / 60
        return if (m < 60) "$m min" else String.format(Locale.US, "%d h %02d min", m / 60, m % 60)
    }

    /** `18.6 km`, `850 m`. */
    fun distance(meters: Double): String =
        if (meters < 1000) "${meters.roundToInt()} m" else String.format(Locale.US, "%.1f km", meters / 1000)

    /** `42:17` or `1:02:17`. */
    fun timer(seconds: Double): String {
        val s = max(0, floor(seconds).toInt())
        return if (s >= 3600) String.format(Locale.US, "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
        else String.format(Locale.US, "%02d:%02d", s / 60, s % 60)
    }
}

/** GPS track for the recap's distance, thinned to points ≥ 5 m apart. Thread-safe. */
class TrackBuffer {
    data class Point(val lat: Double, val lon: Double)

    private val list = ArrayList<Point>()

    fun add(s: LocationSample) {
        if (s.hAcc < 0 || s.hAcc > 50) return // junk fixes
        val p = Point(s.lat, s.lon)
        synchronized(list) {
            if (list.isEmpty() || distanceM(list.last(), p) >= MIN_SPACING_M) list.add(p)
        }
    }

    val points: List<Point> get() = synchronized(list) { list.toList() }

    companion object {
        const val MIN_SPACING_M = 5.0

        fun distanceM(a: Point, b: Point): Double {
            val dLat = Math.toRadians(b.lat - a.lat)
            val x = Math.toRadians(b.lon - a.lon) * cos(Math.toRadians((a.lat + b.lat) / 2))
            return sqrt(x * x + dLat * dLat) * 6_371_000.0
        }
    }
}
