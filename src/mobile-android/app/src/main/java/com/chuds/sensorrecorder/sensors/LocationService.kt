package com.chuds.sensorrecorder.sensors

import android.Manifest
import android.annotation.SuppressLint
import android.content.Context
import android.content.pm.PackageManager
import android.hardware.GeomagneticField
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import android.location.Location
import android.location.LocationListener
import android.location.LocationManager
import android.location.LocationRequest
import android.location.OnNmeaMessageListener
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import com.chuds.sensorrecorder.core.Vec3
import com.chuds.sensorrecorder.core.text

/**
 * GPS and heading, for both the preflight check (live fix / permission state) and the recorder.
 * Everything here runs on the main thread, as in the iOS app: at ~1 Hz with a cheap append it costs
 * nothing, and no callback can arrive after [stopRecording] returns.
 */
class LocationService(private val context: Context) : LocationSource {
    private val manager = context.getSystemService(LocationManager::class.java)
    private val sensors = context.getSystemService(SensorManager::class.java)
    private val main = Handler(Looper.getMainLooper())

    private var callbacks: LocationCallbacks? = null
    private var previewActive = false
    private var updating = false
    private var headingActive = false

    /** Last valid fix and when it was measured (seconds since boot). */
    var latest: LocationSample? = null
        private set
    var latestFixUptime: Double? = null
        private set
    private var latestRaw: Location? = null

    /** Height of the geoid above the ellipsoid, from the GPS chip's NMEA. */
    private var geoidSeparationM: Double? = null

    private fun granted(p: String) = context.checkSelfPermission(p) == PackageManager.PERMISSION_GRANTED

    val hasPermission: Boolean
        get() = granted(Manifest.permission.ACCESS_FINE_LOCATION) || granted(Manifest.permission.ACCESS_COARSE_LOCATION)
    val isLocationOn: Boolean get() = manager.isLocationEnabled
    val isAuthorized: Boolean get() = hasPermission && isLocationOn
    val isFullAccuracy: Boolean get() = granted(Manifest.permission.ACCESS_FINE_LOCATION)

    /** While recording: why location data is degraded (a PROBLEM in the status line). */
    override val degradedReason: String?
        get() = when {
            callbacks == null -> null
            !hasPermission -> "Location permission revoked: Settings → Apps → Bumpy → Permissions"
            !isLocationOn -> "Location is turned off: turn it on in Settings"
            !isFullAccuracy -> "Precise location is OFF: GPS is approximate"
            else -> null
        }

    /** Live updates for the preflight GPS check. */
    fun startPreview() {
        previewActive = true
        startUpdates()
    }

    fun stopPreview() {
        previewActive = false
        if (callbacks == null) stopUpdates()
    }

    /** Permission or location may have been switched on in Settings while updates were wanted. */
    fun refresh() {
        if (previewActive || callbacks != null) startUpdates()
    }

    override fun startRecording(callbacks: LocationCallbacks) {
        this.callbacks = callbacks
        startUpdates()
        startHeading()
    }

    override fun stopRecording() {
        callbacks = null
        stopHeading()
        if (!previewActive) stopUpdates()
    }

    // GPS only, not the fused provider: a network fix (± 50 m) must never pass as a road position.
    @SuppressLint("MissingPermission")
    private fun startUpdates() {
        if (updating || !isFullAccuracy) return
        try {
            if (Build.VERSION.SDK_INT >= 31) {
                val request = LocationRequest.Builder(INTERVAL_MS)
                    .setQuality(LocationRequest.QUALITY_HIGH_ACCURACY)
                    .setMinUpdateIntervalMillis(INTERVAL_MS / 2) // a fix a few ms early is not dropped
                    .build()
                manager.requestLocationUpdates(LocationManager.GPS_PROVIDER, request, context.mainExecutor, listener)
            } else {
                manager.requestLocationUpdates(LocationManager.GPS_PROVIDER, INTERVAL_MS, 0f, listener, Looper.getMainLooper())
            }
            updating = true
            manager.addNmeaListener(nmea, main)
        } catch (e: Exception) { // SecurityException, or no GPS on this phone
            callbacks?.error?.invoke("location: ${e.text}")
        }
    }

    private fun stopUpdates() {
        if (!updating) return
        updating = false
        manager.removeUpdates(listener)
        manager.removeNmeaListener(nmea)
    }

    private val listener = object : LocationListener {
        override fun onLocationChanged(loc: Location) {
            if (!updating) return
            val s = sample(loc)
            callbacks?.location?.invoke(s)
            if (s.hAcc >= 0) {
                latest = s
                latestRaw = loc
                latestFixUptime = loc.elapsedRealtimeNanos * 1e-9
            }
        }

        override fun onProviderDisabled(provider: String) {
            callbacks?.error?.invoke("location turned off")
        }

        override fun onProviderEnabled(provider: String) {
            callbacks?.error?.invoke("location turned on")
        }

        @Deprecated("Called on Android 9 only")
        override fun onStatusChanged(provider: String?, status: Int, extras: Bundle?) {}
    }

