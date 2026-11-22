package com.chuds.sensorrecorder

import com.chuds.sensorrecorder.core.BufferedFileWriter
import com.chuds.sensorrecorder.core.Csv
import com.chuds.sensorrecorder.core.CsvRepair
import com.chuds.sensorrecorder.core.FileSink
import com.chuds.sensorrecorder.core.ISO8601
import com.chuds.sensorrecorder.core.Json
import com.chuds.sensorrecorder.core.JsonObj
import com.chuds.sensorrecorder.core.LogLevel
import com.chuds.sensorrecorder.core.RandomAccessSink
import com.chuds.sensorrecorder.core.SessionAnalyzer
import com.chuds.sensorrecorder.core.SessionMetadata
import com.chuds.sensorrecorder.core.SessionSetup
import com.chuds.sensorrecorder.core.SessionStore
import com.chuds.sensorrecorder.core.SessionWriter
import com.chuds.sensorrecorder.core.StreamFile
import com.chuds.sensorrecorder.core.StreamId
import com.chuds.sensorrecorder.core.TimeBase
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.io.IOException
import java.util.Locale
import java.util.UUID
import kotlin.concurrent.thread

class CsvTest {
    @Test fun formatsLikeTheIosApp() {
        assertEquals("0.123457", Csv.f6(0.1234567))
        assertEquals("-9.806650", Csv.f6(-9.80665))
        assertEquals("0.000000", Csv.f6(-0.0000001))
        assertEquals("-0.000001", Csv.f6(-0.0000005)) // half away from zero, as Swift's rounded()
        assertEquals("46.77121235", Csv.f8(46.771212345000001))
        assertEquals("", Csv.f6(Double.NaN))
        assertEquals("", Csv.f6(Double.POSITIVE_INFINITY))
        assertEquals("123456.789012", Csv.f6(123456.789012))
        assertEquals("1763716532120", Csv.ms(1_763_716_532_120.4))
        assertEquals(listOf("1", "0", ""), listOf(true, false, null).map { Csv.bool(it) })
        assertTrue(Csv.f6(1e15).startsWith("1000000000000000.0"))
    }

    @Test fun localeNeverChangesNumbersOrDates() {
        val old = Locale.getDefault()
        try {
            for (tag in listOf("ro-RO", "ar-EG", "fa-IR")) {
                Locale.setDefault(Locale.forLanguageTag(tag))
                assertEquals("1.500000", Csv.f6(1.5))
                assertEquals("2026-11-21T09:12:03.512Z", ISO8601.string(1_795_252_323_512L))
                assertEquals("2026-11-21T09-12-03Z", ISO8601.folderStamp(1_795_252_323_512.9))
            }
        } finally {
            Locale.setDefault(old)
        }
    }
}

class JsonTest {
    @Test fun roundTripsAndSortsKeys() {
        val s = Json.write(mapOf("b" to 1, "a" to listOf(1.5, null, true, "é\"\\\n\u0001"), "c" to mapOf("x" to 2.0)))
        assertEquals("{\"a\":[1.5,null,true,\"é\\\"\\\\\\n\\u0001\"],\"b\":1,\"c\":{\"x\":2}}", s)
        assertEquals(listOf(1.5, null, true, "é\"\\\n\u0001"), Json.parseObject(s)["a"])
        assertEquals(Json.parse(s), Json.parse(Json.write(Json.parse(s), pretty = true)))
        assertEquals(1e-6, Json.parse(Json.write(1e-6)) as Double, 0.0)
        assertEquals(1_763_716_532_000L, Json.parse("1763716532000"))
    }

    @Test fun rejectsNonFiniteAndBrokenInput() {
        assertThrows(IllegalArgumentException::class.java) { Json.write(Double.NaN) }
        for (bad in listOf("", "{", "{\"a\":}", "[1,]", "{\"a\":1}x", "\"abc", "tru", "NaN", "-")) {
            assertThrows(bad, Json.JsonException::class.java) { Json.parse(bad) }
        }
    }
}

