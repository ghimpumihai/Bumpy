package com.chuds.sensorrecorder.core

import java.io.File
import java.io.IOException
import java.io.RandomAccessFile
import java.util.concurrent.ScheduledFuture
import java.util.concurrent.ScheduledThreadPoolExecutor
import java.util.concurrent.TimeUnit

/**
 * Every CSV in a session folder, with its exact header (spec §4): the same schema the iOS app writes
 * (`mobile/mobile-ios/tools/fixtures/csv_headers.json`). The backend parses by header name.
 */
enum class StreamFile(val stem: String, vararg columns: String) {
    DEVICE_MOTION("device_motion", "ua_x", "ua_y", "ua_z", "g_x", "g_y", "g_z", "rr_x", "rr_y", "rr_z",
        "q_w", "q_x", "q_y", "q_z", "roll", "pitch", "yaw"),
    ACCEL_RAW("accel_raw", "x", "y", "z"),
    GYRO_RAW("gyro_raw", "x", "y", "z"),
    MAG_RAW("mag_raw", "x", "y", "z"),
    LOCATION("location", "lat", "lon", "alt", "ell_alt", "h_acc", "v_acc", "speed", "speed_acc",
        "course", "course_acc", "is_simulated"),
    HEADING("heading", "mag_heading", "true_heading", "heading_acc", "x", "y", "z"),
    ALTIMETER("altimeter", "rel_alt_m", "pressure_kpa"),
    ABS_ALTITUDE("abs_altitude", "altitude_m", "accuracy_m", "precision_m"),
    ACTIVITY("activity", "stationary", "walking", "running", "automotive", "cycling", "unknown",
        "confidence", "start_utc_ms"),
    DEVICE("device", "battery_level", "battery_state", "thermal_state", "low_power",
        "free_disk_bytes", "net_status", "net_type"),
    LABELS("labels", "type", "value", "note"),
    CLOCK("clock", "source");

    val fileName: String = "$stem.csv"
    val header: String = (listOf("t_up", "t_utc_ms") + columns).joinToString(",")
}

object SessionFileName {
    const val METADATA = "session.json"
    const val APP_LOG = "app_log.txt"
}

/** Where a [BufferedFileWriter] puts bytes. Production: the file; tests inject failures here. */
interface FileSink {
    fun offset(): Long
    fun write(data: ByteArray)
    fun synchronize()
    fun close()
}

class RandomAccessSink(file: File) : FileSink {
    private val f = RandomAccessFile(file, "rw").apply { seek(length()) }
    override fun offset(): Long = f.filePointer
    override fun write(data: ByteArray) = f.write(data)
    override fun synchronize() = f.fd.sync()
    override fun close() = f.close()
}

/**
 * Append-only, buffered text file. [append] is cheap and thread-safe (called from sensor threads);
 * [flush] must only be called from the owner's single writer thread.
 *
 * Creates the file (must not exist) and writes [header] synchronously.
 */
class BufferedFileWriter(val file: File, header: String?, sink: (File) -> FileSink = { RandomAccessSink(it) }) {
    private val lock = Any()
    private var pending = StringBuilder() // under lock
    private var closedFlag = false        // under lock
    private var dropped = 0               // under lock
    private val out: FileSink

    /** Bytes that failed to write last time (e.g. disk full). Retried first on the next flush. */
    private var retryData = ByteArray(0)
    private var closed = false

    /** Whether the bytes on disk end with a complete line. */
    private var diskEndsWithNewline = true

    @Volatile var bytesWritten = 0L
        private set

    /**
     * Hard cap for data held in memory per file while the disk refuses writes (prevents OOM).
     * Per instance so tests can use a tiny cap.
     */
    var maxRetryBytes = 4 * 1024 * 1024

    init {
        if (!file.createNewFile()) throw IOException("${file.path} already exists")
        val initial = header?.let { (it + "\n").toByteArray() } ?: ByteArray(0)
        file.writeBytes(initial)
        out = sink(file)
        bytesWritten = initial.size.toLong()
    }

    /** Lines offered after [close] are refused (counted), never silently buffered forever. */
    val droppedAfterClose: Int get() = synchronized(lock) { dropped }

    /**
     * Returns false if the writer is already closed (the line is counted, not written). The closed
     * check happens under the lock [close] also takes, so a line is either part of the final flush
     * or refused, never left in a buffer nobody flushes.
     */
    fun append(line: String): Boolean = synchronized(lock) {
        if (closedFlag) {
            dropped++
            false
        } else {
            pending.append(line).append('\n')
            true
        }
    }

    /** Writes everything buffered so far. Throws on I/O errors; the unwritten data is kept for retry. */
    fun flush() {
        if (closed) return
        val chunk = synchronized(lock) {
            val c = pending
            pending = StringBuilder(c.length)
            c
        }.toString().toByteArray()
        val data = if (retryData.isEmpty()) chunk else retryData + chunk
        if (data.isEmpty()) return
        val before = runCatching { out.offset() }.getOrDefault(0L)
        try {
            out.write(data)
            retryData = ByteArray(0)
            diskEndsWithNewline = data.last() == NEWLINE
            bytesWritten += data.size
        } catch (e: IOException) {
            // A failed write may still have written a prefix: never write those bytes twice.
            val after = runCatching { out.offset() }.getOrDefault(before)
            val written = (after - before).coerceIn(0L, data.size.toLong()).toInt()
            if (written > 0) {
                diskEndsWithNewline = data[written - 1] == NEWLINE
                bytesWritten += written
            }
            var rest = data.copyOfRange(written, data.size)
            if (rest.size > maxRetryBytes) {
                // Drop the oldest *whole lines* only, so the retained data starts at a row boundary.
                // Search from cut-1: if the cut falls exactly on a row start, that row is kept.
                var nl = rest.size - maxRetryBytes - 1
                while (nl < rest.size && rest[nl] != NEWLINE) nl++
                rest = if (nl < rest.size) rest.copyOfRange(nl + 1, rest.size) else ByteArray(0)
                // If the disk currently ends mid-row, terminate that row before the retained rows.
                if (!diskEndsWithNewline) rest = byteArrayOf(NEWLINE) + rest
            }
            retryData = rest
            throw e
        }
    }