    private val nmea = OnNmeaMessageListener { message, _ ->
        Nmea.geoidSeparation(message)?.let { geoidSeparationM = it }
    }

    private fun sample(loc: Location): LocationSample {
        // The fix's age on the phone's monotonic clock, put on the phone's wall clock: GPS time itself
        // can differ from the wall clock by seconds, which would shift fixes against the motion samples.
        val ageMs = (SystemClock.elapsedRealtimeNanos() - loc.elapsedRealtimeNanos) / 1e6
        val ellipsoidal = if (loc.hasAltitude()) loc.altitude else Double.NaN
        val msl = when {
            Build.VERSION.SDK_INT >= 34 && loc.hasMslAltitude() -> loc.mslAltitudeMeters
            else -> geoidSeparationM?.let { ellipsoidal - it } ?: Double.NaN
        }
        return LocationSample(
            utcMs = System.currentTimeMillis() - ageMs,
            lat = loc.latitude, lon = loc.longitude, alt = msl, ellAlt = ellipsoidal,
            hAcc = if (loc.hasAccuracy()) loc.accuracy.toDouble() else -1.0,
            vAcc = if (loc.hasVerticalAccuracy()) loc.verticalAccuracyMeters.toDouble() else -1.0,
            speed = if (loc.hasSpeed()) loc.speed.toDouble() else -1.0,
            speedAcc = if (loc.hasSpeedAccuracy()) loc.speedAccuracyMetersPerSecond.toDouble() else -1.0,
            course = if (loc.hasBearing()) loc.bearing.toDouble() else -1.0,
            courseAcc = if (loc.hasBearingAccuracy()) loc.bearingAccuracyDegrees.toDouble() else -1.0,
            isSimulated = if (Build.VERSION.SDK_INT >= 31) loc.isMock else @Suppress("DEPRECATION") loc.isFromMockProvider,
        )
    }

    // MARK: Heading (L2)

    private fun startHeading() {
        if (headingActive) return
        val rotation = sensors.getDefaultSensor(Sensor.TYPE_ROTATION_VECTOR) ?: return
        val field = sensors.getDefaultSensor(Sensor.TYPE_MAGNETIC_FIELD) ?: return
        headingActive = true
        sensors.registerListener(headingListener, field, HEADING_PERIOD_US, main)
        sensors.registerListener(headingListener, rotation, HEADING_PERIOD_US, main)
    }

    private fun stopHeading() {
        if (!headingActive) return
        headingActive = false
        sensors.unregisterListener(headingListener)
    }

    private val headingListener = object : SensorEventListener {
        private var field: Vec3? = null
        private var lastUp = 0.0
        private val matrix = FloatArray(9)
        private val angles = FloatArray(3)

        override fun onSensorChanged(e: SensorEvent) {
            if (!headingActive) return
            if (e.sensor.type == Sensor.TYPE_MAGNETIC_FIELD) {
                field = Vec3(e.values[0].toDouble(), e.values[1].toDouble(), e.values[2].toDouble())
                return
            }
            val raw = field ?: return
            val up = SystemClock.elapsedRealtimeNanos() * 1e-9
            if (up - lastUp < HEADING_MIN_SPACING_S) return // Android may deliver faster than asked
            lastUp = up
            SensorManager.getRotationMatrixFromVector(matrix, e.values)
            SensorManager.getOrientation(matrix, angles)
            val magnetic = (Math.toDegrees(angles[0].toDouble()) + 360) % 360
            val declination = latestRaw?.let {
                GeomagneticField(it.latitude.toFloat(), it.longitude.toFloat(), it.altitude.toFloat(), it.time).declination
            }
            val accuracy = if (e.values.size > 4 && e.values[4] >= 0) Math.toDegrees(e.values[4].toDouble()) else -1.0
            callbacks?.heading?.invoke(
                HeadingSample(
                    utcMs = System.currentTimeMillis().toDouble(),
                    magneticHeading = magnetic,
                    trueHeading = declination?.let { (magnetic + it + 360) % 360 } ?: -1.0,
                    accuracy = accuracy, raw = raw,
                ),
            )
        }

        override fun onAccuracyChanged(s: Sensor?, accuracy: Int) {}
    }

    private companion object {
        const val INTERVAL_MS = 1000L
        const val HEADING_PERIOD_US = 100_000
        const val HEADING_MIN_SPACING_S = 0.095
    }
}

object Nmea {
    /** Geoid separation in metres from a GGA sentence, or null. */
    fun geoidSeparation(sentence: String): Double? {
        if (sentence.length < 6 || !sentence.startsWith("$") || sentence.substring(3, 6) != "GGA") return null
        val f = sentence.substringBefore('*').split(',')
        return if (f.size > 12 && f[12] == "M") f[11].toDoubleOrNull()?.takeIf { it.isFinite() } else null
    }
}
