package com.chuds.sensorrecorder.app

import android.app.Application
import android.os.Handler
import android.os.Looper
import android.util.Log
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.chuds.sensorrecorder.core.AppLog
import com.chuds.sensorrecorder.core.LogLevel
import com.chuds.sensorrecorder.core.SessionMetadata
import com.chuds.sensorrecorder.core.SessionSetup
import com.chuds.sensorrecorder.core.SessionStore
import com.chuds.sensorrecorder.core.text
import com.chuds.sensorrecorder.recording.PreflightModel
import com.chuds.sensorrecorder.recording.RecordingController
import com.chuds.sensorrecorder.recording.RecordingSession
import com.chuds.sensorrecorder.recording.SystemAlerter
import com.chuds.sensorrecorder.sensors.AltimeterSource
import com.chuds.sensorrecorder.sensors.AndroidAltimeterSource
import com.chuds.sensorrecorder.sensors.AndroidClock
import com.chuds.sensorrecorder.sensors.AndroidMotionSource
import com.chuds.sensorrecorder.sensors.DeviceStatusMonitor
import com.chuds.sensorrecorder.sensors.LocationService
import com.chuds.sensorrecorder.sensors.MotionSource
import com.chuds.sensorrecorder.upload.TripCloudCopy
import com.chuds.sensorrecorder.upload.UploadQueue
import kotlinx.coroutines.CompletableDeferred
import java.io.File
import java.io.IOException
import java.util.Locale
import java.util.UUID
import kotlin.concurrent.thread

class BumpyApp : Application() {
    lateinit var model: AppModel
        private set

    override fun onCreate() {
        super.onCreate()
        AppLog.sink = { level, msg ->
            when (level) {
                LogLevel.ERROR, LogLevel.PROBLEM -> Log.e("Bumpy", msg)
                LogLevel.WARN -> Log.w("Bumpy", msg)
                LogLevel.INFO -> Log.i("Bumpy", msg)
            }
        }
        model = AppModel(this)
        model.onLaunch()
    }
}

/** App-wide state and long-lived services, for the life of the process. Main thread. */
class AppModel(private val app: Application) {
    /** Reachable over USB (`Android/data/com.chuds.sensorrecorder/files`) and in the Files app. */
    val filesRoot: File = app.getExternalFilesDir(null) ?: app.filesDir
    val settings = AppSettings(app)
    val store = SessionStore(File(filesRoot, "sessions"))
    val location = LocationService(app)
    val deviceMonitor = DeviceStatusMonitor(app, filesRoot)
    val uploadQueue: UploadQueue
    val setup: SessionSetup get() = settings.setup
    val preflight by lazy { PreflightModel(this) }

    var recording by mutableStateOf<RecordingController?>(null)
        private set
    var lastRecoveredCount by mutableStateOf(0)
        private set
    private var isRecovering = false

    /** A 5 s motion test (Start screen or an automatic trip's warm-up) holds the motion sensors. */
    var motionTestBusy = false

    /** Automatic trips (D59). */
    val autoTrips: AutoTrips

    /**
     * The session whose app_log.txt receives upload events (spec §4). It stays set after Stop and Done (the
     * final batches and the Stop metadata upload later) until the next recording starts or the session is
     * deleted. Read from the upload thread.
     */
    @Volatile private var uploadLogSession: RecordingSession? = null

    /** The running activity's permission prompt. */
    var permissionPrompt: ((List<String>) -> Unit)? = null
    private var pendingPermissions: CompletableDeferred<Unit>? = null

    init {
        runCatching { store.ensureRoot() }
        uploadQueue = UploadQueue(
            File(filesRoot, "upload_queue"), uptime = AndroidClock::uptime,
            backgroundTime = ServiceBackgroundTime(app), config = { settings.uploadConfig },
        )
        uploadQueue.onEvent = { level, msg ->
            val session = uploadLogSession
            if (session != null) session.log(level, msg) else AppLog.log(level, msg)
        }
        autoTrips = AutoTrips(this, app)
    }

    /** Launch tasks: recover interrupted sessions, start the upload loop. */
    fun onLaunch() {
        uploadQueue.start()
        isRecovering = true
        thread(name = "sensorrecorder.recovery") {
            val recovered = runCatching { store.recoverUnfinishedSessions() }
                .onFailure { AppLog.log(LogLevel.ERROR, "recovery failed: ${it.text}") }.getOrDefault(emptyList())
            Handler(Looper.getMainLooper()).post {
                lastRecoveredCount = recovered.size
                isRecovering = false
            }
        }
    }

    /**
     * Deletes a recorded session (no button yet, as on iOS). Refuses the session being recorded, and any
     * session the cloud is not known to have in full (D55). Not on the main thread.
     */
    fun deleteSession(folder: File) {
        val active = recording
        if (active != null && !active.isFinished && active.session.folder == folder) throw IOException("this trip is being recorded")
        val meta = store.entry(folder).metadata
        val state = meta?.let { uploadQueue.tripState(it.sessionId) } ?: UploadQueue.TripState()
        TripCloudCopy.deleteRefusal(meta, state)?.let { throw it }
        store.deleteSession(folder)
        if (meta != null) uploadQueue.forgetAcknowledged(meta.sessionId)
        if (uploadLogSession?.folder == folder) uploadLogSession = null
    }

