package com.chuds.sensorrecorder.sensors

import android.content.Context
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import android.os.Handler
import android.os.HandlerThread
import android.os.Process
import android.os.SystemClock
import com.chuds.sensorrecorder.core.ClockSource
import com.chuds.sensorrecorder.core.Vec3

object AndroidClock : ClockSource {
    override fun uptime(): Double = SystemClock.elapsedRealtimeNanos() * 1e-9
    override fun nowUtcMs(): Double = System.currentTimeMillis().toDouble()
}

/**
 * Listens to a set of sensors on one thread. [stop] returns only once no callback can run any more
 * (the running flag is checked and cleared under the lock the callbacks hold).
 */
private class SensorThread(context: Context, private val name: String) {
    private val manager = context.getSystemService(SensorManager::class.java)
    private val lock = Any()
    private var listener: SensorEventListener? = null
    private var thread: HandlerThread? = null

    fun has(type: Int) = manager.getDefaultSensor(type) != null

    /** Returns the sensor types that could not be started. */
    fun start(periods: Map<Int, Int>, onEvent: (SensorEvent) -> Unit): List<Int> {
        stop()
        val t = HandlerThread(name, Process.THREAD_PRIORITY_URGENT_DISPLAY).also { it.start() }
        val l = object : SensorEventListener {
            override fun onSensorChanged(e: SensorEvent) = synchronized(lock) { if (listener === this) onEvent(e) }
            override fun onAccuracyChanged(s: Sensor?, accuracy: Int) {}
        }
        synchronized(lock) {
            listener = l
            thread = t
        }
        val handler = Handler(t.looper)
        return periods.filter { (type, periodUs) ->
            val sensor = manager.getDefaultSensor(type)
            // maxReportLatency 0: no hardware batching, samples arrive as they are measured.
            sensor == null || !manager.registerListener(l, sensor, periodUs, 0, handler)
        }.keys.toList()
    }

    fun stop() {
        val (l, t) = synchronized(lock) {
            val old = listener to thread
            listener = null
            thread = null
            old
        }
        if (l != null) manager.unregisterListener(l)
        t?.quitSafely()
    }
}

/**
 * Motion streams M1–M4 at the iOS app's rates. Raw gyro and magnetometer use the *uncalibrated* sensors
 * (CoreMotion's raw streams include the sensor bias too); deviceMotion is built by [MotionFusion].
 */
class AndroidMotionSource(context: Context) : MotionSource {
    private val sensors = SensorThread(context, "sensorrecorder.motion")
    private val rawGyro =
        if (sensors.has(Sensor.TYPE_GYROSCOPE_UNCALIBRATED)) Sensor.TYPE_GYROSCOPE_UNCALIBRATED else Sensor.TYPE_GYROSCOPE
    private val rawMag =
        if (sensors.has(Sensor.TYPE_MAGNETIC_FIELD_UNCALIBRATED)) Sensor.TYPE_MAGNETIC_FIELD_UNCALIBRATED
        else Sensor.TYPE_MAGNETIC_FIELD

    override val isSynthetic = false

    override val availability: MotionAvailability
        get() {
            val accel = sensors.has(Sensor.TYPE_ACCELEROMETER)
            val gyro = sensors.has(Sensor.TYPE_GYROSCOPE)
            return MotionAvailability(
                deviceMotion = accel && gyro && sensors.has(Sensor.TYPE_GAME_ROTATION_VECTOR),
                accel = accel, gyro = sensors.has(rawGyro), mag = sensors.has(rawMag),
            )
        }

    override fun start(callbacks: MotionCallbacks) {
        val a = availability
        val fusion = MotionFusion(callbacks.deviceMotion)
        val clocks = HashMap<Int, SensorClock>()
        val periods = buildMap {
            if (a.accel) put(Sensor.TYPE_ACCELEROMETER, MOTION_PERIOD_US)
            if (a.gyro) put(rawGyro, MOTION_PERIOD_US)
            if (a.mag) put(rawMag, MAG_PERIOD_US)
            if (a.deviceMotion) {
                put(Sensor.TYPE_GYROSCOPE, MOTION_PERIOD_US)
                // Not a magnetometer-based rotation: car metal makes magnetic yaw correction unreliable.
                put(Sensor.TYPE_GAME_ROTATION_VECTOR, MOTION_PERIOD_US)
            }
        }
        val failed = sensors.start(periods) { e ->
            val type = e.sensor.type
            val clock = clocks.getOrPut(type) { SensorClock() }
            val first = clock.note
            val t = clock.seconds(e.timestamp, SystemClock.elapsedRealtimeNanos(), System.nanoTime())
            if (first == null) clock.note?.let { callbacks.error("sensor ${e.sensor.name}: $it") }
            val x = e.values[0].toDouble()
            val y = e.values[1].toDouble()
            val z = e.values[2].toDouble()
            if (type == Sensor.TYPE_ACCELEROMETER) {
                val v = IosFrame.accel(x, y, z)
                callbacks.accel(Vec3Sample(t, v))
                if (a.deviceMotion) fusion.addAccel(t, v)
            }
            if (type == rawGyro) callbacks.gyro(Vec3Sample(t, Vec3(x, y, z)))
            if (type == Sensor.TYPE_GYROSCOPE && a.deviceMotion) fusion.addGyro(t, x, y, z)
            if (type == rawMag) callbacks.mag(Vec3Sample(t, Vec3(x, y, z)))
            if (type == Sensor.TYPE_GAME_ROTATION_VECTOR) {
                val q = FloatArray(4)
                SensorManager.getQuaternionFromVector(q, e.values)
                fusion.addRotation(t, Quaternion(q[0].toDouble(), q[1].toDouble(), q[2].toDouble(), q[3].toDouble()))
            }
        }
        for (type in failed) callbacks.error("motion sensor type $type could not be started")
    }

    override fun stop() = sensors.stop()

    private companion object {
        const val MOTION_PERIOD_US = 10_000 // 100 Hz
        const val MAG_PERIOD_US = 20_000 // 50 Hz
    }
}

/**
 * Barometer (B1), thinned to CMAltimeter's once a second (the rate the backend expects). Relative
 * altitude is 0 at the first sample, like `startRelativeAltitudeUpdates`.
 */
class AndroidAltimeterSource(context: Context) : AltimeterSource {
    private val sensors = SensorThread(context, "sensorrecorder.altimeter")

    override val isAvailable: Boolean get() = sensors.has(Sensor.TYPE_PRESSURE)

    override fun start(callback: (AltimeterSample) -> Unit) {
        val clock = SensorClock()
        var reference: Float? = null
        var lastT = Double.NEGATIVE_INFINITY
        sensors.start(mapOf(Sensor.TYPE_PRESSURE to PERIOD_US)) { e ->
            val t = clock.seconds(e.timestamp, SystemClock.elapsedRealtimeNanos(), System.nanoTime())
            if (t - lastT >= MIN_SPACING_S) {
                lastT = t
                val hPa = e.values[0]
                val altitude = SensorManager.getAltitude(SensorManager.PRESSURE_STANDARD_ATMOSPHERE, hPa)
                val ref = reference ?: altitude.also { reference = it }
                callback(AltimeterSample(t, (altitude - ref).toDouble(), hPa / 10.0))
            }
        }
    }

    override fun stop() = sensors.stop()

    private companion object {
        const val PERIOD_US = 200_000
        const val MIN_SPACING_S = 0.95
    }
}
