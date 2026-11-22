package com.chuds.sensorrecorder.core

/** Abstracts the two clocks we care about so the time logic can be unit-tested. */
interface ClockSource {
    /** Seconds since boot: the clock of the sensor timestamps (`elapsedRealtimeNanos`). */
    fun uptime(): Double

    /** Wall clock, Unix epoch milliseconds (UTC). */
    fun nowUtcMs(): Double
}

/** A pair of (uptime, UTC) readings taken back-to-back. See spec §5. */
data class ClockAnchor(val up: Double, val utcMs: Double)

/**
 * Converts between the sensor clock (seconds since boot) and UTC using the most recent anchor:
 * `utc_ms = anchor_utc_ms + (t_up - anchor_up) * 1000`.
 *
 * Anchors are refreshed every 10 s by the recording session and written to `clock.csv`, so the
 * backend can redo this conversion (and detect wall-clock jumps from NTP corrections).
 */
class TimeBase(private val clock: ClockSource) {
    private val anchor = Locked(sample(clock))

    fun refreshAnchor(): ClockAnchor = sample(clock).also { anchor.set(it) }
    fun uptimeNow(): Double = clock.uptime()
    fun nowUtcMs(): Double = clock.nowUtcMs()

    fun utcMs(up: Double): Double = anchor.current.let { it.utcMs + (up - it.up) * 1000 }
    fun uptime(utcMs: Double): Double = anchor.current.let { it.up + (utcMs - it.utcMs) / 1000 }

    companion object {
        /** Reads uptime, wall clock, uptime again and uses the midpoint, which halves the read jitter. */
        fun sample(clock: ClockSource): ClockAnchor {
            val u1 = clock.uptime()
            val w = clock.nowUtcMs()
            val u2 = clock.uptime()
            return ClockAnchor((u1 + u2) / 2, w)
        }
    }
}
