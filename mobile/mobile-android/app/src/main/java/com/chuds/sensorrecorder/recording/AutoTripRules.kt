package com.chuds.sensorrecorder.recording

import kotlin.math.asin
import kotlin.math.cos
import kotlin.math.max
import kotlin.math.min
import kotlin.math.sin
import kotlin.math.sqrt

/**
 * When an automatic trip starts and stops (D59, 01 §7 "Automatic trips"), on Android without Play
 * Services: speed from location, steps from the step detector. Pure: times are seconds since boot
 * (`elapsedRealtime`), speeds m/s, a negative speed is "unknown". Main thread.
 */
class AutoTripRules {
    private class GpsFix(val up: Double, val speed: Double)

    private var lastStepUp: Double? = null
    private var walkStartUp: Double? = null
    private var lastMovingUp: Double? = null
    private var lastCoarse: CoarseFix? = null
    private val gps = ArrayDeque<GpsFix>()

    // While an automatic trip records
    private var tripStartUp: Double? = null
    private var lastFastUp: Double? = null // GPS speed ≥ STOP_SLOW_MPS
    private var lastDrivingUp: Double? = null // GPS speed ≥ STOP_WALK_MPS

    data class CoarseFix(val up: Double, val lat: Double, val lon: Double, val accuracyM: Double, val speed: Double)

    /** A step from the step detector, at the time it was measured. */
    fun onStep(up: Double) {
        val last = lastStepUp
        if (last == null || up - last > STEP_GAP_S) walkStartUp = up
        if (last == null || up > last) lastStepUp = up
    }

    /**
     * A low-power fix (network or passive). Network fixes rarely carry a speed, so it is also derived from
     * two fixes far enough apart in time and space that their error can't fake it.
     */
    fun onCoarseFix(f: CoarseFix) {
        val prev = lastCoarse
        var speed = f.speed
        if (speed < 0 && prev != null) {
            val dt = f.up - prev.up
            val d = distanceM(prev.lat, prev.lon, f.lat, f.lon)
            val err = max(0.0, prev.accuracyM) + max(0.0, f.accuracyM)
            if (dt >= MIN_DERIVED_DT_S && d > err) speed = d / dt
        }
        if (speed >= CANDIDATE_MPS) lastMovingUp = max(lastMovingUp ?: f.up, f.up)
        if (prev == null || f.up - prev.up >= MIN_DERIVED_DT_S) lastCoarse = f
    }

    /** A GPS fix (1 Hz once the phone is a candidate, and during an automatic trip). */
    fun onGpsFix(up: Double, speed: Double) {
        if (speed >= CANDIDATE_MPS) lastMovingUp = max(lastMovingUp ?: up, up)
        if (gps.isEmpty() || up > gps.last().up) gps.addLast(GpsFix(up, speed))
        while (gps.isNotEmpty() && up - gps.first().up > START_WINDOW_S) gps.removeFirst()
        if (tripStartUp != null) {
            if (speed >= STOP_SLOW_MPS) lastFastUp = up
            if (speed >= STOP_WALK_MPS) lastDrivingUp = up
        }
    }

    /** The phone looks like it is in a vehicle: it moved recently, and no step for a minute. */
    fun isCandidate(now: Double): Boolean {
        val moving = lastMovingUp ?: return false
        if (now - moving > CANDIDATE_TIMEOUT_S) return false
        val step = lastStepUp
        return step == null || now - step >= NO_STEPS_S
    }

    /** Seconds of GPS speed ≥ 20 km/h within the last 90 s. Each fix counts until the next, at most 3 s. */
    fun fastSeconds(now: Double): Double {
        var total = 0.0
        var prev: GpsFix? = null
        for (f in gps) {
            val p = prev
            if (p != null && p.speed >= START_MPS && f.up > now - START_WINDOW_S) {
                total += min(f.up - max(p.up, now - START_WINDOW_S), MAX_FIX_SPAN_S)
            }
            prev = f
        }
        return total
    }

    fun shouldStart(now: Double): Boolean = tripStartUp == null && isCandidate(now) && fastSeconds(now) >= START_FAST_S

    fun tripStarted(now: Double) {
        tripStartUp = now
        lastFastUp = now
        lastDrivingUp = now
    }

    /** Automatic trips only: 10 min below 1.5 m/s, or 60 s of walking below 2 m/s. */
    fun shouldStop(now: Double): Boolean {
        val start = tripStartUp ?: return false
        if (now - max(start, lastFastUp ?: start) >= STOP_SLOW_S) return true
        val step = lastStepUp ?: return false
        val walk = walkStartUp ?: return false
        if (now - step > STEP_GAP_S) return false // not walking right now
        return now - maxOf(walk, lastDrivingUp ?: start, start) >= STOP_WALK_S
    }

    /** After a trip ended or a candidate fell through: the next start needs a fresh 30 s of driving. */
    fun reset() {
        tripStartUp = null
        lastFastUp = null
        lastDrivingUp = null
        gps.clear()
    }

    companion object {
        /** "Moving" for a candidate: about 14 km/h, faster than a brisk run. */
        const val CANDIDATE_MPS = 4.0
        const val CANDIDATE_TIMEOUT_S = 180.0 // red lights and jams keep a candidate
        const val NO_STEPS_S = 60.0
        const val START_MPS = 20 / 3.6 // 5.56 m/s
        const val START_FAST_S = 30.0
        const val START_WINDOW_S = 90.0
        const val MAX_FIX_SPAN_S = 3.0
        const val STOP_SLOW_MPS = 1.5
        const val STOP_SLOW_S = 600.0
        const val STOP_WALK_MPS = 2.0
        const val STOP_WALK_S = 60.0

        /** Steps further apart than this are not one walk. */
        const val STEP_GAP_S = 5.0
        const val MIN_DERIVED_DT_S = 10.0

        fun distanceM(lat1: Double, lon1: Double, lat2: Double, lon2: Double): Double {
            val r = 6_371_000.0
            val p1 = Math.toRadians(lat1)
            val p2 = Math.toRadians(lat2)
            val dp = p2 - p1
            val dl = Math.toRadians(lon2 - lon1)
            val a = sin(dp / 2) * sin(dp / 2) + cos(p1) * cos(p2) * sin(dl / 2) * sin(dl / 2)
            return 2 * r * asin(sqrt(min(1.0, a)))
        }
    }
}