    /** A fresh motion source (also for the preflight motion test). */
    fun makeMotionSource(): MotionSource = AndroidMotionSource(app)
    fun makeAltimeterSource(): AltimeterSource = AndroidAltimeterSource(app)

    /** Shows the system prompt and waits for the answer; returns at once without a visible activity. */
    suspend fun requestPermissions(permissions: List<String>) {
        val prompt = permissionPrompt ?: return
        val answer = CompletableDeferred<Unit>()
        pendingPermissions = answer
        prompt(permissions)
        answer.await()
    }

    fun onPermissionAnswer() {
        pendingPermissions?.complete(Unit)
        pendingPermissions = null
    }

    // Recording

    fun startRecording(preflight: SessionMetadata.Preflight?) {
        if (recording != null) return
        // Launch recovery marks unfinished sessions; never let it see a session we are creating.
        if (isRecovering) throw IOException("Still checking previous sessions, try again in a second.")
        // D51: no setup form; mount and people keep the remembered defaults. D59: the vehicle type comes
        // from Settings.
        val setup = settings.setup.copy(vehicle = SessionMetadata.Vehicle(type = settings.vehicleType))
        settings.setup = setup
        begin(RecordingSession(store, setup, preflight, dependencies()))
    }

    /**
     * Starts an automatic trip (D59) through the same path as Start, without touching the remembered setup.
     * Its uploads are held first, so a Cancel in the first minutes deletes a trip nothing of which reached
     * the cloud. A finished trip whose recap nobody closed doesn't block it.
     */
    fun startAutoRecording(preflight: SessionMetadata.Preflight, detectedAtUtc: String): RecordingSession {
        if (recording?.isFinished == true) closeRecording()
        if (recording != null) throw IOException("A trip is already recording.")
        if (isRecovering) throw IOException("Still checking previous sessions.")
        val remembered = settings.setup
        val setup = remembered.copy(
            vehicle = SessionMetadata.Vehicle(type = settings.vehicleType),
            mount = remembered.mount.copy(rigid = settings.mounted, handheld = false),
        )
        val id = UUID.randomUUID()
        val sessionId = id.toString().uppercase(Locale.ROOT) // RecordingSession.sessionId
        uploadQueue.hold(sessionId)
        val session = try {
            RecordingSession(store, setup, preflight, dependencies(), id, SessionMetadata.AutoStart(detectedAtUtc))
        } catch (e: Exception) {
            uploadQueue.releaseHold(sessionId)
            throw e
        }
        this.preflight.onDisappear() // the Start screen may be open: the recording takes over motion and location
        begin(session)
        return session
    }

    /**
     * An automatic trip cancelled within its upload hold (D59): the queue already dropped every part of it
     * ([UploadQueue.discardHeldSession]), so the D55 delete guard, which waits for the cloud copy, doesn't
     * apply: there is none, and it was never a trip. Not on the main thread.
     */
    fun deleteDiscardedAutoTrip(session: RecordingSession) {
        if (uploadLogSession === session) uploadLogSession = null
        runCatching { store.deleteSession(session.folder) }
            .onFailure { AppLog.log(LogLevel.ERROR, "cancelled trip not deleted: ${it.text}") }
        uploadQueue.forgetAcknowledged(session.sessionId)
        Handler(Looper.getMainLooper()).post { if (recording?.session === session) recording = null }
    }

    private fun dependencies() = RecordingSession.Dependencies(
        motion = makeMotionSource(), location = location, altimeter = makeAltimeterSource(),
        deviceStatus = deviceMonitor, uploadQueue = uploadQueue, clock = AndroidClock,
        deviceId = settings.deviceId, appVersion = AppInfo.version, deviceInfo = AppInfo.deviceInfo,
    )

    private fun begin(session: RecordingSession) {
        val controller = RecordingController(session, SystemAlerter(app))
        location.stopPreview()
        recording = controller
        uploadLogSession = session
        RecordingService.setRecording(app, true)
        controller.start()
        uploadQueue.kick()
    }

    fun stopRecording() {
        recording?.stop()
        // After the queue's own post (hold until uploaded), so the service never stops in between.
        Handler(Looper.getMainLooper()).post { RecordingService.setRecording(app, recording?.isFinished == false) }
    }

    /** Recap's "Done". `uploadLogSession` is kept: this session's last uploads may still be in flight. */
    fun closeRecording() {
        recording = null
    }

    fun onVisibilityChanged(visible: Boolean) {
        if (visible) {
            location.refresh()
            autoTrips.armIfEnabled() // a location service can be started only from the foreground
        }
        recording?.takeIf { !it.isFinished }?.session?.noteLifecycle(background = !visible)
    }
}
