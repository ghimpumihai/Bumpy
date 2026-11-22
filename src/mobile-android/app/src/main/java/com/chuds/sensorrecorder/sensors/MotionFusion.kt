package com.chuds.sensorrecorder.sensors

import com.chuds.sensorrecorder.core.Vec3
import kotlin.math.abs
import kotlin.math.asin
import kotlin.math.atan2
import kotlin.math.sqrt

/** Android → iOS conversions (units, signs). */
object IosFrame {
    /** Android accelerometer (m/s²) → iOS `CMAccelerometerData` (g). Flat and screen up at rest Android
     *  reads +9.81 on z, iOS −1. */
    fun accel(x: Double, y: Double, z: Double) = Vec3(-x / G, -y / G, -z / G)

    /** iOS `gravity` (unit length, pointing down) from a device → reference quaternion (Z up). */
    fun gravity(q: Quaternion) = Vec3(
        -2 * (q.x * q.z - q.w * q.y),
        -2 * (q.y * q.z + q.w * q.x),
        -(1 - 2 * (q.x * q.x + q.y * q.y)),
    )

    /** CoreMotion's attitude angles: R = Rz(yaw)·Rx(pitch)·Ry(roll). */
    fun roll(q: Quaternion) = atan2(-2 * (q.x * q.z - q.w * q.y), 1 - 2 * (q.x * q.x + q.y * q.y))
    fun pitch(q: Quaternion) = asin((2 * (q.y * q.z + q.w * q.x)).coerceIn(-1.0, 1.0))
    fun yaw(q: Quaternion) = atan2(-2 * (q.x * q.y - q.w * q.z), 1 - 2 * (q.x * q.x + q.z * q.z))

    const val G = 9.80665
}

/**
 * Builds iOS-like `deviceMotion` samples from Android's separate sensors: one per accelerometer sample,
 * with the rotation and the rotation rate interpolated to its timestamp.
 *
 * Gravity comes from the fused rotation (so it always has length 1 g) and user acceleration is the raw
 * accelerometer minus it, which is CoreMotion's own definition. Android's TYPE_GRAVITY and
 * TYPE_LINEAR_ACCELERATION are not used: each vendor filters them differently, and the sickness dose
 * lives at 0.1–0.5 Hz, where a gravity estimate that follows the acceleration hides it (D46).
 *
 * Not thread-safe: fed from the one sensor thread.
 */
class MotionFusion(private val emit: (DeviceMotionSample) -> Unit) {
    private class Timed(val t: Double, val v: DoubleArray)

    private val accel = ArrayDeque<Vec3Sample>() // iOS frame, waiting for later gyro and rotation samples
    private val gyro = ArrayDeque<Timed>()
    private val rotation = ArrayDeque<Timed>()

    private var lastAccelT = Double.NaN
    private var meanInterval = Double.NaN
    private var intervals = 0
    private var half: Vec3Sample? = null

    /** Android may run the accelerometer at up to twice the requested rate: above [HALVE_ABOVE_HZ]
     *  neighbours are averaged, so deviceMotion stays near the backend's 100 Hz grid without aliasing. */
    fun addAccel(t: Double, ios: Vec3) {
        val dt = t - lastAccelT
        if (dt > 0 && dt < 0.1) {
            meanInterval = if (meanInterval.isNaN()) dt else meanInterval + 0.05 * (dt - meanInterval)
            intervals++
        }
        lastAccelT = t
        val s = Vec3Sample(t, ios)
        if (intervals >= RATE_SETTLE && meanInterval < 1 / HALVE_ABOVE_HZ) {
            val first = half
            if (first == null || t - first.t > MAX_BRACKET_S) {
                half = s
                return
            }
            half = null
            accel.addLast(Vec3Sample((first.t + t) / 2, (first.v + ios) * 0.5))
        } else {
            half = null
            accel.addLast(s)
        }
        // A stalled gyro or rotation sensor: drop the oldest rather than emit made-up motion.
        while (accel.size > MAX_PENDING) accel.removeFirst()
        pump()
    }

