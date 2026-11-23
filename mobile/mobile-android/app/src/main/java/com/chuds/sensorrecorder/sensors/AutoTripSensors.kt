package com.chuds.sensorrecorder.sensors

import android.Manifest
import android.annotation.SuppressLint
import android.content.Context
import android.content.pm.PackageManager
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import android.location.Location
import android.location.LocationListener
import android.location.LocationManager
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import com.chuds.sensorrecorder.core.AppLog
import com.chuds.sensorrecorder.core.LogLevel
import com.chuds.sensorrecorder.core.text

/**
 * What automatic trips (D59) watch, without Play Services: low-power location (network and passive), the
 * step detector, and full-rate GPS once the phone may be in a vehicle. Callbacks on the main thread, with
 * times in seconds since boot; none after the matching stop returns.
 */
class AutoTripSensors(private val context: Context) {
    class Fix(val up: Double, val lat: Double, val lon: Double, val accuracyM: Double, val speed: Double, val isGps: Boolean)

    private val locations = context.getSystemService(LocationManager::class.java)
    private val sensors = context.getSystemService(SensorManager::class.java)
    private val main = Handler(Looper.getMainLooper())

    var onFix: ((Fix) -> Unit)? = null
    var onStep: ((Double) -> Unit)? = null

    private var watching = false
    private var gpsOn = false

    /** Latest GPS fix and its time, for the warm-up's GPS check. */
    var latestGps: Pair<LocationSample, Double>? = null
        private set

    val hasStepDetector: Boolean get() = sensors.getDefaultSensor(Sensor.TYPE_STEP_DETECTOR) != null

    private fun granted(p: String) = context.checkSelfPermission(p) == PackageManager.PERMISSION_GRANTED

    @SuppressLint("MissingPermission")
    fun startWatching() {
        if (watching) return
        watching = true
        try {
            if (granted(Manifest.permission.ACCESS_FINE_LOCATION) || granted(Manifest.permission.ACCESS_COARSE_LOCATION)) {
                for (p in listOf(LocationManager.NETWORK_PROVIDER, LocationManager.PASSIVE_PROVIDER)) {
                    if (p == LocationManager.PASSIVE_PROVIDER || locations.isProviderEnabled(p)) {
                        locations.requestLocationUpdates(p, LOW_POWER_INTERVAL_MS, 0f, coarse, Looper.getMainLooper())
                    }
                }
            }
        } catch (e: Exception) {
            AppLog.log(LogLevel.WARN, "auto start: low-power location not started: ${e.text}")
        }
        val step = sensors.getDefaultSensor(Sensor.TYPE_STEP_DETECTOR)
        if (step != null && granted(Manifest.permission.ACTIVITY_RECOGNITION)) {
            // Non-wake-up: steps taken while the phone sleeps arrive batched, with their own timestamps.
            sensors.registerListener(stepListener, step, SensorManager.SENSOR_DELAY_NORMAL, STEP_LATENCY_US, main)
        }
    }

    fun stopWatching() {
        stopGps()
        if (!watching) return
        watching = false
        locations.removeUpdates(coarse)
        sensors.unregisterListener(stepListener)
    }

    // GPS only for the speed: a network fix's speed is a guess.
    @SuppressLint("MissingPermission")
    fun startGps() {
        if (gpsOn || !granted(Manifest.permission.ACCESS_FINE_LOCATION)) return
        try {
            locations.requestLocationUpdates(LocationManager.GPS_PROVIDER, GPS_INTERVAL_MS, 0f, gps, Looper.getMainLooper())
            gpsOn = true
        } catch (e: Exception) {
            AppLog.log(LogLevel.WARN, "auto start: GPS not started: ${e.text}")
        }
    }

    fun stopGps() {
        if (!gpsOn) return
        gpsOn = false
        latestGps = null
        locations.removeUpdates(gps)
    }

    private fun fix(loc: Location, isGps: Boolean) = Fix(
        up = loc.elapsedRealtimeNanos * 1e-9, lat = loc.latitude, lon = loc.longitude,
        accuracyM = if (loc.hasAccuracy()) loc.accuracy.toDouble() else -1.0,
        speed = if (loc.hasSpeed()) loc.speed.toDouble() else -1.0, isGps = isGps,
    )

    private val coarse = object : LocationListener {
        override fun onLocationChanged(loc: Location) {
            if (!watching) return
            // The passive provider also brings other apps' GPS fixes: those have a real speed.
            onFix?.invoke(fix(loc, isGps = loc.provider == LocationManager.GPS_PROVIDER))
        }

        override fun onProviderEnabled(provider: String) {}
        override fun onProviderDisabled(provider: String) {}

        @Deprecated("Called on Android 9 only")
        override fun onStatusChanged(provider: String?, status: Int, extras: Bundle?) {}
    }

    private val gps = object : LocationListener {
        override fun onLocationChanged(loc: Location) {
            if (!gpsOn) return
            val f = fix(loc, isGps = true)
            if (loc.hasAccuracy()) {
                latestGps = LocationSample(
                    loc.time.toDouble(), loc.latitude, loc.longitude, Double.NaN, loc.altitude, loc.accuracy.toDouble(),
                    -1.0, f.speed, -1.0, -1.0, -1.0, null,
                ) to f.up
            }
            onFix?.invoke(f)
        }

        override fun onProviderEnabled(provider: String) {}
        override fun onProviderDisabled(provider: String) {}

        @Deprecated("Called on Android 9 only")
        override fun onStatusChanged(provider: String?, status: Int, extras: Bundle?) {}
    }

    private val stepListener = object : SensorEventListener {
        override fun onSensorChanged(e: SensorEvent) {
            if (!watching) return
            val now = SystemClock.elapsedRealtimeNanos() * 1e-9
            val t = e.timestamp * 1e-9
            // Some sensors stamp on another clock (README): then the arrival time is the better guess.
            onStep?.invoke(if (t > now || now - t > 600) now else t)
        }

        override fun onAccuracyChanged(s: Sensor?, accuracy: Int) {}
    }

    private companion object {
        const val LOW_POWER_INTERVAL_MS = 20_000L
        const val GPS_INTERVAL_MS = 1000L
        const val STEP_LATENCY_US = 10_000_000
    }
}
