package com.chuds.sensorrecorder

import com.chuds.sensorrecorder.core.Vec3
import com.chuds.sensorrecorder.sensors.DeviceMotionSample
import com.chuds.sensorrecorder.sensors.IosFrame
import com.chuds.sensorrecorder.sensors.MotionFusion
import com.chuds.sensorrecorder.sensors.Nmea
import com.chuds.sensorrecorder.sensors.Quaternion
import com.chuds.sensorrecorder.sensors.SensorClock
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.PI
import kotlin.math.cos
import kotlin.math.sin

/**
 * The signs the backend was built on (dsp.py UA_SIGN): with one flipped, the learned forward axis points
 * backwards and no speed bump is ever detected.
 */
class MotionFusionTest {
    private val g = 9.80665
    private val flat = Quaternion(1.0, 0.0, 0.0, 0.0)
    private val out = ArrayList<DeviceMotionSample>()
    private val fusion = MotionFusion { out.add(it) }

    private fun assertVec(x: Double, y: Double, z: Double, v: Vec3, eps: Double = 1e-9) {
        assertEquals(x, v.x, eps)
        assertEquals(y, v.y, eps)
        assertEquals(z, v.z, eps)
    }

    /** Feeds one second of constant readings: accelerometer in Android's m/s². */
    private fun feed(ax: Double, ay: Double, az: Double, q: Quaternion, hz: Int = 100, gyro: Vec3 = Vec3.ZERO) {
        for (i in 0 until hz) {
            val t = 10 + i / hz.toDouble()
            fusion.addRotation(t, q)
            fusion.addGyro(t, gyro.x, gyro.y, gyro.z)
            fusion.addAccel(t, IosFrame.accel(ax, ay, az))
        }
    }

    @Test fun flatAndStillReadsMinusOneGOnZ() {
        feed(0.0, 0.0, g, flat)
        assertVec(0.0, 0.0, -1.0, out.last().gravity)
        assertVec(0.0, 0.0, 0.0, out.last().userAccel)
        assertVec(0.0, 0.0, -1.0, IosFrame.accel(0.0, 0.0, g))
    }

    /** CoreMotion's userAcceleration is minus the phone's acceleration: +1 g on z in free fall. */
    @Test fun signsAreCoreMotions() {
        feed(0.0, 0.0, 0.0, flat)
        assertVec(0.0, 0.0, 1.0, out.last().userAccel)
        out.clear()
        feed(0.0, 3.0, g + 2.0, flat) // the phone accelerates forward (+y) and up
        assertVec(0.0, -3.0 / g, -2.0 / g, out.last().userAccel)
    }

    @Test fun gravityHasUnitLengthWhateverTheAccelerometerReads() {
        val q = Quaternion(0.8, 0.2, -0.4, 0.4) // not normalized
        feed(4.0, -7.0, 15.0, q)
        for (s in out) assertEquals(1.0, s.gravity.norm, 1e-12)
    }

    /** gravity.y = −sin pitch, gravity.x = cos pitch · sin roll (CoreMotion's attitude convention). */
    @Test fun attitudeAnglesMatchCoreMotion() {
        val pitch = 0.3
        val roll = -0.7
        val yaw = 1.1
        fun rot(a: Double, x: Double, y: Double, z: Double) = Quaternion(cos(a / 2), x * sin(a / 2), y * sin(a / 2), z * sin(a / 2))
        fun mul(a: Quaternion, b: Quaternion) = Quaternion(
            a.w * b.w - a.x * b.x - a.y * b.y - a.z * b.z, a.w * b.x + a.x * b.w + a.y * b.z - a.z * b.y,
            a.w * b.y - a.x * b.z + a.y * b.w + a.z * b.x, a.w * b.z + a.x * b.y - a.y * b.x + a.z * b.w,
        )
        val q = mul(mul(rot(yaw, 0.0, 0.0, 1.0), rot(pitch, 1.0, 0.0, 0.0)), rot(roll, 0.0, 1.0, 0.0))
        assertEquals(listOf(pitch, roll, yaw).toString(), listOf(IosFrame.pitch(q), IosFrame.roll(q), IosFrame.yaw(q)).map { Math.round(it * 1e9) / 1e9 }.toString())
        assertVec(cos(pitch) * sin(roll), -sin(pitch), -cos(pitch) * cos(roll), IosFrame.gravity(q))
        // The phone held upright (Android: +g on y) is pitched by +90°.
        val up = rot(PI / 2, 1.0, 0.0, 0.0)
        feed(0.0, g, 0.0, up)
        assertVec(0.0, 0.0, 0.0, out.last().userAccel)
    }

