package com.chuds.sensorrecorder.recording

import android.Manifest
import android.os.Build
import android.os.SystemClock
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.chuds.sensorrecorder.app.AppModel
import com.chuds.sensorrecorder.core.ByteFormat
import com.chuds.sensorrecorder.core.ISO8601
import com.chuds.sensorrecorder.core.SessionMetadata
import com.chuds.sensorrecorder.core.StreamId
import com.chuds.sensorrecorder.core.ThermalLevel
import com.chuds.sensorrecorder.core.Vec3
import com.chuds.sensorrecorder.sensors.MotionCallbacks
import com.chuds.sensorrecorder.sensors.Vec3Sample
import com.chuds.sensorrecorder.upload.UploadQueue
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.util.Locale
import kotlin.math.max
import kotlin.math.sqrt

/** Pure analysis of the preflight motion capture (rates + mount stillness). */
object MotionTestAnalysis {
    class Result(val rates: Map<StreamId, Double>, val accelMean: Vec3, val accelStd: Vec3, val gravityMean: Vec3?) {
        val maxStd: Double get() = max(accelStd.x, max(accelStd.y, accelStd.z))
    }

    fun rate(t: List<Double>): Double = if (t.size < 2 || t.last() <= t.first()) 0.0 else (t.size - 1) / (t.last() - t.first())

    fun analyze(dmTimes: List<Double>, gravity: List<Vec3>, accel: List<Vec3Sample>, gyroTimes: List<Double>, magTimes: List<Double>): Result {
        val n = max(1, accel.size).toDouble()
        val mean = accel.fold(Vec3.ZERO) { a, s -> a + s.v } * (1 / n)
        val sq = accel.fold(Vec3.ZERO) { a, s ->
            val d = s.v - mean
            a + Vec3(d.x * d.x, d.y * d.y, d.z * d.z)
        }
        return Result(
            mapOf(
                StreamId.DEVICE_MOTION to rate(dmTimes), StreamId.ACCEL to rate(accel.map { it.t }),
                StreamId.GYRO to rate(gyroTimes), StreamId.MAG to rate(magTimes),
            ),
            mean, Vec3(sqrt(sq.x / n), sqrt(sq.y / n), sqrt(sq.z / n)),
            if (gravity.isEmpty()) null else gravity.fold(Vec3.ZERO) { a, g -> a + g } * (1.0 / gravity.size),
        )
    }
}

/**
 * The preflight checklist (spec §7): blocks Start until required checks pass, with an explicit override.
 * Main thread only. The check IDs are the iOS app's (they go into `session.json`).
 */
class PreflightModel(private val app: AppModel) {
    enum class Status(val id: String) {
        PENDING("pending"), RUNNING("running"), PASS("pass"), WARN("warn"), FAIL("fail"), INFO("info")
    }

    data class Check(
        val id: String,
        val title: String,
        val required: Boolean,
        val status: Status = Status.PENDING,
        val detail: String = "",
    )

    var checks by mutableStateOf(
        listOf(
            Check("perm.motion", "Motion permission", true),
            Check("perm.location", "Location: authorized + precise", true),
            Check("avail.motion", "Device motion / accel / gyro", true),
            // Not required on Android: many phones have no barometer, and nothing is computed from it.
            Check("avail.baro", "Barometer available", false),
            Check("gps.fix", "GPS fix ≤ 10 m", true),
            Check("motion.rate", "Motion rate ≥ 90 Hz", true),
            // A hand-held phone can't pass a stillness test; the backend excludes such sessions anyway.
            Check("motion.still", "Mount stillness (5 s, vehicle stopped)", !app.setup.mount.handheld),
            Check("dev.lpm", "Battery Saver off", true),
            Check("dev.battery", "Battery ≥ 50 % or charging", true),
            Check("dev.thermal", "Thermal nominal / fair", true),
            Check("dev.disk", "Free disk ≥ 2 GB", true),
            Check("upload", "Upload test (warning only)", false),
        ),
    )
        private set
    private var running by mutableStateOf(false)
    private var motionTestRunning by mutableStateOf(false)
    private var motionResult: MotionTestAnalysis.Result? = null

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private var liveJob: Job? = null
    private var runJob: Job? = null
    private var motionJob: Job? = null

    /**
     * Uptime when GPS last met ≤ 10 m; the check then stays green unless the fix degrades a lot, so START
     * and the override don't swap under the operator's finger on marginal accuracy.
     */
    private var gpsPassedAtUp: Double? = null

    /** True while any check is still running: Start must wait. */
    val busy: Boolean get() = running || motionTestRunning
    val allRequiredPass: Boolean get() = failingRequired.isEmpty()
    val failingRequired: List<Check> get() = checks.filter { it.required && it.status != Status.PASS }

    private fun set(id: String, status: Status, detail: String) {
        checks = checks.map { if (it.id == id) it.copy(status = status, detail = detail) else it }
    }

