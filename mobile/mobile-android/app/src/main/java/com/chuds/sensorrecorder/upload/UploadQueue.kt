package com.chuds.sensorrecorder.upload

import com.chuds.sensorrecorder.core.CsvRepair
import com.chuds.sensorrecorder.core.FileUtil
import com.chuds.sensorrecorder.core.Json
import com.chuds.sensorrecorder.core.Locked
import com.chuds.sensorrecorder.core.LogLevel
import com.chuds.sensorrecorder.core.text
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.util.Locale
import kotlin.math.max
import kotlin.math.min

data class UploadStatus(
    val enabled: Boolean = false,
    val queueCount: Int = 0,
    val failedCount: Int = 0,
    val uploadedCount: Int = 0,
    val lastSuccessUp: Double? = null,
    val lastError: String? = null,
    val currentBackoff: Double = 0.0,
    val enabledSinceUp: Double? = null,
)

/** The queue's file operations, injectable so tests can make each of them fail deterministically. */
interface QueueFiles {
    fun write(data: ByteArray, file: File)
    fun read(file: File): ByteArray
    fun delete(file: File)
    fun move(from: File, to: File)

    object Real : QueueFiles {
        override fun write(data: ByteArray, file: File) = FileUtil.writeAtomically(data, file)
        override fun read(file: File): ByteArray = file.readBytes()
        override fun delete(file: File) = Files.delete(file.toPath())
        override fun move(from: File, to: File) {
            Files.move(from.toPath(), to.toPath(), StandardCopyOption.REPLACE_EXISTING)
        }
    }
}

/** Keeps the app running after Stop until the queue is empty. Implementations must be thread-safe. */
interface BackgroundTimeProvider {
    /** [onExpire] runs if the system takes the time back first (the provider has already ended it then). */
    fun begin(onExpire: () -> Unit)
    fun end()
}

/**
 * Disk-backed upload queue (spec §6), the same rules as the iOS app's.
 *
 * - Each batch is a `.json.gz` file in `upload_queue/`, named
 *   `<createdUtcMs>_<sessionId>_<batchSeq>.json.gz` so lexical order = oldest first. The `createdMs` in a
 *   name is strictly increasing per queue (a wall clock that steps back can't reorder files).
 * - One request at a time, oldest first, never re-ordered. Exponential backoff 1 s → 30 s on failure.
 * - 2xx and 409 (duplicate) → delete. 408/429/5xx/network → retry the same file. 401/403 and batch 404 →
 *   retry (a config error must not dump the queue into `upload_failed/`). Session metadata 404/405 →
 *   retried for a while, then set aside. Other 4xx → move to `upload_failed/`.
 * - A file that can't be sent at all (a name we didn't write, or unreadable) is moved to
 *   `upload_failed/` so it never blocks the queue.
 * - Idempotency key = `sessionId:batchSeq` (also inside the body).
 * - Every 2xx/409 is recorded in `upload_acked/<sessionId>.txt` before the queue file is deleted, so the
 *   app knows which parts of a trip reached the cloud (Recap, delete guard; D55).
 * - An automatic trip's files wait in the queue for its first 2 minutes (`upload_held/<sessionId>.txt`
 *   holds the release time, D59), so a Cancel in that window can delete a trip nothing of which reached
 *   the cloud. Held files don't block other trips' files.
 */