    @Test fun rotationAndGyroAreInterpolatedToTheAccelerometersTime() {
        for (i in 0..10) {
            fusion.addGyro(i * 0.01, i.toDouble(), 0.0, 0.0)
            fusion.addRotation(i * 0.01 + 0.003, if (i % 2 == 0) flat else Quaternion(-1.0, 0.0, 0.0, 0.0)) // the same rotation
        }
        fusion.addAccel(0.0525, IosFrame.accel(0.0, 0.0, g))
        assertEquals(5.25, out.single().rotationRate.x, 1e-9)
        assertEquals(0.0525, out.single().t, 0.0)
        assertVec(0.0, 0.0, -1.0, out.single().gravity)
    }

    @Test fun nothingIsInterpolatedAcrossAGap() {
        for (t in listOf(0.0, 0.01, 0.5, 0.51)) fusion.addGyro(t, 0.0, 0.0, 0.0)
        for (i in 0..51) fusion.addRotation(i * 0.01, flat)
        fusion.addAccel(0.25, IosFrame.accel(0.0, 0.0, g)) // in the gyro's gap
        fusion.addAccel(0.505, IosFrame.accel(0.0, 0.0, g))
        assertEquals(listOf(0.505), out.map { it.t })
    }

    @Test fun aFastAccelerometerIsHalvedAndA104HzOneIsNot() {
        feed(0.0, 0.0, g, flat, hz = 200)
        assertTrue("${out.size}", out.size in 100..115)
        out.clear()
        val second = MotionFusion { out.add(it) }
        for (i in 0 until 104) {
            val t = 10 + i / 104.0
            second.addRotation(t, flat)
            second.addGyro(t, 0.0, 0.0, 0.0)
            second.addAccel(t, IosFrame.accel(0.0, 0.0, g))
        }
        assertEquals(104, out.size)
        assertTrue(out.zipWithNext().all { (a, b) -> b.t > a.t })
    }
}

class SensorClockTest {
    private val elapsed = 5_000_000_000_000L
    private val uptime = 3_000_000_000_000L

    @Test fun elapsedRealtimeIsUsedAsIs() {
        val c = SensorClock()
        assertEquals(4999.99, c.seconds(elapsed - 10_000_000, elapsed, uptime), 1e-9)
        assertNull(c.note)
    }

    @Test fun otherClocksAreShiftedOnceAndKeepTheirSpacing() {
        for (own in listOf(uptime, 77_000_000_000L)) {
            val c = SensorClock()
            assertEquals(5000.0, c.seconds(own, elapsed, uptime), 0.001)
            assertNotNull(c.note)
            // The next arrival is late by 300 ms; the sample's own spacing (10 ms) is what counts.
            assertEquals(5000.01, c.seconds(own + 10_000_000, elapsed + 310_000_000, uptime + 310_000_000), 0.001)
        }
    }
}

class NmeaTest {
    @Test fun geoidSeparation() {
        assertEquals(38.2, Nmea.geoidSeparation("\$GPGGA,091532.00,4646.27,N,02337.41,E,1,08,0.9,352.1,M,38.2,M,,*47")!!, 0.0)
        assertEquals(-30.5, Nmea.geoidSeparation("\$GNGGA,091532.00,4646.27,N,02337.41,E,1,08,0.9,352.1,M,-30.5,M,,*47")!!, 0.0)
        for (s in listOf("", "\$GPGGA", "\$GPRMC,091532.00,A", "\$GPGGA,091532.00,,,,,0,,,,M,,M,,*5C")) assertNull(s, Nmea.geoidSeparation(s))
    }
}
