package com.chuds.sensorrecorder.recording

import android.content.Context
import android.media.AudioManager
import android.media.ToneGenerator
import android.os.Handler
import android.os.Looper
import android.os.VibrationEffect
import android.os.Vibrator
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.chuds.sensorrecorder.core.HealthEvaluator
import com.chuds.sensorrecorder.core.HealthIssue
import com.chuds.sensorrecorder.core.HealthLevel
import com.chuds.sensorrecorder.core.LogLevel
import com.chuds.sensorrecorder.core.SessionMetadata

/**
 * Main-thread view model for the recording screen. Refreshes at 8 Hz (spec: 5–10 Hz, never per sample),
 * evaluates the warning rules, alerts on new problems. Lives in the app, not in the activity, so a
 * recreated activity finds the running recording.
 */
class RecordingController(val session: RecordingSession, private val alerter: Alerter) {
    var elapsed by mutableStateOf(0.0)
        private set
    var issues by mutableStateOf(emptyList<HealthIssue>())
        private set
    var finished by mutableStateOf<SessionMetadata?>(null)
        private set

    /** "GPS back · 12 s gap", shown for a few seconds after GPS recovers. */
    private var recoveryNote by mutableStateOf<String?>(null)
    private var recoveryExpiryUp = 0.0

    /** Uptime of the last GPS fix before the current outage; null while GPS is fine. */
    private var gpsLostSinceUp: Double? = null
    private val issueTracker = IssueTracker()
    private val handler = Handler(Looper.getMainLooper())

    val isFinished: Boolean get() = finished != null
    val trackPoints: List<TrackBuffer.Point> get() = session.track.points

    private val tick = object : Runnable {
        override fun run() {
            refresh()
            handler.postDelayed(this, REFRESH_MS)
        }
    }

    fun start() {
        session.start()
        tick.run()
    }

    fun stop() {
        if (isFinished) return
        handler.removeCallbacks(tick)
        finished = session.stop()
        alerter.stopped()
    }

    private fun refresh() {
        val now = session.timeBase.uptimeNow()
        val new = HealthEvaluator.evaluate(session.healthInputs(now))
        handleTransitions(new, now)
        issues = new
        if (recoveryNote != null && now > recoveryExpiryUp) recoveryNote = null
        elapsed = now - session.startUp
    }

    private fun handleTransitions(new: List<HealthIssue>, now: Double) {
        val t = issueTracker.update(new)
        for (i in t.appeared) session.log(if (i.level == HealthLevel.PROBLEM) LogLevel.PROBLEM else LogLevel.WARN, i.message)
        for (key in t.resolved) session.log(LogLevel.INFO, "resolved: $key")
        if (t.alert) alerter.newProblem() // spec: strong haptic + sound on PROBLEM

        val gpsLost = new.any { it.key == "gps.nofix" }
        val since = gpsLostSinceUp
        if (gpsLost && since == null) {
            gpsLostSinceUp = session.latest.gpsFixUp ?: session.startUp
        } else if (!gpsLost && since != null) {
            gpsLostSinceUp = null
            val back = session.latest.gpsFixUp
            if (back != null && back > since) {
                recoveryNote = "GPS back · ${TripFormat.gap(back - since)} gap"
                recoveryExpiryUp = now + RECOVERY_NOTE_S
            }
        }
    }

    /**
     * The one status line above "Hold to end trip": the worst current issue, else the recovery note, else
     * "All saved".
     */
    val statusLine: Pair<String, HealthLevel>
        get() {
            val worst = issues.firstOrNull() ?: return (recoveryNote ?: "All saved") to HealthLevel.OK // sorted worst first
            var text = worst.message
            if (worst.key == "gps.nofix") text = text.replace("GPS: no fix for", "GPS lost for") + " · motion still saving"
            if (issues.size > 1) text += " · +${issues.size - 1} more"
            return text to worst.level
        }

    private companion object {
        const val REFRESH_MS = 125L // 8 Hz
        const val RECOVERY_NOTE_S = 5.0
    }
}

/** Operator feedback (haptics + sounds). */
interface Alerter {
    fun newProblem()
    fun stopped()
}

class SystemAlerter(context: Context) : Alerter {
    private val vibrator = context.getSystemService(Vibrator::class.java)

    override fun newProblem() {
        vibrate(VibrationEffect.createWaveform(longArrayOf(0, 120, 80, 120, 80, 180), -1))
        runCatching {
            val tone = ToneGenerator(AudioManager.STREAM_NOTIFICATION, ToneGenerator.MAX_VOLUME)
            tone.startTone(ToneGenerator.TONE_PROP_BEEP2, 400)
            Handler(Looper.getMainLooper()).postDelayed({ tone.release() }, 800)
        }
    }

    override fun stopped() = vibrate(VibrationEffect.createPredefined(VibrationEffect.EFFECT_DOUBLE_CLICK))

    private fun vibrate(e: VibrationEffect) {
        runCatching { vibrator?.vibrate(e) }
    }
}

/**
 * Which health issues are new, changed or resolved between two evaluations, and whether the operator must
 * be alerted.
 */
class IssueTracker {
    class Transition(
        /** Issues that are new or changed level (logged). */
        val appeared: List<HealthIssue>,
        /** Keys that disappeared (logged as resolved). */
        val resolved: List<String>,
        /** A PROBLEM appeared or an issue escalated to PROBLEM: strong haptic + sound. */
        val alert: Boolean,
    )

    private var known: Map<String, HealthLevel> = emptyMap()

    fun update(issues: List<HealthIssue>): Transition {
        val current = issues.associate { it.key to it.level }
        val appeared = issues.filter { known[it.key] != it.level }
        val resolved = known.keys.filter { it !in current }.sorted()
        known = current
        return Transition(appeared, resolved, appeared.any { it.level == HealthLevel.PROBLEM })
    }
}