class UploadQueue(
    private val directory: File,
    private val transport: HttpTransport = UrlConnectionTransport,
    private val uptime: () -> Double,
    private val backgroundTime: BackgroundTimeProvider? = null,
    private val files: QueueFiles = QueueFiles.Real,
    /** Wall clock for holds: they must survive a relaunch and a reboot, which reset the uptime. */
    private val nowUtcMs: () -> Long = System::currentTimeMillis,
    private val config: () -> UploadConfig,
) {
    sealed interface Outcome {
        data class Uploaded(val status: Int) : Outcome
        data object Duplicate : Outcome
        data class PermanentFailure(val status: Int) : Outcome
        data class Retry(val reason: String) : Outcome

        /** No request was made for the head file: it vanished, or it could not be read and was moved to
         *  `upload_failed/`. The next file goes next. */
        data class Skipped(val reason: String) : Outcome
        data object Disabled : Outcome
        data object Empty : Outcome
    }

    private val parent: File = directory.absoluteFile.parentFile!!
    private val failedDirectory = File(parent, "upload_failed")
    private val ackedDirectory = File(parent, "upload_acked")
    private val heldDirectory = File(parent, "upload_held")

    /**
     * Held while a file is chosen, sent and acknowledged, and while a held trip is discarded: a Cancel must
     * never delete a trip whose Start copy is on its way to the server.
     */
    private val sendLock = Any()
    private val statusBox = Locked(UploadStatus())
    private val ackLock = Any()

    /**
     * Session metadata answered 404/405 (a redeploy in progress) this many times in a row is set aside in
     * `upload_failed/`, so it never blocks the batches for good. With the 1 → 30 s backoff that is about
     * 1.5 minutes of retries. Touched by the upload thread only.
     */
    private var notFoundName = ""
    private var notFoundCount = 0

    /**
     * Files that were sent (or rejected) but could not be deleted (or moved to `upload_failed/`). They are
     * skipped instead of re-sent in a tight loop, and the delete/move is retried on every pass. In memory
     * only: after a relaunch such a file is sent once more (harmless, idempotent).
     */
    private enum class Leftover { DELETE, MOVE_TO_FAILED }
    private val leftovers = Locked<Map<String, Leftover>>(emptyMap())

    /**
     * Last `createdMs` used in a file name; names are strictly increasing so send order = enqueue order
     * even when the wall clock steps back between two enqueues (spec §6.1 ordering).
     */
    private val lastNamedMs: Locked<Long>
    private val backgroundHeld = Locked(false)
    private val backgroundLock = Any()

    @Volatile private var loop: Thread? = null
    private val wake = Object()
    private var kicked = false // under wake

    /** Set by the app after init; called from the upload thread. */
    @Volatile var onEvent: ((LogLevel, String) -> Unit)? = null

    init {
        for (d in listOf(directory, failedDirectory, ackedDirectory, heldDirectory)) d.mkdirs()
        // A half-written enqueue from a killed run; it was never queued under its final name.
        directory.listFiles().orEmpty().filter { it.name.endsWith(FileUtil.TMP_SUFFIX) }.forEach { it.delete() }
        lastNamedMs = Locked(queueFileNames(directory).mapNotNull { parseItem(it)?.createdMs }.maxOrNull() ?: 0L)
        refreshCounts()
    }

    val status: UploadStatus get() = statusBox.current

    /** Upload configured right now (API URL set). */
    val isEnabled: Boolean get() = config().isEnabled

    // Enqueue

    enum class MetaPhase(val id: String) { START("start"), STOP("stop") }

    /** What a queue file carries (spec §6 batches, §6.1 session metadata). */
    sealed interface Item {
        data class Batch(val seq: Int) : Item
        data class SessionMeta(val phase: MetaPhase) : Item
    }

    data class QueueFile(val createdMs: Long, val sessionId: String, val item: Item) {
        /** `<batchSeq>` or `meta-start|stop`: the idempotency key's second half and the ack record's line. */
        val part: String
            get() = when (item) {
                is Item.Batch -> "${item.seq}"
                is Item.SessionMeta -> "meta-${item.phase.id}"
            }
        val idempotencyKey: String get() = "$sessionId:$part"
    }

    /** Always after the previous name, so a clock step back can't sort the Stop copy before the last batch. */
    private fun nextCreatedMs(requested: Long): Long = lastNamedMs.update { max(requested, it + 1) }

    /**
     * Queues the session metadata (§6.1): `PUT /api/ingest/sessions/{id}` with the gzipped JSON body. The
     * Stop copy also holds background time until the queue is empty, and wakes the loop.
     */
    fun enqueueSessionMetadata(json: ByteArray, sessionId: String, phase: MetaPhase, createdUtcMs: Long) {
        val name = fileName(nextCreatedMs(createdUtcMs), sessionId, Item.SessionMeta(phase))
        files.write(Gzip.compress(json), File(directory, name))
        statusBox.update { it.copy(queueCount = it.queueCount + 1) }
        if (phase == MetaPhase.STOP) {
            holdBackgroundTimeUntilDrained()
            kick()
        }
    }

    fun enqueue(gzippedBody: ByteArray, sessionId: String, seq: Int, createdUtcMs: Long) {
        val name = fileName(nextCreatedMs(createdUtcMs), sessionId, Item.Batch(seq))
        files.write(gzippedBody, File(directory, name))
        statusBox.update { it.copy(queueCount = it.queueCount + 1) }
    }

    private fun queueFileNames(dir: File): List<String> = dir.list().orEmpty().filter { it.endsWith(SUFFIX) }

    /** Files waiting to be sent, in send order: only names this queue wrote and not already sent. */
    fun pendingFiles(): List<File> {
        val skip = leftovers.current
        return queueFileNames(directory).filter { parseItem(it) != null && it !in skip }.sorted().map { File(directory, it) }
    }

    fun failedFiles(): List<File> = queueFileNames(failedDirectory).sorted().map { File(failedDirectory, it) }

    /** Trips with anything still queued (batches or metadata), for Settings' "2 trips waiting". */
    fun waitingTripCount(): Int = pendingFiles().mapNotNull { parseItem(it.name)?.sessionId }.toSet().size

    private fun refreshCounts() {
        val q = pendingFiles().size
        val f = failedFiles().size
        statusBox.update { it.copy(queueCount = q, failedCount = f) }
    }

    /** Moves everything in `upload_failed/` back into the queue (operator action). */
    fun requeueFailed() {
        for (f in failedFiles()) runCatching { files.move(f, File(directory, f.name)) }
        refreshCounts()
        kick()
    }

    // Acknowledged parts (D55)

    /** Where one trip stands in the upload, from the queue, `upload_failed/` and the ack record. */
    data class TripState(
        val failedBatches: Int = 0,
        val acknowledgedBatches: Set<Int> = emptySet(),
        val stopPending: Boolean = false,
        val stopFailed: Boolean = false,
        val stopAcknowledged: Boolean = false,
        /** Anything of this trip still queued or in `upload_failed/` (batches or metadata). */
        val pendingItems: Int = 0,
        val failedItems: Int = 0,
    )

    fun tripState(sessionId: String): TripState {
        val stop = Item.SessionMeta(MetaPhase.STOP)
        val pending = pendingFiles().mapNotNull { parseItem(it.name) }.filter { it.sessionId == sessionId }
        val failed = failedFiles().mapNotNull { parseItem(it.name) }.filter { it.sessionId == sessionId }
        val (batches, stopAcked) = acknowledged(sessionId)
        return TripState(
            failedBatches = failed.count { it.item is Item.Batch },
            acknowledgedBatches = batches,
            stopPending = pending.any { it.item == stop },
            stopFailed = failed.any { it.item == stop },
            stopAcknowledged = stopAcked,
            pendingItems = pending.size,
            failedItems = failed.size,
        )
    }

    private fun ackFile(sessionId: String) = File(ackedDirectory, "$sessionId.txt")

    /** Appending the same part again (a re-send after a relaunch) is harmless. */
    private fun recordAcknowledged(file: QueueFile) {
        try {
            synchronized(ackLock) {
                val f = ackFile(file.sessionId)
                // A line torn by a power loss must not merge with this one into another batch number.
                if (f.exists()) CsvRepair.repairTornLine(f)
                FileOutputStream(f, true).use { it.write("${file.part}\n".toByteArray()) }
            }
        } catch (e: IOException) {
            // Safe direction: the trip just can't be shown as complete or deleted in the app.
            onEvent?.invoke(LogLevel.WARN, "upload: could not record that ${file.idempotencyKey} was accepted: ${e.text}")
        }
    }

    /** Accepted batch numbers, and whether the Stop copy was accepted. */
    fun acknowledged(sessionId: String): Pair<Set<Int>, Boolean> {
        val text = runCatching { synchronized(ackLock) { ackFile(sessionId).readText() } }.getOrNull() ?: return emptySet<Int>() to false
        val lines = text.split('\n').dropLast(1) // empty after the final newline, or a line still being written
        return lines.mapNotNull { it.toIntOrNull() }.toSet() to ("meta-stop" in lines)
    }

    /** After the trip's folder was deleted. */
    fun forgetAcknowledged(sessionId: String) {
        synchronized(ackLock) { ackFile(sessionId).delete() }
    }

    // Upload hold (D59)

    private fun holdFile(sessionId: String) = File(heldDirectory, "$sessionId.txt")

    /**
     * Holds the trip's files until [seconds] from now. Call before its Start copy is queued. Returns false
     * when the hold could not be written: the trip then uploads at once (never lost), and a Cancel can't
     * delete it.
     */
    fun hold(sessionId: String, seconds: Double = HOLD_SECONDS): Boolean {
        val release = nowUtcMs() + (seconds * 1000).toLong()
        return try {
            files.write(release.toString().toByteArray(), holdFile(sessionId))
            true
        } catch (e: IOException) {
            onEvent?.invoke(LogLevel.WARN, "upload: could not hold $sessionId for its first minutes: ${e.text}")
            false
        }
    }

    /** Milliseconds of hold left for the trip; null when it isn't held (or the hold ended). */
    fun holdRemainingMs(sessionId: String): Long? {
        val release = runCatching { holdFile(sessionId).readText().trim().toLong() }.getOrNull() ?: return null
        val left = release - nowUtcMs()
        // A release further away than a whole hold means the clock stepped back: end it now.
        return left.takeIf { it > 0 && it <= (HOLD_SECONDS * 1000).toLong() }
    }

    fun releaseHold(sessionId: String) {
        holdFile(sessionId).delete()
    }

    /** Sessions whose files must not be sent yet. Ended holds are removed here. */
    fun activeHolds(): Set<String> {
        val held = HashSet<String>()
        for (name in heldDirectory.list().orEmpty()) {
            if (!name.endsWith(".txt") || name.endsWith(FileUtil.TMP_SUFFIX)) continue
            val id = name.removeSuffix(".txt")
            if (holdRemainingMs(id) != null) held.add(id) else releaseHold(id)
        }
        return held
    }

    /**
     * Cancel within the hold: removes every queue file of the trip (also any in `upload_failed/`) and its
     * hold, so nothing of it is ever sent. Refuses (false) when the hold has ended or anything of the trip
     * was acknowledged; the caller then keeps the trip. Waits for a request in flight. Not on the main thread.
     */
    fun discardHeldSession(sessionId: String): Boolean = synchronized(sendLock) {
        if (holdRemainingMs(sessionId) == null) return false
        val (batches, stopAcked) = acknowledged(sessionId)
        if (batches.isNotEmpty() || stopAcked || synchronized(ackLock) { ackFile(sessionId).exists() }) return false
        val mine = { f: File -> parseItem(f.name)?.sessionId == sessionId }
        for (f in pendingFiles().filter(mine) + failedFiles().filter(mine)) {
            try {
                files.delete(f)
            } catch (e: IOException) {
                // What is left uploads after the hold, so the trip is kept: the caller must not delete it.
                onEvent?.invoke(LogLevel.WARN, "upload: could not discard ${f.name}: ${e.text}")
                refreshCounts()
                return false
            }
        }
        releaseHold(sessionId)
        refreshCounts()
        true
    }

    // Processing

    private fun makeRequest(file: QueueFile, body: ByteArray, cfg: UploadConfig): HttpRequest {
        val batch = file.item is Item.Batch
        val url = (if (batch) cfg.ingestUrl else cfg.sessionUrl(file.sessionId)) ?: throw IOException("no URL")
        return HttpRequest(
            if (batch) "POST" else "PUT", url,
            mapOf(
                "Content-Type" to "application/json", "Content-Encoding" to "gzip",
                "x-device-key" to cfg.deviceKey, "x-idempotency-key" to file.idempotencyKey,
            ),
            body, REQUEST_TIMEOUT_MS,
        )
    }

    /** Uploads the oldest queued file once. Deterministic and unit-tested; the loop calls it. */
    fun processOnce(): Outcome {
        val cfg = config()
        val now = uptime()
        statusBox.update {
            it.copy(enabled = cfg.isEnabled, enabledSinceUp = if (!cfg.isEnabled) null else if (it.enabled) it.enabledSinceUp else now)
        }
        if (!cfg.isEnabled) {
            releaseBackgroundTime()
            return Outcome.Disabled
        }
        finishLeftovers()
        setAsideForeignFiles()
        return synchronized(sendLock) { sendHead(cfg) }
    }

    private fun sendHead(cfg: UploadConfig): Outcome {
        val held = activeHolds()
        val file = pendingFiles().firstOrNull { f -> parseItem(f.name)?.sessionId !in held }
        val item = file?.let { parseItem(it.name) }
        if (file == null || item == null) {
            if (held.isEmpty()) statusBox.update { it.copy(queueCount = 0) } else refreshCounts()
            releaseBackgroundTimeIfDrained()
            return Outcome.Empty
        }
        val name = file.name

        val body = try {
            files.read(file)
        } catch (e: IOException) {
            return unreadable(file, e)
        }

        val outcome = try {
            classify(transport.send(makeRequest(item, body, cfg)), item.item is Item.SessionMeta, name)
        } catch (e: Exception) {
            Outcome.Retry("network: ${e.javaClass.simpleName}")
        }
        if (outcome !is Outcome.Retry) {
            notFoundName = ""
            notFoundCount = 0
        }

        when (outcome) {
            is Outcome.Uploaded, Outcome.Duplicate -> {
                recordAcknowledged(item)
                try {
                    files.delete(file)
                } catch (e: IOException) {
                    // Skip it from now on (no hot loop re-sending it) and keep trying to delete it.
                    leftovers.update { it + (name to Leftover.DELETE) }
                    onEvent?.invoke(LogLevel.WARN, "upload: sent $name but could not delete it: ${e.text}")
                }
                statusBox.update {
                    it.copy(uploadedCount = it.uploadedCount + 1, lastSuccessUp = uptime(), lastError = null, currentBackoff = 0.0)
                }
                refreshCounts()
            }
            is Outcome.PermanentFailure -> {
                val code = outcome.status
                if (moveToFailed(name)) {
                    onEvent?.invoke(LogLevel.WARN, "upload: $name rejected with HTTP $code, moved to upload_failed/")
                } else {
                    leftovers.update { it + (name to Leftover.MOVE_TO_FAILED) }
                    onEvent?.invoke(LogLevel.WARN, "upload: $name rejected with HTTP $code; could not move it to upload_failed/, skipping it")
                }
                statusBox.update { it.copy(lastError = "HTTP $code") }
                refreshCounts()
            }
            is Outcome.Retry -> {
                val previous = statusBox.current.lastError
                statusBox.update { it.copy(lastError = outcome.reason, currentBackoff = nextBackoff(it.currentBackoff)) }
                if (previous != outcome.reason) onEvent?.invoke(LogLevel.WARN, "upload retry: ${outcome.reason}")
            }
            else -> {}
        }
        return outcome
    }

    private fun unreadable(file: File, e: IOException): Outcome {
        // Gone (cleared while we looked) → nothing to do. Unreadable → never let it block the queue.
        if (!file.exists()) {
            refreshCounts()
            return Outcome.Skipped("${file.name} is gone")
        }
        val reason = "could not read ${file.name}: ${e.text}"
        if (moveToFailed(file.name)) {
            onEvent?.invoke(LogLevel.WARN, "upload: $reason, moved to upload_failed/")
        } else {
            leftovers.update { it + (file.name to Leftover.MOVE_TO_FAILED) }
            onEvent?.invoke(LogLevel.WARN, "upload: $reason; could not move it to upload_failed/ either, skipping it")
        }
        refreshCounts()
        return Outcome.Skipped(reason)
    }

    /** Spec §6 / §6.2 status mapping for one response to the head file. */
    private fun classify(code: Int, isMeta: Boolean, name: String): Outcome = when {
        code in 200..299 -> Outcome.Uploaded(code)
        code == 409 -> Outcome.Duplicate
        code == 401 || code == 403 -> Outcome.Retry("HTTP $code (check device key)")
        isMeta && (code == 404 || code == 405) -> {
            if (notFoundName != name) notFoundCount = 0
            notFoundName = name
            notFoundCount++
            if (notFoundCount >= MAX_METADATA_NOT_FOUND_ATTEMPTS) Outcome.PermanentFailure(code)
            else Outcome.Retry("HTTP $code on session metadata (check the API URL)")
        }
        // A wrong base path must not dump the whole queue into upload_failed/ within seconds.
        code == 404 -> Outcome.Retry("HTTP 404 (check the API URL)")
        code == 408 || code == 429 -> Outcome.Retry("HTTP $code")
        code in 400..499 -> Outcome.PermanentFailure(code)
        // 5xx (the ingest function's 503 = its own outage), 3xx (redirects are never followed): retry the
        // same file, in place, with backoff. Never re-ordered.
        else -> Outcome.Retry("HTTP $code")
    }

    /** Moves [name] from the queue to `upload_failed/` (replacing an older copy with the same name). */
    private fun moveToFailed(name: String): Boolean =
        runCatching { files.move(File(directory, name), File(failedDirectory, name)) }.isSuccess

    /** Retries the delete/move of files that were already sent or rejected. */
    private fun finishLeftovers() {
        for ((name, action) in leftovers.current) {
            val f = File(directory, name)
            val done = !f.exists() || when (action) {
                Leftover.DELETE -> runCatching { files.delete(f) }.isSuccess
                Leftover.MOVE_TO_FAILED -> moveToFailed(name)
            }
            if (done) leftovers.update { it - name }
        }
    }

    /** `.json.gz` files whose name we didn't write (a copy made over USB): moved aside instead of blocking. */
    private fun setAsideForeignFiles() {
        for (name in queueFileNames(directory)) {
            if (parseItem(name) == null && moveToFailed(name)) {
                onEvent?.invoke(LogLevel.WARN, "upload: $name is not a queue file name, moved to upload_failed/")
            }
        }
    }

    // Background time

    /** Held until [processOnce] sees an empty or disabled queue, or the system takes it back. */
    private fun holdBackgroundTimeUntilDrained() {
        val provider = backgroundTime ?: return
        if (synchronized(backgroundLock) { backgroundHeld.swap(true) }) return
        provider.begin {
            backgroundHeld.set(false)
            onEvent?.invoke(
                LogLevel.WARN,
                "upload: Android ended the background time with ${status.queueCount} file(s) queued; they are sent when the app runs again",
            )
        }
    }

    private fun releaseBackgroundTime() {
        val provider = backgroundTime ?: return
        if (synchronized(backgroundLock) { backgroundHeld.swap(false) }) provider.end()
    }

    /** The Stop copy is on disk before the hold is taken, so a listing made under the lock can't miss it. */
    private fun releaseBackgroundTimeIfDrained() = synchronized(backgroundLock) {
        if (pendingFiles().isEmpty()) releaseBackgroundTime()
    }

    val isHoldingBackgroundTime: Boolean get() = backgroundHeld.current

    // Loop

    fun start() {
        if (loop != null) return
        loop = Thread({
            while (loop === Thread.currentThread()) {
                // Anything unexpected (a listing that fails…) must not end uploading for this run.
                val wait = try {
                    when (processOnce()) {
                        // The file just handled is gone or skipped (see `leftovers`), so this never re-sends it.
                        is Outcome.Uploaded, Outcome.Duplicate, is Outcome.PermanentFailure, is Outcome.Skipped -> 0.0
                        is Outcome.Retry -> status.currentBackoff
                        Outcome.Disabled -> 2.0
                        Outcome.Empty -> 1.0
                    }
                } catch (e: Exception) {
                    onEvent?.invoke(LogLevel.ERROR, "upload loop: ${e.text}")
                    MAX_BACKOFF
                }
                if (wait > 0) sleep(wait)
            }
        }, "sensorrecorder.upload").apply { isDaemon = true; start() }
    }

    fun stop() {
        loop = null
        kick()
        releaseBackgroundTime()
    }

    /** Retry now: resets backoff and wakes the loop (Settings saved, a recording started). */
    fun kick() {
        statusBox.update { it.copy(currentBackoff = 0.0) }
        synchronized(wake) {
            kicked = true
            wake.notifyAll()
        }
    }

    /** Sleeps up to [seconds], waking early on [kick]. */
    private fun sleep(seconds: Double) = synchronized(wake) {
        if (!kicked) wake.wait((seconds * 1000).toLong())
        kicked = false
    }

    /** `detail` for logs and the preflight record; `short` is the few words Settings shows. */
    data class ProbeResult(val ok: Boolean, val detail: String, val short: String)

    companion object {
        const val MAX_METADATA_NOT_FOUND_ATTEMPTS = 8
        const val MIN_BACKOFF = 1.0
        const val MAX_BACKOFF = 30.0

        /** An automatic trip's uploads wait this long from its start (D59). */
        const val HOLD_SECONDS = 120.0
        private const val REQUEST_TIMEOUT_MS = 15_000
        private const val PROBE_TIMEOUT_MS = 8_000
        private const val SUFFIX = ".json.gz"

        fun nextBackoff(current: Double): Double = if (current <= 0) MIN_BACKOFF else min(MAX_BACKOFF, current * 2)

        /**
         * `<createdMs:13>_<sessionId>_<seq:7>.json.gz` for batches, `…_meta-<phase>.json.gz` for session
         * metadata. Lexical order = send order.
         */
        fun fileName(createdUtcMs: Long, sessionId: String, item: Item): String {
            val suffix = when (item) {
                is Item.Batch -> String.format(Locale.ROOT, "%07d", item.seq)
                is Item.SessionMeta -> "meta-" + item.phase.id
            }
            return String.format(Locale.ROOT, "%013d", createdUtcMs) + "_" + sessionId + "_" + suffix + SUFFIX
        }

        fun parseItem(fileName: String): QueueFile? {
            if (!fileName.endsWith(SUFFIX)) return null
            val parts = fileName.dropLast(SUFFIX.length).split('_')
            if (parts.size != 3 || parts[1].isEmpty()) return null
            val ms = parts[0].toLongOrNull() ?: return null
            parts[2].toIntOrNull()?.let { return QueueFile(ms, parts[1], Item.Batch(it)) }
            val phase = MetaPhase.entries.firstOrNull { parts[2] == "meta-${it.id}" } ?: return null
            return QueueFile(ms, parts[1], Item.SessionMeta(phase))
        }

        /**
         * Probe `POST {API}/api/ingest` with a deliberately invalid body. The ingest function checks the
         * key, then that the key is stored under this deviceId, then the schema, so: 400/422 = reachable +
         * key accepted for this device (the probe is rejected, never stored); 401 = unknown key; 403 = key
         * stored under another Device ID; 404 = wrong base URL. There is no `/api/health` route (02 §5).
         */
        fun testConnection(cfg: UploadConfig, deviceId: String, transport: HttpTransport = UrlConnectionTransport): ProbeResult {
            val url = cfg.ingestUrl ?: return ProbeResult(false, "upload off (no URL)", "Upload off")
            val body = Gzip.compress(Json.write(mapOf("probe" to true, "deviceId" to deviceId)).toByteArray())
            val headers = mapOf(
                "Content-Type" to "application/json", "Content-Encoding" to "gzip", "x-device-key" to cfg.deviceKey, "x-probe" to "1",
            )
            return try {
                interpretProbe(transport.send(HttpRequest("POST", url, headers, body, PROBE_TIMEOUT_MS)))
            } catch (e: Exception) {
                ProbeResult(false, "unreachable: ${e.text}", "Server unreachable")
            }
        }

        fun interpretProbe(status: Int): ProbeResult = when (status) {
            400, 422 -> ProbeResult(true, "reachable, key accepted (HTTP $status to probe)", "Connected")
            in 200..299 -> ProbeResult(true, "reachable (HTTP $status)", "Connected")
            401 -> ProbeResult(false, "device key rejected (HTTP 401)", "Wrong device key")
            403 -> ProbeResult(
                false,
                "device key is stored under another Device ID (HTTP 403): add it for this phone's Device ID (deviceId in session.json)",
                "Key belongs to another phone",
            )
            404 -> ProbeResult(false, "endpoint not found (HTTP 404): check the API URL", "Wrong server address")
            else -> ProbeResult(false, "HTTP $status from /api/ingest", "Server error (HTTP $status)")
        }
    }
}