class TimeBaseTest {
    @Test fun convertsWithTheLatestAnchor() {
        val c = FakeClock(up = 100.0, utc = 1_000_000.0)
        val tb = TimeBase(c)
        assertEquals(1_001_500.0, tb.utcMs(101.5), 1e-6)
        assertEquals(101.5, tb.uptime(1_001_500.0), 1e-9)
        c.advance(10.0)
        c.utc += 250 // NTP correction
        assertEquals(1_010_000.0, tb.utcMs(110.0), 1e-6)
        tb.refreshAnchor()
        assertEquals(1_010_250.0, tb.utcMs(110.0), 1e-6)
    }
}

class BufferedFileWriterTest {
    /** Writes [capacity] bytes, then fails ("disk full") until it grows. */
    private class FullSink(file: File, var capacity: Int) : FileSink {
        private val real = RandomAccessSink(file)
        override fun offset() = real.offset()
        override fun write(data: ByteArray) {
            val n = minOf(capacity, data.size)
            real.write(data.copyOf(n))
            capacity -= n
            if (n < data.size) throw IOException("disk full")
        }
        override fun synchronize() = real.synchronize()
        override fun close() = real.close()
    }

    @Test fun aPartialWriteIsResumedWithoutLosingOrRepeatingBytes() {
        val f = File(tempDir(), "x.csv")
        lateinit var sink: FullSink
        val w = BufferedFileWriter(f, "h") { FullSink(it, 7).also { s -> sink = s } }
        w.append("aaaa")
        w.append("bbbb")
        w.append("cccc")
        assertThrows(IOException::class.java) { w.flush() }
        w.append("dddd")
        assertThrows(IOException::class.java) { w.flush() }
        sink.capacity = 1000
        w.close()
        assertEquals("h\naaaa\nbbbb\ncccc\ndddd\n", f.readText())
        assertEquals(f.length(), w.bytesWritten)
    }

    @Test fun overTheCapOnlyWholeOldLinesAreDropped() {
        val f = File(tempDir(), "x.csv")
        lateinit var sink: FullSink
        val w = BufferedFileWriter(f, "h") { FullSink(it, 2).also { s -> sink = s } }
        w.maxRetryBytes = 10
        for (l in listOf("1111", "2222", "3333", "4444")) w.append(l)
        assertThrows(IOException::class.java) { w.flush() }
        sink.capacity = 1000
        w.close()
        assertEquals("the torn first row is ended, then the newest whole rows", "h\n11\n3333\n4444\n", f.readText())
    }

    @Test fun closeRacingAppendNeverLosesAcceptedLines() {
        repeat(50) {
            val f = File(tempDir(), "x.txt")
            val w = BufferedFileWriter(f, null)
            var accepted = 0
            val t = thread { for (i in 0 until 200) if (w.append("l$i")) accepted++ }
            w.close()
            t.join()
            assertEquals("every accepted line is in the final flush", accepted, f.readLines().size)
            assertEquals(200, accepted + w.droppedAfterClose)
        }
    }

    @Test fun neverOverwritesAnExistingFile() {
        val f = File(tempDir(), "x.csv").apply { writeText("data") }
        assertThrows(IOException::class.java) { BufferedFileWriter(f, "h") }
        assertEquals("data", f.readText())
    }
}

class SessionWriterTest {
    @Test fun writesHeadersFlushesOnItsOwnAndKeepsLateLogLines() {
        val dir = File(tempDir(), "s")
        val w = SessionWriter(dir, uptime = { 5.0 })
        w.start()
        w.append(StreamFile.CLOCK, "1.000000,2,start")
        val clock = File(dir, "clock.csv")
        val deadline = System.currentTimeMillis() + 20_000
        while (!clock.readText().contains("start") && System.currentTimeMillis() < deadline) Thread.sleep(50)
        assertEquals("t_up,t_utc_ms,source\n1.000000,2,start\n", clock.readText())
        w.close()
        w.close() // idempotent
        w.log(LogLevel.WARN, "upload retry: HTTP 503")
        w.log(LogLevel.WARN, "second")
        w.drainLateLog()
        val log = File(dir, "app_log.txt").readText()
        assertTrue(log.indexOf("[WARN] upload retry: HTTP 503") in 0 until log.indexOf("second"))
        for (f in StreamFile.entries) assertEquals(f.header, File(dir, f.fileName).readLines().first())
    }