    fun onAppear() {
        app.location.startPreview()
        liveJob?.cancel()
        liveJob = scope.launch {
            while (isActive) {
                delay(500)
                updateGps()
                updateDeviceChecks()
            }
        }
        if (!running && checks.all { it.status == Status.PENDING }) runJob = scope.launch { runAll() }
    }

    fun onDisappear() {
        liveJob?.cancel()
        if (app.recording == null) app.location.stopPreview() // battery/heat between sessions
        runJob?.cancel() // stops permission waits and an in-flight motion test
        motionJob?.cancel()
    }

    private suspend fun runAll() {
        if (running) return
        running = true
        try {
            checkPermissions()
            checkAvailability()
            updateDeviceChecks()
            updateGps()
            coroutineScope {
                val upload = async { checkUpload() }
                runMotionTest()
                upload.await()
            }
        } finally {
            running = false
        }
    }

    private suspend fun checkPermissions() {
        // Android has no permission for the motion sensors; the check stays for the same session.json record.
        set("perm.motion", Status.PASS, "not needed on Android")
        set("perm.location", Status.RUNNING, "requesting…")
        if (!app.location.isFullAccuracy) {
            app.requestPermissions(
                buildList {
                    add(Manifest.permission.ACCESS_FINE_LOCATION)
                    add(Manifest.permission.ACCESS_COARSE_LOCATION)
                    // Only so the "recording" notification is visible; recording works without it.
                    if (Build.VERSION.SDK_INT >= 33) add(Manifest.permission.POST_NOTIFICATIONS)
                },
            )
        }
        updateLocationPermission()
        app.location.startPreview()
    }

    private fun updateLocationPermission() {
        val loc = app.location
        when {
            !loc.hasPermission -> set("perm.location", Status.FAIL, "denied: Settings → Apps → Bumpy → Permissions")
            !loc.isLocationOn -> set("perm.location", Status.FAIL, "location is turned off in Settings")
            !loc.isFullAccuracy -> set("perm.location", Status.FAIL, "Precise location is OFF: Settings → Apps → Bumpy → Permissions")
            else -> set("perm.location", Status.PASS, "when in use, precise")
        }
    }

    private fun checkAvailability() {
        val a = app.makeMotionSource().availability
        fun mark(b: Boolean) = if (b) "✓" else "✗"
        set(
            "avail.motion", if (a.deviceMotion && a.accel && a.gyro) Status.PASS else Status.FAIL,
            "dm ${mark(a.deviceMotion)} · accel ${mark(a.accel)} · gyro ${mark(a.gyro)} · mag ${mark(a.mag)}",
        )
        if (app.makeAltimeterSource().isAvailable) set("avail.baro", Status.PASS, "relative")
        else set("avail.baro", Status.WARN, "not available on this device")
    }

    private fun updateGps() {
        // Keep the permission row live (the user may flip it in Settings and come back).
        val perm = checks.first { it.id == "perm.location" }.status
        if (perm != Status.PENDING && perm != Status.RUNNING) updateLocationPermission()
        if (!app.location.isAuthorized) {
            set("gps.fix", Status.FAIL, "no location permission")
            return
        }
        val fix = app.location.latest
        val at = app.location.latestFixUptime
        if (fix == null || at == null) {
            set("gps.fix", Status.RUNNING, "waiting for fix…")
            return
        }
        val now = SystemClock.elapsedRealtimeNanos() * 1e-9
        val age = now - at
        val acc = fix.hAcc
        val detail = String.format(Locale.US, "hAcc %.1f m · %.0f s ago", acc, age)
        val good = acc in 0.0..GPS_MAX_ACCURACY_M && age < 5
        if (good) gpsPassedAtUp = now
        // Hysteresis: once passed, stay green while the fix is still reasonable (≤ 20 m, < 30 s old).
        val stillOk = gpsPassedAtUp != null && acc in 0.0..GPS_KEEP_ACCURACY_M && age < 30
        if (good || stillOk) {
            set("gps.fix", Status.PASS, detail)
        } else {
            gpsPassedAtUp = null
            set("gps.fix", Status.RUNNING, "$detail (need ≤ 10 m; go outside / wait)")
        }
    }

    private fun updateDeviceChecks() {
        val d = app.deviceMonitor.currentStatus()
        set("dev.lpm", if (d.lowPowerMode) Status.FAIL else Status.PASS, if (d.lowPowerMode) "ON: Settings → Battery" else "off")
        if (d.batteryLevel < 0) {
            set("dev.battery", Status.WARN, "unknown (${d.batteryState})")
        } else {
            val ok = d.batteryLevel >= MIN_BATTERY || d.isCharging
            set("dev.battery", if (ok) Status.PASS else Status.FAIL, "${(d.batteryLevel * 100).toInt()} % · ${d.batteryState}")
        }
        val thermalOk = d.thermal == ThermalLevel.NOMINAL || d.thermal == ThermalLevel.FAIR
        set("dev.thermal", if (thermalOk) Status.PASS else Status.FAIL, d.thermal.id)
        set(
            "dev.disk", if (d.freeDiskBytes >= MIN_FREE_DISK) Status.PASS else Status.FAIL,
            if (d.freeDiskBytes >= 0) "${ByteFormat.string(d.freeDiskBytes)} free" else "unknown",
        )
    }

