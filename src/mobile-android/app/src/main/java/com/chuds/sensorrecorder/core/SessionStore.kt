package com.chuds.sensorrecorder.core

import java.io.File
import java.io.IOException
import java.io.RandomAccessFile
import java.util.UUID
import kotlin.math.max

/** Lists, creates and recovers session folders under `sessions/`. */
class SessionStore(val root: File) {
    fun ensureRoot() {
        if (!root.isDirectory && !root.mkdirs()) throw IOException("could not create ${root.path}")
    }

    /** Permanently deletes a session folder. Only folders directly inside [root] can be deleted. */
    fun deleteSession(folder: File) {
        if (folder.canonicalFile.parentFile != root.canonicalFile) throw IOException("not a session folder: ${folder.path}")
        if (!folder.deleteRecursively()) throw IOException("could not delete ${folder.path}")
    }

    fun makeSessionFolder(startUtcMs: Double, id: UUID): File {
        ensureRoot()
        val dir = File(root, folderName(startUtcMs, id))
        if (!dir.mkdir()) throw IOException("could not create ${dir.path}")
        return dir
    }

    data class Entry(val folder: File, val metadata: SessionMetadata?)

    fun list(): List<Entry> = root.listFiles().orEmpty()
        .filter { it.isDirectory }
        .map { entry(it) }
        .sortedByDescending { it.folder.name } // newest first (name starts with UTC stamp)

    fun entry(folder: File) =
        Entry(folder, runCatching { SessionMetadata.load(File(folder, SessionFileName.METADATA)) }.getOrNull())

    /**
     * Spec §4: on launch, any session folder whose `session.json` lacks `endedAtUtc` was interrupted
     * (crash, kill, battery). Mark it `recovered: true`, repair torn last lines in CSVs, fill stats
     * from the files, and keep it. [active] protects a session that is currently recording.
     */
    fun recoverUnfinishedSessions(active: File? = null, nowMs: Long = System.currentTimeMillis()): List<File> {
        val recovered = ArrayList<File>()
        for (e in list()) {
            if (e.folder == active) continue
            val meta = e.metadata
            if (meta == null) {
                // Unreadable/missing session.json: we can't mark it, but torn CSV rows are still repaired
                // (idempotent) so the data stays parseable, and the folder is never deleted.
                val repairs = CsvRepair.repairTornLines(e.folder)
                if (repairs.isNotEmpty()) appendRecoveryNote(e.folder, repairs, nowMs, unreadable = true)
                continue
            }
            if (meta.endedAtUtc != null || meta.recovered) continue
            val repairs = CsvRepair.repairTornLines(e.folder)
            appendRecoveryNote(e.folder, repairs, nowMs, unreadable = false)
            val analysis = SessionAnalyzer.analyze(e.folder) // after the note: sizes include it
            var stats = analysis.asStats()
            // Duration from the real session start (not from a stream's first row).
            val last = analysis.lastSampleUp
            if (meta.startUptimeSec > 0 && last != null && last > meta.startUptimeSec) {
                stats = stats.copy(durationSec = last - meta.startUptimeSec)
            }
            try {
                meta.copy(recovered = true, recoveredAtUtc = ISO8601.string(nowMs), stats = stats)
                    .write(File(e.folder, SessionFileName.METADATA))
                recovered.add(e.folder)
            } catch (x: IOException) {
                AppLog.log(LogLevel.ERROR, "recovery of ${e.folder.name} failed: ${x.text}")
            }
        }
        return recovered
    }

    private fun appendRecoveryNote(folder: File, repairs: Map<String, Int>, nowMs: Long, unreadable: Boolean) {
        val now = ISO8601.string(nowMs)
        val text = StringBuilder(
            if (unreadable) "$now [WARN] session.json missing/unreadable; CSV files repaired only\n"
            else "$now [WARN] session recovered on next launch (app was terminated while recording)\n",
        )
        for ((file, bytes) in repairs.toSortedMap()) {
            text.append("$now [WARN] recovery: trimmed $bytes bytes of incomplete last line from $file\n")
        }
        runCatching { File(folder, SessionFileName.APP_LOG).appendText(text.toString()) }
    }

    companion object {
        fun shortId(id: UUID): String = id.toString().lowercase().take(4)
        fun folderName(startUtcMs: Double, id: UUID) = "${ISO8601.folderStamp(startUtcMs)}_${shortId(id)}"
    }
}

object CsvRepair {
    private const val CHUNK = 64L * 1024

    /**
     * If a CSV does not end with a newline (process died mid-write), truncate the incomplete last
     * line so every parser can read the file. Returns trimmed byte counts per file.
     */
    fun repairTornLines(folder: File): Map<String, Int> {
        val out = HashMap<String, Int>()
        for (f in folder.listFiles().orEmpty().filter { it.extension == "csv" }) {
            val trimmed = runCatching { repairTornLine(f) }.getOrDefault(0)
            if (trimmed > 0) out[f.name] = trimmed
        }
        return out
    }

    /** Returns the number of bytes trimmed (0 if the file was fine). */
    fun repairTornLine(file: File): Int = RandomAccessFile(file, "rw").use { f ->
        val size = f.length()
        var pos = size
        var keep = 0L
        // Scan backwards in chunks for the last '\n'.
        while (pos > 0) {
            val start = max(0L, pos - CHUNK)
            val buf = ByteArray((pos - start).toInt())
            f.seek(start)
            f.readFully(buf)
            val idx = buf.lastIndexOf('\n'.code.toByte())
            if (idx >= 0) {
                keep = start + idx + 1
                break
            }
            pos = start
        }
        if (keep < size) f.setLength(keep)
        (size - keep).toInt()
    }
}
