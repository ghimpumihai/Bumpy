package com.chuds.sensorrecorder

import com.chuds.sensorrecorder.core.ClockSource
import com.chuds.sensorrecorder.core.SessionMetadata
import com.chuds.sensorrecorder.core.ThermalLevel
import com.chuds.sensorrecorder.core.Vec3
import com.chuds.sensorrecorder.sensors.AltimeterSample
import com.chuds.sensorrecorder.sensors.AltimeterSource
import com.chuds.sensorrecorder.sensors.DeviceMotionSample
import com.chuds.sensorrecorder.sensors.DeviceStatus
import com.chuds.sensorrecorder.sensors.DeviceStatusSource
import com.chuds.sensorrecorder.sensors.HeadingSample
import com.chuds.sensorrecorder.sensors.LocationCallbacks
import com.chuds.sensorrecorder.sensors.LocationSample
import com.chuds.sensorrecorder.sensors.LocationSource
import com.chuds.sensorrecorder.sensors.MotionAvailability
import com.chuds.sensorrecorder.sensors.MotionCallbacks
import com.chuds.sensorrecorder.sensors.MotionSource
import com.chuds.sensorrecorder.sensors.Quaternion
import com.chuds.sensorrecorder.sensors.Vec3Sample
import com.chuds.sensorrecorder.upload.BackgroundTimeProvider
import com.chuds.sensorrecorder.upload.HttpRequest
import com.chuds.sensorrecorder.upload.HttpTransport
import com.chuds.sensorrecorder.upload.QueueFiles
import java.io.File
import java.io.IOException
import java.nio.file.Files
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

fun tempDir(): File = Files.createTempDirectory("bumpy").toFile().also { it.deleteOnExit() }

object JvmClock : ClockSource {
    override fun uptime() = System.nanoTime() * 1e-9
    override fun nowUtcMs() = System.currentTimeMillis().toDouble()
}

class FakeClock(var up: Double = 1000.0, var utc: Double = 1_763_716_323_512.0) : ClockSource {
    override fun uptime() = up
    override fun nowUtcMs() = utc
    fun advance(s: Double) {
        up += s
        utc += s * 1000
    }
}

class MockTransport : HttpTransport {
    private val responses = ArrayDeque<Any>()
    val requests = ArrayList<HttpRequest>()

    @Synchronized fun enqueue(vararg statuses: Int) { responses.addAll(statuses.toList()) }
    @Synchronized fun enqueueError(e: Exception) { responses.add(e) }

    @Synchronized override fun send(request: HttpRequest): Int {
        requests.add(request)
        return when (val r = responses.removeFirstOrNull()) {
            null -> 200
            is Exception -> throw r
            else -> r as Int
        }
    }

    val keys: List<String> get() = synchronized(this) { requests.map { it.headers.getValue("x-idempotency-key") } }
}

/** File operations that can be told to fail. */
class FlakyFiles : QueueFiles {
    var failWrite = false
    var failRead: (File) -> Boolean = { false }
    var failDelete = false
    var failMove = false

    override fun write(data: ByteArray, file: File) = if (failWrite) throw IOException("disk full") else QueueFiles.Real.write(data, file)
    override fun read(file: File) = if (failRead(file)) throw IOException("unreadable") else QueueFiles.Real.read(file)
    override fun delete(file: File) = if (failDelete) throw IOException("no delete") else QueueFiles.Real.delete(file)
    override fun move(from: File, to: File) = if (failMove) throw IOException("no move") else QueueFiles.Real.move(from, to)
}

class FakeBackgroundTime : BackgroundTimeProvider {
    var begins = 0
    var ends = 0
    private var onExpire: (() -> Unit)? = null
    override fun begin(onExpire: () -> Unit) {
        begins++
        this.onExpire = onExpire
    }
    override fun end() {
        ends++
        onExpire = null
    }
    fun expire() {
        onExpire?.invoke()
        onExpire = null
    }
}

val TEST_STATUS = DeviceStatus(0.8f, "charging", ThermalLevel.NOMINAL, false, 50_000_000_000, "satisfied", "wifi")

