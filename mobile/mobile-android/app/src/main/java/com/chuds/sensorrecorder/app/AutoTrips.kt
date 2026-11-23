package com.chuds.sensorrecorder.app

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.drawable.Icon
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.chuds.sensorrecorder.R
import com.chuds.sensorrecorder.core.AppLog
import com.chuds.sensorrecorder.core.ISO8601
import com.chuds.sensorrecorder.core.LogLevel
import com.chuds.sensorrecorder.core.SessionMetadata
import com.chuds.sensorrecorder.core.text
import com.chuds.sensorrecorder.recording.AutoTripRules
import com.chuds.sensorrecorder.recording.PreflightModel
import com.chuds.sensorrecorder.recording.RecordingSession
import com.chuds.sensorrecorder.sensors.AutoTripSensors
import com.chuds.sensorrecorder.upload.UploadQueue
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import java.util.UUID
import kotlin.concurrent.thread

/**
 * Automatic trips (D59, 01 §7 "Automatic trips"): while armed, the recording service runs as a location
 * service with low-power location and the step detector; a candidate (moving, no steps for a minute) gets
 * full-rate GPS and the silent warm-up; [AutoTripRules] decides the start and, for automatic trips only,
 * the stop. Main thread.
 */
class AutoTrips(private val model: AppModel, private val context: Context) {
    private val sensors = AutoTripSensors(context)
    private val rules = AutoTripRules()
    private val main = Handler(Looper.getMainLooper())
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val notifications = context.getSystemService(NotificationManager::class.java)

    var armed by mutableStateOf(false)
        private set

    /** The automatic trip being recorded. */
    private var trip: RecordingSession? = null
    private var candidate = false
    private var warmUpJob: Job? = null
    private var warmUp: Pair<SessionMetadata.Preflight, String?>? = null // result, blocking reason
    private var blockedNotified = false

    /** After a Cancel or a manual Stop of an automatic trip: no new start until this drive is over. */
    private var suppressed = false

    /** Before Android 12 the Cancel action opens the app to confirm; this token proves the tap came from it. */
    private var cancelToken: String? = null

    /** The app shows "Cancel this trip?" (before Android 12). */
    var confirmCancel by mutableStateOf(false)

    private fun granted(p: String) = context.checkSelfPermission(p) == PackageManager.PERMISSION_GRANTED

    val hasBackgroundLocation: Boolean
        get() = granted(Manifest.permission.ACCESS_FINE_LOCATION) && granted(Manifest.permission.ACCESS_BACKGROUND_LOCATION)

    /** What turning automatic trips on still needs, in words; empty when everything is there. */
    fun missingRequirements(): List<String> = buildList {
        if (!granted(Manifest.permission.ACCESS_FINE_LOCATION)) add("precise location")
        else if (!granted(Manifest.permission.ACCESS_BACKGROUND_LOCATION)) add("location \"Allow all the time\"")
        if (!granted(Manifest.permission.ACTIVITY_RECOGNITION)) add("physical activity")
        if (Build.VERSION.SDK_INT >= 33 && !granted(Manifest.permission.POST_NOTIFICATIONS)) add("notifications")
        if (!sensors.hasStepDetector) add("a step detector (this phone has none)")
    }

    /** Settings' switch: asks for what can be asked in one prompt, then turns on only if nothing is missing. */
    suspend fun enable(): List<String> {
        val ask = buildList {
            if (!granted(Manifest.permission.ACCESS_FINE_LOCATION)) {
                add(Manifest.permission.ACCESS_FINE_LOCATION)
                add(Manifest.permission.ACCESS_COARSE_LOCATION)
            }
            if (!granted(Manifest.permission.ACTIVITY_RECOGNITION)) add(Manifest.permission.ACTIVITY_RECOGNITION)
            if (Build.VERSION.SDK_INT >= 33 && !granted(Manifest.permission.POST_NOTIFICATIONS)) add(Manifest.permission.POST_NOTIFICATIONS)
        }
        if (ask.isNotEmpty()) model.requestPermissions(ask)
        val missing = missingRequirements()
        if (missing.isEmpty()) {
            model.settings.autoStartEnabled = true
            armIfEnabled()
        }
        return missing
    }

    fun disable() {
        model.settings.autoStartEnabled = false
        disarm()
    }

