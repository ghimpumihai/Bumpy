package com.chuds.sensorrecorder.core

import java.io.File
import java.io.FileOutputStream
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.time.Instant
import java.time.ZoneOffset
import java.time.format.DateTimeFormatter
import java.util.Locale
import kotlin.math.floor
import kotlin.math.roundToLong
import kotlin.math.sqrt

/**
 * Minimal lock-protected box. Sensor callbacks arrive on background threads while the UI reads
 * snapshots on the main thread, so every piece of shared mutable state goes through one of these.
 */
class Locked<T>(private var value: T) {
    val current: T get() = synchronized(this) { value }
    fun set(v: T) = synchronized(this) { value = v }

    /** Stores what [body] returns and returns it. */
    fun update(body: (T) -> T): T = synchronized(this) { body(value).also { value = it } }

    /** Stores [v] and returns the previous value. */
    fun swap(v: T): T = synchronized(this) { value.also { value = v } }
}

/** Fixed-capacity ring buffer (overwrites the oldest element). Not thread-safe by itself. */
class RingBuffer(val capacity: Int) {
    private val storage = DoubleArray(capacity)
    private var head = 0
    var count = 0
        private set

    init { require(capacity > 0) }

    fun append(v: Double) {
        storage[head] = v
        head = (head + 1) % capacity
        if (count < capacity) count++
    }

    /** Elements from oldest to newest. */
    val elements: List<Double>
        get() {
            val start = (head - count + capacity) % capacity
            return List(count) { storage[(start + it) % capacity] }
        }
}

data class Vec3(val x: Double, val y: Double, val z: Double) {
    fun dot(o: Vec3) = x * o.x + y * o.y + z * o.z
    val norm: Double get() = sqrt(x * x + y * y + z * z)
    operator fun minus(o: Vec3) = Vec3(x - o.x, y - o.y, z - o.z)
    operator fun plus(o: Vec3) = Vec3(x + o.x, y + o.y, z + o.z)
    operator fun times(s: Double) = Vec3(x * s, y * s, z * s)
    val normalized: Vec3 get() { val n = norm; return if (n > 0) this * (1 / n) else this }

    companion object { val ZERO = Vec3(0.0, 0.0, 0.0) }
}

object ISO8601 {
    private val millis = DateTimeFormatter.ofPattern("yyyy-MM-dd'T'HH:mm:ss.SSS'Z'", Locale.ROOT).withZone(ZoneOffset.UTC)
    private val folder = DateTimeFormatter.ofPattern("yyyy-MM-dd'T'HH-mm-ss'Z'", Locale.ROOT).withZone(ZoneOffset.UTC)

    /** `2026-11-21T09:12:03.512Z` */
    fun string(utcMs: Double): String = string(if (utcMs.isFinite()) utcMs.roundToLong() else 0L)
    fun string(utcMs: Long): String = millis.format(Instant.ofEpochMilli(utcMs))

    /** Unix milliseconds, or null. */
    fun utcMs(s: String): Long? = runCatching { Instant.parse(s).toEpochMilli() }.getOrNull()

    /** Folder-safe timestamp: `2026-11-21T09-12-03Z` */
    fun folderStamp(utcMs: Double): String = folder.format(Instant.ofEpochMilli(floor(utcMs).toLong()))
}

object ByteFormat {
    /** `412 KB`, `52.3 MB`, `1.2 GB` (decimal units, as iOS's ByteCountFormatter `.file`). */
    fun string(bytes: Long): String = when {
        bytes < 1_000_000 -> "${(bytes + 500) / 1000} KB"
        bytes < 1_000_000_000 -> trim(bytes / 1e6, 1) + " MB"
        else -> trim(bytes / 1e9, 2) + " GB"
    }

    private fun trim(v: Double, decimals: Int) =
        String.format(Locale.US, "%.${decimals}f", v).trimEnd('0').trimEnd('.')
}

object FileUtil {
    const val TMP_SUFFIX = ".tmp"

    /** Temp file + fsync + rename, so a crash never leaves a half-written file under its final name. */
    fun writeAtomically(data: ByteArray, file: File) {
        val tmp = File(file.parentFile, file.name + TMP_SUFFIX)
        try {
            FileOutputStream(tmp).use {
                it.write(data)
                it.fd.sync()
            }
            Files.move(tmp.toPath(), file.toPath(), StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING)
        } catch (e: Exception) {
            tmp.delete()
            throw e
        }
    }
}

enum class LogLevel(val label: String) { INFO("INFO"), WARN("WARN"), PROBLEM("PROBLEM"), ERROR("ERROR") }

/** The app's system log, behind a hook so `core` needs no Android classes. */
object AppLog {
    @Volatile var sink: (LogLevel, String) -> Unit = { _, _ -> }
    fun log(level: LogLevel, message: String) = sink(level, message)
}

/** What to show for an exception that may carry no message. */
val Throwable.text: String get() = message ?: javaClass.simpleName