    @Test fun aLateLineNeverRecreatesADeletedSession() {
        val dir = File(tempDir(), "s")
        val w = SessionWriter(dir, uptime = { 0.0 }, files = emptyList())
        w.close()
        dir.deleteRecursively()
        w.log(LogLevel.WARN, "late")
        w.drainLateLog()
        assertFalse(dir.exists())
    }
}

class SessionMetadataTest {
    @Test fun hasTheSpecKeysAndExplicitNulls() {
        val o = Json.parseObject(String(sampleMetadata().jsonData()))
        for (k in listOf("endedAtUtc", "stats")) assertTrue(k in o && o[k] == null)
        assertEquals(setOf("location", "phoneOrientation", "rigid", "handheld", "seatOverAxle", "photoFile"), JsonObj(o["mount"]).map.keys)
        assertTrue("photoFile" in JsonObj(o["mount"]).map && JsonObj(o["mount"]).map["photoFile"] == null)
        assertTrue("line" in JsonObj(o["vehicle"]).map)
        assertEquals("android", JsonObj(o["device"]).str("platform"))
        assertEquals("Android 16 (API 36)", JsonObj(o["device"]).str("iosVersion"))
        assertEquals(mapOf("deviceMotion" to 100.0, "accel" to 100.0, "gyro" to 100.0, "mag" to 50.0), JsonObj(o).numbers("requestedRatesHz"))
    }

    @Test fun roundTrips() {
        val m = sampleMetadata().copy(
            endedAtUtc = "2026-11-21T10:00:00.000Z", recovered = true, recoveredAtUtc = "2026-11-21T11:00:00.000Z",
            stats = sampleStats(5, 2).copy(streams = mapOf("accel" to SessionMetadata.StreamStats(1000, 99.9, 0.02, 0, 0, 100)), fileSizes = mapOf("a.csv" to 7L)),
            preflight = SessionMetadata.Preflight(
                "2026-11-21T09:12:00.000Z", true, listOf(SessionMetadata.PreflightCheckResult("gps.fix", "GPS", "fail", "x", true)),
                listOf(0.0, 0.1, -1.0), listOf(0.0, 0.0, -1.0), listOf(0.001, 0.002, 0.003), mapOf("accel" to 100.5),
            ),
        )
        val f = File(tempDir(), "session.json")
        m.write(f)
        assertEquals(m, SessionMetadata.load(f))
        assertEquals("no temp file left", listOf("session.json"), f.parentFile!!.list()!!.toList())
    }

    @Test fun filesFromOtherVersionsStillDecode() {
        val old = SessionMetadata.decode("{\"sessionId\":\"S\",\"startedAtUtc\":\"2026-11-21T09:12:03.512Z\",\"audioEnabled\":true,\"device\":{\"iosVersion\":\"18.1\"},\"stats\":{\"broken\":1}}")
        assertEquals("ios", old.device.platform)
        assertEquals("18.1", old.device.osVersion)
        assertNull(old.stats)
        assertTrue(old.mount.rigid)
        assertThrows(Json.JsonException::class.java) { SessionMetadata.decode("{\"startedAtUtc\":\"x\"}") }
    }

    @Test fun mountQualityIsNeverRemembered() {
        val stored = SessionSetup(mount = SessionMetadata.Mount(location = "dash", rigid = false, handheld = true, photoFile = "mount.jpg")).encode()
        val m = SessionSetup.decode(stored).mount
        assertEquals(SessionMetadata.Mount(location = "dash"), m)
    }
}

class SessionStoreTest {
    @Test fun folderNameFormat() {
        val id = UUID.fromString("7F3A1234-0000-0000-0000-000000000000")
        assertEquals("2026-11-21T09-12-03Z_7f3a", SessionStore.folderName(ISO8601.utcMs("2026-11-21T09:12:03.512Z")!!.toDouble(), id))
    }