    /** fsync: pushes the kernel page cache to flash. Costly; call rarely. */
    fun synchronize() {
        if (!closed) out.synchronize()
    }

    fun close() {
        if (closed) return
        synchronized(lock) { closedFlag = true }
        try {
            flush()
            out.synchronize()
        } finally {
            closed = true
            runCatching { out.close() }
        }
    }

    private companion object {
        const val NEWLINE = '\n'.code.toByte()
    }
}

data class WriteErrors(val count: Int = 0, val last: String? = null, val lastAtUp: Double? = null)

/**
 * Owns every CSV writer of one session plus `app_log.txt`, and flushes them on one thread every
 * 0.5 s (spec: at least every 1 s, so a crash loses < 1 s).
 */
class SessionWriter(
    val folder: File,
    private val uptime: () -> Double,
    files: List<StreamFile> = StreamFile.entries,
) {
    private val writers: Map<StreamFile, BufferedFileWriter>
    private val logWriter: BufferedFileWriter
    private val queue = ScheduledThreadPoolExecutor(1) { r -> Thread(r, "sensorrecorder.writer").apply { isDaemon = true } }
        .apply {
            setKeepAliveTime(10, TimeUnit.SECONDS)
            allowCoreThreadTimeOut(true)
        }
    private var timer: ScheduledFuture<*>? = null
    private var flushCount = 0
    private val errorState = Locked(WriteErrors())

    /** Called (on the writer thread) whenever a flush fails. */
    @Volatile var onWriteError: ((String) -> Unit)? = null

    init {
        if (!folder.isDirectory && !folder.mkdirs()) throw IOException("could not create ${folder.path}")
        writers = files.associateWith { BufferedFileWriter(File(folder, it.fileName), it.header) }
        logWriter = BufferedFileWriter(File(folder, SessionFileName.APP_LOG), null)
    }

    fun start() {
        timer = queue.scheduleWithFixedDelay({ flushAll() }, FLUSH_INTERVAL_MS, FLUSH_INTERVAL_MS, TimeUnit.MILLISECONDS)
    }

    fun append(file: StreamFile, line: String) {
        writers[file]?.append(line)
    }

    /**
     * Timestamped line in `app_log.txt`, mirrored to the system log.
     *
     * After [close] the line is still appended (spec §4: app_log.txt holds upload failures, and the
     * final batches and the Stop metadata upload after Stop). Late lines are rare, so each one opens
     * the file on the writer thread (keeps the order). `session.json` stats are a snapshot taken at
     * Stop, so its `app_log.txt` size may be smaller than the file.
     */
    fun log(level: LogLevel, message: String) {
        val line = "${ISO8601.string(System.currentTimeMillis())} t_up=${Csv.f6(uptime())} [${level.label}] $message"
        if (!logWriter.append(line)) queue.execute { appendLateLine(line) }
        AppLog.log(level, message)
    }

    /** Appends to an existing file only: if the session folder was deleted meanwhile, nothing is recreated. */
    private fun appendLateLine(line: String) {
        try {
            if (!logWriter.file.exists()) return
            RandomAccessFile(logWriter.file, "rw").use {
                it.seek(it.length())
                it.write((line + "\n").toByteArray())
            }
        } catch (e: IOException) {
            AppLog.log(LogLevel.ERROR, "late app_log line not written: ${e.text}")
        }
    }

    /** Waits until every late log line queued so far is on disk (used by tests). */
    fun drainLateLog() {
        queue.submit {}.get()
    }

    val writeErrors: WriteErrors get() = errorState.current

    private fun flushAll() {
        flushCount++
        val sync = flushCount % FSYNC_EVERY_N_FLUSHES == 0
        // Throwable, not IOException: anything escaping here would silently cancel the flush timer.
        for ((file, w) in writers) {
            try {
                w.flush()
                if (sync) w.synchronize()
            } catch (e: Throwable) {
                recordError("flush ${file.fileName} failed: ${e.text}")
            }
        }
        try {
            logWriter.flush()
        } catch (e: Throwable) {
            recordError("flush app_log.txt failed: ${e.text}")
        }
    }

    private fun recordError(msg: String) {
        val now = uptime()
        errorState.update { WriteErrors(it.count + 1, msg, now) }
        onWriteError?.invoke(msg)
    }

    /** Synchronous flush of everything buffered so far (used before computing final stats). */
    fun flushNow() {
        queue.submit { flushAll() }.get()
    }

    /** Final flush + fsync + close. Idempotent. */
    fun close() {
        queue.submit {
            timer?.cancel(false)
            timer = null
            for ((file, w) in writers) {
                try {
                    w.close()
                } catch (e: Throwable) {
                    recordError("close ${file.fileName} failed: ${e.text}")
                }
            }
            runCatching { logWriter.close() }
        }.get()
    }

    private companion object {
        const val FLUSH_INTERVAL_MS = 500L
        const val FSYNC_EVERY_N_FLUSHES = 20 // ~10 s
    }
}
