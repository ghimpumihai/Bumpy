package com.chuds.sensorrecorder.app

import android.Manifest
import android.annotation.SuppressLint
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.PowerManager
import com.chuds.sensorrecorder.R
import com.chuds.sensorrecorder.core.AppLog
import com.chuds.sensorrecorder.core.LogLevel
import com.chuds.sensorrecorder.core.text
import com.chuds.sensorrecorder.upload.BackgroundTimeProvider

/**
 * Keeps the process and its sensors running while a trip records (iOS: background mode `location`) and,
 * after Stop, until the upload queue is empty (iOS: a background task). It owns no state of the trip: the
 * notification only opens the app, because Stop must stay a 2 s hold.
 */
class RecordingService : Service() {
    private var wakeLock: PowerManager.WakeLock? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        instance = this
        // Required within seconds of startForegroundService, even if the work has ended meanwhile.
        show()
        if (!needed) finish()
        return START_NOT_STICKY // a killed recording is recovered on the next launch, never resumed
    }

    @SuppressLint("WakelockTimeout") // released in onDestroy; a trip has no maximum length
    private fun show() {
        val type = if (recording && checkSelfPermission(Manifest.permission.ACCESS_FINE_LOCATION) == PackageManager.PERMISSION_GRANTED) {
            ServiceInfo.FOREGROUND_SERVICE_TYPE_LOCATION
        } else {
            ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC // uploading, or a trip started without location
        }
        try {
            startForeground(NOTIFICATION_ID, notification(), type)
        } catch (e: Exception) {
            AppLog.log(LogLevel.PROBLEM, "foreground service refused: ${e.text}. Keep the app on screen")
        }
        if (wakeLock == null) {
            wakeLock = getSystemService(PowerManager::class.java)
                .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "bumpy:recording").also { it.acquire() }
        }
    }

    private fun notification(): Notification {
        getSystemService(NotificationManager::class.java)
            .createNotificationChannel(NotificationChannel(CHANNEL, "Recording", NotificationManager.IMPORTANCE_LOW))
        val open = PendingIntent.getActivity(this, 0, Intent(this, MainActivity::class.java), PendingIntent.FLAG_IMMUTABLE)
        return Notification.Builder(this, CHANNEL)
            .setSmallIcon(R.drawable.ic_notification)
            .setContentTitle(if (recording) "Recording" else "Uploading the trip")
            .setContentIntent(open)
            .setOngoing(true)
            .build()
    }

    private fun finish() {
        if (instance === this) instance = null // a start from here on needs a new instance
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    /** Android 15 ends a dataSync service after 6 hours a day. */
    override fun onTimeout(startId: Int, fgsType: Int) {
        uploading = false
        onExpire?.invoke()
        onExpire = null
        if (needed) show() else finish()
    }

    override fun onDestroy() {
        wakeLock?.release()
        wakeLock = null
        if (instance === this) instance = null
        super.onDestroy()
    }

    /** Main thread only. */
    companion object {
        private const val CHANNEL = "recording"
        private const val NOTIFICATION_ID = 1

        private var instance: RecordingService? = null
        private var recording = false
        private var uploading = false
        private var onExpire: (() -> Unit)? = null
        private val needed get() = recording || uploading

        fun setRecording(context: Context, on: Boolean) {
            recording = on
            update(context)
        }

        internal fun setUploading(context: Context, on: Boolean, expire: (() -> Unit)?) {
            uploading = on
            onExpire = expire
            update(context)
        }

        private fun update(context: Context) {
            val running = instance
            when {
                needed && running != null -> running.show()
                needed -> try {
                    context.startForegroundService(Intent(context, RecordingService::class.java))
                } catch (e: Exception) { // not allowed from the background
                    AppLog.log(LogLevel.WARN, "foreground service not started: ${e.text}")
                }
                else -> running?.finish() // a start still on its way finishes itself
            }
        }
    }
}

/** Both calls hop to the main thread in FIFO order, so an `end()` right after a `begin()` can't run first. */
class ServiceBackgroundTime(private val context: Context) : BackgroundTimeProvider {
    private val main = Handler(Looper.getMainLooper())

    override fun begin(onExpire: () -> Unit) {
        main.post { RecordingService.setUploading(context, true, onExpire) }
    }

    override fun end() {
        main.post { RecordingService.setUploading(context, false, null) }
    }
}
