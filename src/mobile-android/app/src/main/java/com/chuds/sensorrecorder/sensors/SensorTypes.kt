package com.chuds.sensorrecorder.sensors

import com.chuds.sensorrecorder.core.ThermalLevel
import com.chuds.sensorrecorder.core.Vec3

// Plain value types for every sensor sample. They carry the *iOS* units, axes and signs, because the
// backend was built on them (dsp.py UA_SIGN): only the adapters in this package know Android's.

/** Device → reference rotation, reference Z up (CoreMotion's `xArbitraryZVertical`). */
data class Quaternion(val w: Double, val x: Double, val y: Double, val z: Double)

data class DeviceMotionSample(
    val t: Double, // seconds since boot
    val userAccel: Vec3, // g
    val gravity: Vec3, // g
    val rotationRate: Vec3, // rad/s
    val quaternion: Quaternion,
    val roll: Double, // rad
    val pitch: Double,
    val yaw: Double,
)

data class Vec3Sample(val t: Double, val v: Vec3)

/** `-1` = invalid for speed, course and every accuracy, as iOS reports it. */
data class LocationSample(
    val utcMs: Double,
    val lat: Double,
    val lon: Double,
    val alt: Double,
    val ellAlt: Double,
    val hAcc: Double,
    val vAcc: Double,
    val speed: Double,
    val speedAcc: Double,
    val course: Double,
    val courseAcc: Double,
    val isSimulated: Boolean?,
)

data class HeadingSample(
    val utcMs: Double,
    val magneticHeading: Double,
    val trueHeading: Double,
    val accuracy: Double,
    val raw: Vec3, // µT
)

data class AltimeterSample(val t: Double, val relativeAltitudeM: Double, val pressureKPa: Double)

data class DeviceStatus(
    val batteryLevel: Float, // 0...1, -1 unknown
    val batteryState: String, // unknown | unplugged | charging | full
    val thermal: ThermalLevel,
    val lowPowerMode: Boolean,
    val freeDiskBytes: Long,
    val networkStatus: String, // satisfied | unsatisfied | unknown
    val networkType: String, // wifi | cellular | wired | other | none
) {
    val isCharging: Boolean get() = batteryState == "charging" || batteryState == "full"

    companion object {
        val UNKNOWN = DeviceStatus(-1f, "unknown", ThermalLevel.NOMINAL, false, -1, "unknown", "none")
    }
}

data class MotionAvailability(val deviceMotion: Boolean, val accel: Boolean, val gyro: Boolean, val mag: Boolean)

class MotionCallbacks(
    val deviceMotion: (DeviceMotionSample) -> Unit = {},
    val accel: (Vec3Sample) -> Unit = {},
    val gyro: (Vec3Sample) -> Unit = {},
    val mag: (Vec3Sample) -> Unit = {},
    val error: (String) -> Unit = {},
)

/** Every source's [stop] guarantees no callback after it returns: writers are closed right after. */
interface MotionSource {
    val availability: MotionAvailability
    val isSynthetic: Boolean

    /** Starts all available motion streams. Callbacks arrive on a background thread. */
    fun start(callbacks: MotionCallbacks)
    fun stop()
}

class LocationCallbacks(
    val location: (LocationSample) -> Unit = {},
    val heading: (HeadingSample) -> Unit = {},
    val error: (String) -> Unit = {},
)

interface LocationSource {
    /** Non-null when location permission was revoked, or location or its precision was turned off. */
    val degradedReason: String? get() = null

    /** Starts continuous high-accuracy updates for recording (in addition to any preflight preview). */
    fun startRecording(callbacks: LocationCallbacks)
    fun stopRecording()
}

interface AltimeterSource {
    val isAvailable: Boolean
    fun start(callback: (AltimeterSample) -> Unit)
    fun stop()
}

interface DeviceStatusSource {
    fun currentStatus(): DeviceStatus
}