    /**
     * Starts watching. Android lets a location service start only from the foreground (or at boot), so
     * this runs when the app becomes visible and from [AutoTripBootReceiver].
     */
    fun armIfEnabled() {
        if (!model.settings.autoStartEnabled) return disarm()
        val missing = missingRequirements()
        if (missing.isNotEmpty()) {
            AppLog.log(LogLevel.WARN, "auto start turned off, missing: ${missing.joinToString()}")
            model.settings.autoStartEnabled = false
            return disarm()
        }
        if (armed) return
        armed = true
        sensors.onFix = { f ->
            if (f.isGps) rules.onGpsFix(f.up, f.speed)
            else rules.onCoarseFix(AutoTripRules.CoarseFix(f.up, f.lat, f.lon, f.accuracyM, f.speed))
            evaluate()
        }
        sensors.onStep = { up ->
            rules.onStep(up)
            evaluate()
        }
        sensors.startWatching()
        RecordingService.setArmed(context, Armed.WATCHING)
        main.post(tick)
    }

    private fun disarm() {
        if (!armed) return
        armed = false
        main.removeCallbacks(tick)
        leaveCandidate()
        sensors.stopWatching()
        RecordingService.setArmed(context, Armed.OFF)
        // A trip that is recording keeps recording; it just won't stop by itself any more.
        if (trip != null) endTrip()
    }

    private val tick = object : Runnable {
        override fun run() {
            try {
                evaluate()
            } catch (e: Throwable) {
                AppLog.log(LogLevel.ERROR, "auto start: ${e.text}")
            }
            if (armed) main.postDelayed(this, TICK_MS)
        }
    }

    private fun now() = SystemClock.elapsedRealtimeNanos() * 1e-9

    private fun evaluate() {
        if (!armed) return
        val now = now()
        val rec = model.recording
        trip?.let { t ->
            if (rec?.session !== t || rec.isFinished) {
                suppressed = true // the user ended it with the 2 s hold: don't start again on this drive
                endTrip()
            } else if (rules.shouldStop(now)) {
                t.log(LogLevel.INFO, "automatic stop")
                model.stopRecording()
                endTrip()
            }
            return
        }
        if (rec != null && !rec.isFinished) return leaveCandidate() // a manual trip: never interfere
        if (!rules.isCandidate(now)) {
            suppressed = false
            return leaveCandidate()
        }
        if (suppressed) return
        if (!candidate) enterCandidate()
        if (!rules.shouldStart(now)) return
        val (preflight, blocking) = warmUp ?: return // still warming up
        if (blocking != null) {
            if (!blockedNotified) notifyBlocked(blocking)
            blockedNotified = true
            return
        }
        startTrip(preflight, now)
    }

    private fun enterCandidate() {
        candidate = true
        sensors.startGps()
        RecordingService.setArmed(context, Armed.CANDIDATE)
        if (warmUp == null && warmUpJob?.isActive != true) {
            warmUpJob = scope.launch {
                val checks = PreflightModel(model, warmUp = true, gpsFix = { sensors.latestGps })
                val result = checks.runWarmUp()
                warmUp = result to checks.blockingReason()
            }
        }
    }

    private fun leaveCandidate() {
        if (!candidate) return
        candidate = false
        warmUpJob?.cancel()
        warmUpJob = null
        warmUp = null
        blockedNotified = false
        rules.reset()
        sensors.stopGps()
        if (armed) RecordingService.setArmed(context, Armed.WATCHING)
    }

    private fun startTrip(preflight: SessionMetadata.Preflight, now: Double) {
        val session = try {
            model.startAutoRecording(preflight, ISO8601.string(System.currentTimeMillis()))
        } catch (e: Exception) {
            AppLog.log(LogLevel.WARN, "automatic trip not started: ${e.text}")
            if (!blockedNotified) notifyBlocked(e.text)
            blockedNotified = true
            return
        }
        trip = session
        candidate = false
        warmUp = null
        rules.tripStarted(now)
        RecordingService.setArmed(context, Armed.WATCHING) // the recording holds the wake lock now
        notifyStarted()
        // The loop polls an empty queue every second anyway; this also ends a long retry backoff.
        main.postDelayed({ model.uploadQueue.kick() }, (UploadQueue.HOLD_SECONDS * 1000).toLong() + 500)
    }

    private fun endTrip() {
        trip = null
        cancelToken = null
        confirmCancel = false
        notifications.cancel(NOTIFICATION_STARTED)
        leaveCandidate()
        rules.reset()
        sensors.stopGps()
    }