class FakeDeviceStatus : DeviceStatusSource {
    override fun currentStatus() = TEST_STATUS
}

private class Ticker(private val periodMs: Long) {
    private val executor = Executors.newSingleThreadScheduledExecutor { r -> Thread(r).apply { isDaemon = true } }
    fun start(body: () -> Unit) { executor.scheduleAtFixedRate(body, 0, periodMs, TimeUnit.MILLISECONDS) }
    fun stop() {
        executor.shutdown()
        executor.awaitTermination(5, TimeUnit.SECONDS)
    }
}

/** 100 Hz, phone flat and screen up. Sessions recorded with it are flagged `syntheticSensors: true`. */
class SyntheticMotionSource : MotionSource {
    private val ticker = Ticker(10)
    private var n = 0
    override val isSynthetic = true
    override val availability = MotionAvailability(true, true, true, true)

    override fun start(callbacks: MotionCallbacks) = ticker.start {
        val t = JvmClock.uptime()
        val g = Vec3(0.0, 0.0, -1.0)
        val ua = Vec3(0.01, 0.02, 0.03)
        callbacks.deviceMotion(DeviceMotionSample(t, ua, g, Vec3.ZERO, Quaternion(1.0, 0.0, 0.0, 0.0), 0.0, 0.0, 0.0))
        callbacks.accel(Vec3Sample(t, ua + g))
        callbacks.gyro(Vec3Sample(t, Vec3(0.001, 0.002, 0.003)))
        if (n++ % 2 == 0) callbacks.mag(Vec3Sample(t, Vec3(20.0, -5.0, -40.0)))
    }

    override fun stop() = ticker.stop()
}

fun fix(
    utcMs: Double = System.currentTimeMillis().toDouble(), lat: Double = 46.77121, lon: Double = 23.62363, alt: Double = 352.1,
    ellAlt: Double = 390.0, hAcc: Double = 4.7, vAcc: Double = 3.0, speed: Double = 8.4, course: Double = 92.0,
) = LocationSample(utcMs, lat, lon, alt, ellAlt, hAcc, vAcc, speed, 0.5, course, 5.0, false)

class FakeLocationSource : LocationSource {
    private val ticker = Ticker(1000)
    private var i = 0
    override fun startRecording(callbacks: LocationCallbacks) = ticker.start {
        i++
        val s = fix(lat = 46.77121 + i * 0.0001)
        callbacks.location(s)
        callbacks.heading(HeadingSample(s.utcMs, 90.0, 95.0, 10.0, Vec3(1.0, 2.0, 3.0)))
    }
    override fun stopRecording() = ticker.stop()
}

class FakeAltimeter : AltimeterSource {
    private val ticker = Ticker(1000)
    override val isAvailable = true
    override fun start(callback: (AltimeterSample) -> Unit) = ticker.start { callback(AltimeterSample(JvmClock.uptime(), 0.5, 97.1)) }
    override fun stop() = ticker.stop()
}

fun sampleMetadata() = SessionMetadata(
    sessionId = "ABC", appVersion = "1.0.0 (1) abc123", device = SessionMetadata.Device("x1", "Phone X", "Android 16 (API 36)"),
    timezone = "Europe/Bucharest", startedAtUtc = "2026-11-21T09:12:03.512Z", startUptimeSec = 123456.789012, endedAtUtc = null,
    syntheticSensors = false, folderName = "2026-11-21T09-12-03Z_abcd", deviceId = "DEV",
)

fun sampleStats(batches: Int, notQueued: Int? = null) = SessionMetadata.Stats(
    durationSec = 10.0, streams = emptyMap(), labelsCount = 0, fileSizes = emptyMap(), totalBytes = 1, writeErrors = 0,
    uploadBatchesCreated = batches, uploadWindowsNotQueued = notQueued,
)

class Csv2(val header: List<String>, val rows: List<List<String>>)

fun readCsv(f: File): Csv2 {
    val text = f.readText()
    check(text.endsWith("\n")) { "${f.name} ends mid-line" }
    val lines = text.dropLast(1).split("\n")
    return Csv2(lines.first().split(","), lines.drop(1).map { it.split(",") })
}