    fun addGyro(t: Double, x: Double, y: Double, z: Double) {
        push(gyro, Timed(t, doubleArrayOf(x, y, z)))
        pump()
    }

    fun addRotation(t: Double, q: Quaternion) {
        val v = doubleArrayOf(q.w, q.x, q.y, q.z)
        // q and −q are the same rotation; keep neighbours on one side so they can be interpolated.
        rotation.lastOrNull()?.let { last -> if (dot(last.v, v) < 0) for (i in v.indices) v[i] = -v[i] }
        push(rotation, Timed(t, v))
        pump()
    }

    private fun push(d: ArrayDeque<Timed>, s: Timed) {
        val last = d.lastOrNull()
        if (last != null && s.t <= last.t) return // out of order: can't bracket anything
        d.addLast(s)
        while (d.size > MAX_PENDING * 4) d.removeFirst()
    }

    private fun pump() {
        while (true) {
            val a = accel.firstOrNull() ?: return
            val g = gyro.lastOrNull() ?: return
            val r = rotation.lastOrNull() ?: return
            if (g.t < a.t || r.t < a.t) return // wait for the sample after it
            accel.removeFirst()
            val gv = at(gyro, a.t) ?: continue
            val rv = at(rotation, a.t) ?: continue
            val n = sqrt(dot(rv, rv))
            if (n < 1e-6) continue
            val q = Quaternion(rv[0] / n, rv[1] / n, rv[2] / n, rv[3] / n)
            val gravity = IosFrame.gravity(q)
            emit(
                DeviceMotionSample(
                    a.t, a.v - gravity, gravity, Vec3(gv[0], gv[1], gv[2]), q,
                    IosFrame.roll(q), IosFrame.pitch(q), IosFrame.yaw(q),
                ),
            )
        }
    }

    /** Linear interpolation at [t]; null when no pair closer than [MAX_BRACKET_S] surrounds it. */
    private fun at(d: ArrayDeque<Timed>, t: Double): DoubleArray? {
        while (d.size > 1 && d[1].t <= t) d.removeFirst()
        val a = d.first()
        if (a.t == t) return a.v
        if (a.t > t || d.size < 2) return null
        val b = d[1]
        if (b.t - a.t > MAX_BRACKET_S) return null
        val k = (t - a.t) / (b.t - a.t)
        return DoubleArray(a.v.size) { a.v[it] + k * (b.v[it] - a.v[it]) }
    }

    private fun dot(a: DoubleArray, b: DoubleArray): Double {
        var s = 0.0
        for (i in a.indices) s += a[i] * b[i]
        return s
    }

    private companion object {
        const val MAX_BRACKET_S = 0.1
        const val MAX_PENDING = 100
        const val HALVE_ABOVE_HZ = 150.0
        const val RATE_SETTLE = 20
    }
}

/**
 * Maps one sensor's timestamps to seconds since boot (`elapsedRealtimeNanos`). Most phones already use
 * that clock; some use the one that stops in deep sleep, or their own. Decided once per sensor at its
 * first sample, so the stream's own spacing is never disturbed.
 */
class SensorClock {
    private var offsetNs: Long? = null

    /** [note] is non-null when the sensor's clock was not `elapsedRealtimeNanos`. */
    var note: String? = null
        private set

    fun seconds(timestampNs: Long, elapsedRealtimeNs: Long, uptimeNs: Long): Double {
        val off = offsetNs ?: pick(timestampNs, elapsedRealtimeNs, uptimeNs).also { offsetNs = it }
        return (timestampNs + off) * 1e-9
    }

    private fun pick(ts: Long, elapsed: Long, uptime: Long): Long = when {
        abs(elapsed - ts) < TOLERANCE_NS -> 0L
        abs(uptime - ts) < TOLERANCE_NS -> {
            note = "timestamps exclude deep sleep, shifted by ${(elapsed - uptime) / 1_000_000} ms"
            elapsed - uptime
        }
        else -> {
            note = "unknown timestamp clock, aligned to its first sample's arrival"
            elapsed - ts
        }
    }

    private companion object {
        const val TOLERANCE_NS = 500_000_000L
    }
}