    /**
     * The notification's Cancel (D59). Within the upload hold the trip is deleted from the phone, nothing of
     * it having reached the cloud; after it, the trip stops, is kept, and carries `autoStart.cancelledAtUtc`.
     */
    fun cancel() {
        val session = trip ?: return
        if (model.recording?.session !== session || model.recording?.isFinished != false) return
        val id = session.sessionId
        val queue = model.uploadQueue
        val withinHold = session.timeBase.uptimeNow() - session.startUp < UploadQueue.HOLD_SECONDS || queue.holdRemainingMs(id) != null
        // Nothing of it may leave while it stops (the final batches and the Stop copy are queued then).
        if (withinHold) queue.hold(id)
        session.markAutoCancelled(ISO8601.string(System.currentTimeMillis()))
        model.stopRecording()
        suppressed = true
        endTrip()
        if (!withinHold) return
        thread(name = "sensorrecorder.cancel") {
            try {
                if (queue.discardHeldSession(id)) {
                    model.deleteDiscardedAutoTrip(session)
                } else {
                    session.log(LogLevel.WARN, "cancelled trip kept: part of it already reached the cloud")
                    queue.releaseHold(id)
                    queue.kick()
                }
            } catch (e: Throwable) {
                AppLog.log(LogLevel.ERROR, "cancel: ${e.text}")
            }
        }
    }

    /** MainActivity's intent from the Cancel action before Android 12. */
    fun onIntent(intent: Intent?) {
        if (intent?.action != ACTION_CONFIRM_CANCEL) return
        val token = cancelToken
        // Any app can start the activity with any extra; only the notification knows the token.
        if (token != null && intent.getStringExtra(EXTRA_TOKEN) == token) confirmCancel = true
    }

    // Notifications

    private fun channel() {
        notifications.createNotificationChannel(NotificationChannel(CHANNEL, "Automatic trips", NotificationManager.IMPORTANCE_DEFAULT))
    }

    private fun openApp() = PendingIntent.getActivity(context, 0, Intent(context, MainActivity::class.java), PendingIntent.FLAG_IMMUTABLE)

    /** Never a Stop action: Stop stays the 2 s hold. */
    private fun notifyStarted() {
        channel()
        val icon = Icon.createWithResource(context, R.drawable.ic_notification)
        val action = if (Build.VERSION.SDK_INT >= 31) {
            val cancel = PendingIntent.getBroadcast(
                context, 1, Intent(context, AutoTripCancelReceiver::class.java),
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
            )
            Notification.Action.Builder(icon, "Cancel", cancel).setAuthenticationRequired(true).build()
        } else {
            val token = UUID.randomUUID().toString()
            cancelToken = token
            val confirm = PendingIntent.getActivity(
                context, 1,
                Intent(context, MainActivity::class.java).setAction(ACTION_CONFIRM_CANCEL).putExtra(EXTRA_TOKEN, token),
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
            )
            Notification.Action.Builder(icon, "Cancel", confirm).build()
        }
        val n = Notification.Builder(context, CHANNEL)
            .setSmallIcon(R.drawable.ic_notification)
            .setContentTitle("Trip started automatically")
            .setContentText("Not a trip? Cancel within 2 minutes and nothing is uploaded.")
            .setContentIntent(openApp())
            .addAction(action)
            .build()
        runCatching { notifications.notify(NOTIFICATION_STARTED, n) }
    }

    private fun notifyBlocked(reason: String) {
        channel()
        val n = Notification.Builder(context, CHANNEL)
            .setSmallIcon(R.drawable.ic_notification)
            .setContentTitle("Trip not started automatically")
            .setContentText(reason)
            .setContentIntent(openApp())
            .setAutoCancel(true)
            .build()
        runCatching { notifications.notify(NOTIFICATION_BLOCKED, n) }
    }

    companion object {
        const val ACTION_CONFIRM_CANCEL = "com.chuds.sensorrecorder.CONFIRM_CANCEL_AUTO_TRIP"
        private const val EXTRA_TOKEN = "token"
        private const val CHANNEL = "auto_trip"
        private const val NOTIFICATION_STARTED = 2
        private const val NOTIFICATION_BLOCKED = 3
        private const val TICK_MS = 1000L
    }
}

/** The Cancel action (Android 12+, only after the phone is unlocked). Not exported. */
class AutoTripCancelReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        (context.applicationContext as BumpyApp).model.autoTrips.cancel()
    }
}

/**
 * Re-arms after a reboot or an app update. Both are protected broadcasts only the system sends. Android may
 * still refuse the location service here (README).
 */
class AutoTripBootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Intent.ACTION_BOOT_COMPLETED && intent.action != Intent.ACTION_MY_PACKAGE_REPLACED) return
        (context.applicationContext as BumpyApp).model.autoTrips.armIfEnabled()
    }
}