    private suspend fun checkUpload() {
        val cfg = app.settings.uploadConfig
        if (!cfg.isEnabled) {
            set("upload", Status.INFO, "OFF – local only")
            return
        }
        set("upload", Status.RUNNING, "probing ${cfg.ingestUrl}…")
        val r = withContext(Dispatchers.IO) { UploadQueue.testConnection(cfg, app.settings.deviceId) }
        set("upload", if (r.ok) Status.PASS else Status.WARN, r.detail + if (r.ok) "" else " (data stays queued on disk)")
    }

    /** Captures 5 s of motion, for the rate check and the stillness check. */
    private suspend fun runMotionTest() {
        if (motionTestRunning || app.recording != null) return
        motionTestRunning = true
        set("motion.rate", Status.RUNNING, "measuring…")
        set("motion.still", Status.RUNNING, "keep the vehicle stopped and the phone untouched…")
        val source = app.makeMotionSource()
        val dm = ArrayList<Double>()
        val gravity = ArrayList<Vec3>()
        val accel = ArrayList<Vec3Sample>()
        val gyro = ArrayList<Double>()
        val mag = ArrayList<Double>()
        try {
            // One sensor thread fills the lists, and stop() ends it before they are read.
            source.start(
                MotionCallbacks(
                    deviceMotion = { dm.add(it.t); gravity.add(it.gravity) },
                    accel = { accel.add(it) }, gyro = { gyro.add(it.t) }, mag = { mag.add(it.t) },
                ),
            )
            try {
                delay(MOTION_TEST_MS)
            } finally {
                source.stop()
            }
            val r = MotionTestAnalysis.analyze(dm, gravity, accel, gyro, mag)
            motionResult = r
            fun hz(id: StreamId) = r.rates[id] ?: 0.0
            val core = listOf(StreamId.DEVICE_MOTION, StreamId.ACCEL, StreamId.GYRO)
            set(
                "motion.rate", if (core.all { hz(it) >= MIN_MOTION_RATE }) Status.PASS else Status.FAIL,
                String.format(
                    Locale.US, "dm %.1f · acc %.1f · gyr %.1f · mag %.1f Hz",
                    hz(StreamId.DEVICE_MOTION), hz(StreamId.ACCEL), hz(StreamId.GYRO), hz(StreamId.MAG),
                ),
            )
            set(
                "motion.still", if (accel.isNotEmpty() && r.maxStd < STILLNESS_MAX_STD_G) Status.PASS else Status.FAIL,
                if (accel.isEmpty()) "no accelerometer data"
                else String.format(Locale.US, "max σ %.4f g (need < %.2f)", r.maxStd, STILLNESS_MAX_STD_G),
            )
        } finally {
            motionTestRunning = false
        }
    }

    /** Re-run only the motion test. */
    fun rerunMotionTest() {
        if (busy) return
        motionJob = scope.launch { runMotionTest() }
    }

    fun rerun() {
        val previous = listOfNotNull(runJob, motionJob)
        runJob = scope.launch {
            previous.forEach { it.cancelAndJoin() } // else the old run still counts as running
            checks = checks.map { it.copy(status = Status.PENDING, detail = "") }
            gpsPassedAtUp = null
            runAll()
        }
    }

    fun result(overridden: Boolean): SessionMetadata.Preflight {
        val r = motionResult
        fun list(v: Vec3) = listOf(v.x, v.y, v.z)
        return SessionMetadata.Preflight(
            completedAtUtc = ISO8601.string(System.currentTimeMillis()), overridden = overridden,
            checks = checks.map { SessionMetadata.PreflightCheckResult(it.id, it.title, it.status.id, it.detail, it.required) },
            stillAccelMeanG = r?.let { list(it.accelMean) }, stillGravityG = r?.gravityMean?.let { list(it) },
            stillAccelStdG = r?.let { list(it.accelStd) },
            measuredRatesHz = r?.rates?.entries?.associate { it.key.id to it.value },
        )
    }

    private companion object {
        const val MIN_MOTION_RATE = 90.0

        // 0.03 g: an idling engine or a stopped bus shakes more than 0.01 g, and a loose mount is far above
        // either (the spec gave 0.01 only as an example).
        const val STILLNESS_MAX_STD_G = 0.03
        const val GPS_MAX_ACCURACY_M = 10.0
        const val GPS_KEEP_ACCURACY_M = 20.0
        const val MIN_BATTERY = 0.5f
        const val MIN_FREE_DISK = 2_000_000_000L
        const val MOTION_TEST_MS = 5000L
    }
}