    @Test fun recoveryMarksUnfinishedRepairsCsvsAndFillsStats() {
        val store = SessionStore(tempDir())
        val meta = sampleMetadata().copy(startUptimeSec = 99.0)
        val crashed = store.makeSessionFolder(1_700_000_000_000.0, UUID.randomUUID())
        meta.write(File(crashed, "session.json"))
        File(crashed, "accel_raw.csv").writeText(
            "t_up,t_utc_ms,x,y,z\n" + (0 until 200).joinToString("") { "${Csv.f6(100 + it * 0.01)},1,0.1,0.2,0.3\n" } + "102.000000,1,0.1,0.",
        )
        File(crashed, "labels.csv").writeText("t_up,t_utc_ms,type,value,note\n100.5,1,pothole,,\n101,1,note,3,\n")
        val finished = store.makeSessionFolder(1_700_001_000_000.0, UUID.randomUUID())
        meta.copy(endedAtUtc = "2026-11-21T10:00:00.000Z").write(File(finished, "session.json"))
        val active = store.makeSessionFolder(1_700_002_000_000.0, UUID.randomUUID())
        meta.write(File(active, "session.json"))
        val unreadable = store.makeSessionFolder(1_700_003_000_000.0, UUID.randomUUID())
        File(unreadable, "gyro_raw.csv").writeText("h\n1,2\n3,")

        assertEquals(listOf(crashed), store.recoverUnfinishedSessions(active))
        val r = SessionMetadata.load(File(crashed, "session.json"))
        assertTrue(r.recovered)
        assertNotNull(r.recoveredAtUtc)
        assertNull(r.endedAtUtc)
        val accel = r.stats!!.streams.getValue("accel")
        assertEquals(200, accel.samples)
        assertEquals(100.0, accel.meanRateHz, 0.01)
        assertEquals("from the session start", 2.99, r.stats!!.durationSec, 1e-6)
        assertEquals(2, r.stats!!.labelsCount)
        assertTrue(File(crashed, "accel_raw.csv").readText().endsWith("0.1,0.2,0.3\n"))
        val log = File(crashed, "app_log.txt").readText()
        assertTrue(log.contains("session recovered") && log.contains("trimmed 19 bytes"))
        assertEquals("h\n1,2\n", File(unreadable, "gyro_raw.csv").readText())
        assertFalse(SessionMetadata.load(File(finished, "session.json")).recovered)
        assertFalse(SessionMetadata.load(File(active, "session.json")).recovered)
        assertEquals("second launch: nothing more to recover", emptyList<File>(), store.recoverUnfinishedSessions(active))
        assertEquals("newest first", unreadable, store.list().first().folder)
    }

    @Test fun onlyDirectChildrenCanBeDeleted() {
        val root = tempDir()
        val store = SessionStore(File(root, "sessions").apply { mkdirs() })
        val other = File(root, "upload_queue").apply { mkdirs() }
        assertThrows(IOException::class.java) { store.deleteSession(other) }
        assertThrows(IOException::class.java) { store.deleteSession(File(store.root, "../upload_queue")) }
        assertThrows(IOException::class.java) { store.deleteSession(store.root) }
        assertTrue(other.exists() && store.root.exists())
    }

    @Test fun repairTornLineEdgeCases() {
        val f = File(tempDir(), "a.csv")
        for ((text, trimmed, left) in listOf(
            Triple("h\n1\n2\n", 0, "h\n1\n2\n"), Triple("h\n1\n2", 1, "h\n1\n"), Triple("", 0, ""), Triple("torn header", 11, ""),
            Triple("h\n" + "x".repeat(200_000), 200_000, "h\n"), // spans several chunks
        )) {
            f.writeText(text)
            assertEquals(trimmed, CsvRepair.repairTornLine(f))
            assertEquals(left, f.readText())
        }
    }

    @Test fun analyzerParsesTheFirstColumn() {
        val dir = tempDir()
        File(dir, "gyro_raw.csv").writeText("t_up,t_utc_ms,x,y,z\n1.0,0,0,0,0\n1.01,0,0,0,0\n1.02,0,0,0,0\n")
        val r = SessionAnalyzer.analyze(dir)
        assertEquals(3L, r.streams.getValue(StreamId.GYRO).count)
        assertEquals(100.0, r.streams.getValue(StreamId.GYRO).meanRateHz, 0.01)
        assertEquals(0.02, r.durationSec, 1e-9)
    }
}
