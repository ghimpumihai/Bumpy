package com.chuds.sensorrecorder

import com.chuds.sensorrecorder.core.Json
import com.chuds.sensorrecorder.core.JsonObj
import com.chuds.sensorrecorder.core.SessionMetadata
import com.chuds.sensorrecorder.core.SessionSetup
import com.chuds.sensorrecorder.core.SessionStore
import com.chuds.sensorrecorder.core.StreamFile
import com.chuds.sensorrecorder.core.StreamId
import com.chuds.sensorrecorder.core.Vec3
import com.chuds.sensorrecorder.recording.RecordingSession
import com.chuds.sensorrecorder.sensors.AltimeterSample
import com.chuds.sensorrecorder.sensors.DeviceMotionSample
import com.chuds.sensorrecorder.sensors.HeadingSample
import com.chuds.sensorrecorder.sensors.Quaternion
import com.chuds.sensorrecorder.sensors.Vec3Sample
import com.chuds.sensorrecorder.upload.BatchAccumulator
import com.chuds.sensorrecorder.upload.Gzip
import com.chuds.sensorrecorder.upload.UploadConfig
import com.chuds.sensorrecorder.upload.UploadQueue
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

private fun dm(t: Double, uaX: Double = 0.01) = DeviceMotionSample(
    t, Vec3(uaX, 0.0, 0.0), Vec3(0.0, 0.0, -1.0), Vec3.ZERO, Quaternion(1.0, 0.0, 0.0, 0.0), 0.0, 0.0, 0.0,
)

/** 2 s of every stream, as `BatchAccumulator` gets them while recording. */
private fun filledBatch(): BatchAccumulator = BatchAccumulator("00000000-0000-4000-8000-000000000001", "FIXTURE-DEVICE").apply {
    for (i in 0 until 200) {
        val t = 500 + i * 0.01
        add(dm(t, 0.0123456789))
        addAccel(Vec3Sample(t, Vec3(0.0, 0.0, -1.0)))
        addGyro(Vec3Sample(t, Vec3.ZERO))
        if (i % 2 == 0) addMag(Vec3Sample(t, Vec3(20.0, -5.0, -40.0)))
    }
    add(fix(utcMs = 1_763_716_532_120.4, lat = 46.771212345))
    add(HeadingSample(1_763_716_532_200.0, 90.0, 95.0, 10.0, Vec3(1.0, 2.0, 3.0)))
    add(AltimeterSample(500.5, 0.25, 97.1))
}

class ContractTest {
    private val fixtures = File(System.getProperty("ios.fixtures")!!)
    private fun fixture(name: String) = Json.parseObject(String(Gzip.decompress(File(fixtures, name).readBytes())))
    private val out = File(System.getProperty("contract.out")!!).apply { mkdirs() }

    /** Same keys and the same JSON type at every path; `exempt` paths are Android's own additions. */
    private fun assertSameShape(path: String, expected: Any?, actual: Any?, exempt: Set<String>) {
        when (expected) {
            is Map<*, *> -> {
                val a = actual as? Map<*, *> ?: throw AssertionError("$path is not an object")
                val extra = a.keys - expected.keys
                assertEquals("missing in $path", emptySet<Any?>(), expected.keys - a.keys)
                assertTrue("unexpected in $path: $extra", extra.all { "$path.$it" in exempt })
                for ((k, v) in expected) assertSameShape("$path.$k", v, a[k], exempt)
            }
            is List<*> -> {
                val a = actual as? List<*> ?: throw AssertionError("$path is not an array")
                if (expected.isNotEmpty() && a.isNotEmpty()) assertSameShape("$path[]", expected.first(), a.first(), exempt)
            }
            is Number -> assertTrue("$path is not a number: $actual", actual is Number)
            is String -> assertTrue("$path is not a string: $actual", actual is String)
            is Boolean -> assertTrue("$path is not a boolean: $actual", actual is Boolean)
            null -> {}
        }
    }

    @Test fun csvHeadersAreTheIosApps() {
        val pinned = Json.parseObject(File(fixtures, "csv_headers.json").readText())
        assertEquals(pinned - setOf("audio_level", "audio_segments"), StreamFile.entries.associate { it.stem to it.header })
    }

    @Test fun theBatchHasTheFixturesShape() {
        val b = filledBatch().drain(500.0, 1_763_716_532_000.0, TEST_STATUS)
        val json = b.jsonData()
        val o = Json.parseObject(String(json))
        val expected = fixture("ingest_batch_v1.json.gz")
        assertSameShape("", expected, o, emptySet())
        for (k in listOf("schemaVersion", "eventType", "source", "units", "fieldUnits")) assertEquals(k, expected[k], o[k])
        assertEquals("2025-11-21T09:15:32.000Z", o["t0Utc"])
        for (k in listOf("schemaVersion", "batchSeq", "t0UtcMs")) assertTrue("$k must be an integer", o[k] is Long)
        val motion = JsonObj(o["deviceMotion"])
        assertEquals(200, motion.list("t").size)
        assertEquals(0.01, motion.doubles("t")!![1], 1e-9)
        assertEquals(0.012346, motion.doubles("ua_x")!![0], 0.0)
        val loc = JsonObj(JsonObj(o).list("location").single())
        assertEquals(1_763_716_532_120L, loc.map["tUtcMs"])
        assertEquals(46.77121235, loc.num("lat")!!, 0.0)
        val gz = Gzip.compress(json)
        assertTrue(json.size < 60_000 && gz.size < json.size / 2)
        File(out, "batch.json.gz").writeBytes(gz)
    }

    @Test fun theStopCopyHasTheFixturesShape() {
        val meta = sampleMetadata().copy(
            endedAtUtc = "2026-11-21T10:00:00.000Z",
            people = SessionMetadata.People(raterName = "someone"),
            stats = sampleStats(2, 4).copy(
                streams = mapOf("accel" to SessionMetadata.StreamStats(1000, 99.9, 0.02, 0, 0, 100)), fileSizes = mapOf("accel_raw.csv" to 100L),
            ),
            preflight = SessionMetadata.Preflight("2026-11-21T09:12:00.000Z", false, emptyList()),
        )
        val body = RecordingSession.sessionMetadataBody(meta, 2)
        val o = Json.parseObject(String(body))
        val expected = fixture("session_meta_stop_v1.json.gz")
        assertEquals("missing", emptySet<String>(), expected.keys - o.keys - setOf("preflight", "recoveredAtUtc"))
        assertEquals("unexpected", emptySet<String>(), o.keys - expected.keys - setOf("preflight"))
        for (k in listOf("vehicle", "mount", "people", "conditions")) assertEquals(k, JsonObj(expected[k]).map.keys, JsonObj(o[k]).map.keys)
        assertEquals(setOf("osVersion", "platform"), JsonObj(o["device"]).map.keys - JsonObj(expected["device"]).map.keys)
        assertEquals(JsonObj(expected["stats"]).map.keys, JsonObj(o["stats"]).map.keys)
        assertEquals(2L, o["batchCount"])
        assertEquals("live", o["source"])
        assertFalse("personal data stays on the phone", String(body).contains("raterName"))
        assertFalse("local only (D55)", String(body).contains("uploadWindowsNotQueued"))
        assertTrue(String(meta.jsonData()).contains("uploadWindowsNotQueued"))
        File(out, "session_stop.json.gz").writeBytes(Gzip.compress(body))
        // An automatic trip's Start copy (D59), so check_contract.py also runs `autoStart` through the validator.
        val auto = sampleMetadata().copy(autoStart = SessionMetadata.AutoStart("2026-11-21T09:12:00.000Z"))
        File(out, "session_start.json.gz").writeBytes(Gzip.compress(RecordingSession.sessionMetadataBody(auto, null)))
    }

    /** One bad value rejects the whole batch, so a NaN/Inf sample is left out or sent as -1. */
    @Test fun nonFiniteValuesNeverReachTheBatchAndArraysStayAligned() {
        val nan = Double.NaN
        val acc = BatchAccumulator("S", "D")
        acc.add(dm(100.00))
        acc.add(dm(100.01, nan))
        acc.add(dm(100.02, Double.POSITIVE_INFINITY))
        acc.add(dm(100.03))
        acc.addAccel(Vec3Sample(100.0, Vec3(nan, 0.0, -1.0)))
        acc.addAccel(Vec3Sample(100.01, Vec3(0.0, 0.0, -1.0)))
        acc.addMag(Vec3Sample(100.0, Vec3(1.0, 2.0, Double.NEGATIVE_INFINITY)))
        acc.add(fix())
        acc.add(fix(lat = nan)) // no position: left out
        acc.add(fix(lat = -180.0, lon = -180.0))
        acc.add(fix(alt = nan, hAcc = nan, speed = nan, course = Double.POSITIVE_INFINITY)) // kept, invalid values as -1
        acc.add(HeadingSample(1.0, 10.0, nan, nan, Vec3(1.0, 2.0, 3.0)))
        acc.add(HeadingSample(1.0, 10.0, 12.0, 5.0, Vec3(nan, 2.0, 3.0)))
        acc.add(AltimeterSample(100.0, 0.1, nan))
        acc.add(AltimeterSample(100.5, 0.2, 97.2))
        val o = Json.parseObject(String(acc.drain(100.0, 1_763_716_532_000.0, TEST_STATUS.copy(batteryLevel = Float.NaN)).jsonData()))
        val motion = JsonObj(o["deviceMotion"])
        assertEquals("left out, not sent as 0", listOf(0.0, 0.03), motion.doubles("t"))
        assertTrue(motion.map.values.all { (it as List<*>).size == 2 })
        assertEquals(listOf(0.01), JsonObj(o["accelRaw"]).doubles("t"))
        assertTrue(JsonObj(o["magRaw"]).list("z").isEmpty())
        val locations = JsonObj(o).list("location").map { JsonObj(it) }
        assertEquals(2, locations.size)
        assertEquals(listOf(-1.0, -1.0, -1.0, -1.0, 0.0), listOf("hAcc", "speed", "course", "vAcc", "alt").map { locations[1].num(it) })
        val heading = JsonObj(JsonObj(o).list("heading").single())
        assertEquals(listOf(-1.0, -1.0), listOf(heading.num("trueHeading"), heading.num("headingAcc")))
        assertEquals(listOf(0.5), JsonObj(o["altimeter"]).doubles("t"))
        assertEquals(-1.0, JsonObj(o["device"]).num("battery")!!, 0.0)
    }

    @Test fun aNumberIsUsedOnlyOnceItsBatchIsQueued() {
        val acc = filledBatch()
        assertEquals(0, acc.drain(0.0, 0.0, TEST_STATUS).batchSeq)
        assertEquals("not queued yet", 0, acc.drain(2.0, 0.0, TEST_STATUS).batchSeq)
        acc.markQueued(0)
        acc.markQueued(0)
        assertEquals(1, acc.nextSeq)
    }
}

class RecordingSessionTest {
    private val root = tempDir()
    private val files = FlakyFiles()
    private var config = UploadConfig("https://api.test", "k")
    private val queue = UploadQueue(File(root, "upload_queue"), MockTransport(), uptime = JvmClock::uptime, files = files) { config }
    private val store = SessionStore(File(root, "sessions"))

    private fun session(location: Boolean = true) = RecordingSession(
        store, SessionSetup(mount = SessionMetadata.Mount(photoFile = "mount.jpg")), null,
        RecordingSession.Dependencies(
            motion = SyntheticMotionSource(), location = if (location) FakeLocationSource() else null, altimeter = FakeAltimeter(),
            deviceStatus = FakeDeviceStatus(), uploadQueue = queue, clock = JvmClock, deviceId = "DEV-1", appVersion = "1.0.0 (1) test",
            deviceInfo = SessionMetadata.Device("x", "x", "x"),
        ),
    )

    private fun queued() = queue.pendingFiles().map { UploadQueue.parseItem(it.name)!!.item to Json.parseObject(String(Gzip.decompress(it.readBytes()))) }

    @Test fun threeSecondRecordingProducesAValidSession() {
        val s = session()
        val metaFile = File(s.folder, "session.json")
        val initial = SessionMetadata.load(metaFile)
        assertNull(initial.endedAtUtc)
        assertTrue(initial.syntheticSensors)
        assertNull("no mount photo since D51", initial.mount.photoFile)
        s.start()
        Thread.sleep(3200)
        val inputs = s.healthInputs(JvmClock.uptime())
        for (id in StreamId.entries.filter { it.isMotion }) assertTrue(id.id, inputs.streams.getValue(id).count > 0)
        assertNotNull(inputs.gpsLastFixUp)
        val meta = s.stop()
        assertEquals("idempotent", meta, s.stop())
        assertEquals(meta, SessionMetadata.load(metaFile))
        val stats = meta.stats!!
        assertTrue(stats.durationSec in 3.19..30.0)
        assertTrue(stats.uploadBatchesCreated > 1)
        assertNull("every window was queued", stats.uploadWindowsNotQueued)
        assertNull("no Play Services", stats.streams["activity"])

        val clock = readCsv(File(s.folder, "clock.csv"))
        assertEquals("start", clock.rows.first()[2])
        assertEquals("stop", clock.rows.last()[2])
        val anchorUp = clock.rows[0][0].toDouble()
        val anchorMs = clock.rows[0][1].toDouble()
        for (id in StreamId.entries.filter { it.isMotion }) {
            val csv = readCsv(File(s.folder, id.file.fileName))
            assertTrue(csv.rows.size > 10 && csv.rows.all { it.size == csv.header.size })
            val t = csv.rows.map { it[0].toDouble() }
            assertEquals("${id.id} t_up must be monotonic", t.sorted(), t)
            for (r in csv.rows.take(50)) assertEquals(anchorMs + (r[0].toDouble() - anchorUp) * 1000, r[1].toDouble(), 20.0)
            assertEquals(id.id, csv.rows.size.toLong(), stats.streams.getValue(id.id).samples)
        }
        val loc = readCsv(File(s.folder, "location.csv"))
        assertTrue(loc.rows.size >= 3)
        assertEquals("46.77131000", loc.rows[0][2])
        assertEquals("0", loc.rows[0][12])
        assertTrue(readCsv(File(s.folder, "altimeter.csv")).rows.size >= 3)
        assertTrue(readCsv(File(s.folder, "device.csv")).rows.isNotEmpty())
        for (f in listOf(StreamFile.LABELS, StreamFile.ACTIVITY, StreamFile.ABS_ALTITUDE)) assertEquals(f.header + "\n", File(s.folder, f.fileName).readText())

        // Send order: Start copy, batches 0..n-1, Stop copy with batchCount = n (§6.1)
        val all = queued()
        assertEquals(UploadQueue.Item.SessionMeta(UploadQueue.MetaPhase.START), all.first().first)
        assertEquals(UploadQueue.Item.SessionMeta(UploadQueue.MetaPhase.STOP), all.last().first)
        val batches = all.filter { it.first is UploadQueue.Item.Batch }.map { it.second }
        assertEquals(batches.indices.map { it.toLong() }, batches.map { it["batchSeq"] })
        assertEquals(stats.uploadBatchesCreated, batches.size)
        assertEquals(batches.size.toLong(), all.last().second["batchCount"])
        assertFalse("batchCount" in all.first().second)
        assertTrue(all.all { it.second["sessionId"] == s.sessionId && s.sessionId == s.sessionId.uppercase() })
        for ((id, block) in listOf(StreamId.DEVICE_MOTION to "deviceMotion", StreamId.ACCEL to "accelRaw", StreamId.GYRO to "gyroRaw", StreamId.MAG to "magRaw")) {
            assertEquals(
                "every $block sample is in exactly one batch",
                readCsv(File(s.folder, id.file.fileName)).rows.size, batches.sumOf { JsonObj(it[block]).list("t").size },
            )
        }
        val log = File(s.folder, "app_log.txt").readText()
        assertTrue(log.contains("recording started") && log.contains("recording stopped"))
        assertEquals(emptyList<File>(), store.recoverUnfinishedSessions())
    }

    @Test fun aFullDiskLeavesNoHoleInTheBatchNumbers() {
        val s = session(location = false)
        s.start()
        files.failWrite = true
        Thread.sleep(2500) // one window can't be queued
        files.failWrite = false
        Thread.sleep(2200) // it goes first at the next tick
        val meta = s.stop()
        val batches = queued().filter { it.first is UploadQueue.Item.Batch }.map { it.second }
        assertEquals(batches.indices.map { it.toLong() }, batches.map { it["batchSeq"] })
        assertNull(meta.stats!!.uploadWindowsNotQueued)
        assertEquals(readCsv(File(s.folder, "device_motion.csv")).rows.size, batches.sumOf { JsonObj(it["deviceMotion"]).list("t").size })
    }

    @Test fun windowsThatCanNotBeQueuedAreCountedAndNotPromised() {
        val s = session(location = false)
        s.start()
        files.failWrite = true
        Thread.sleep(2500)
        val meta = s.stop()
        assertEquals(0, meta.stats!!.uploadBatchesCreated)
        assertEquals(2, meta.stats!!.uploadWindowsNotQueued)
    }

    @Test fun uploadOffCountsItsWindowsAndQueuesNothing() {
        config = UploadConfig.DISABLED
        val s = session(location = false)
        s.start()
        val meta = s.stop()
        assertEquals(0, meta.stats!!.uploadBatchesCreated)
        assertTrue(meta.stats!!.uploadWindowsNotQueued!! >= 1)
        assertTrue(queue.pendingFiles().isEmpty())
    }

    @Test fun backgroundTripsAreNotedOnceEachWay() {
        val s = session(location = false)
        s.start()
        s.noteLifecycle(background = false) // a first "visible" is not a return
        assertNull(s.latest.returnedFromBackgroundUp)
        repeat(2) { s.noteLifecycle(background = true) }
        repeat(2) { s.noteLifecycle(background = false) }
        s.stop()
        val sources = readCsv(File(s.folder, "clock.csv")).rows.map { it[2] }
        assertEquals(1, sources.count { it == "background" })
        assertEquals(1, sources.count { it == "foreground" })
    }

    @Test fun staleCachedFixesAreDropped() {
        val s = RecordingSession(
            store, SessionSetup(), null,
            RecordingSession.Dependencies(
                motion = SyntheticMotionSource(),
                location = object : com.chuds.sensorrecorder.sensors.LocationSource {
                    override fun startRecording(callbacks: com.chuds.sensorrecorder.sensors.LocationCallbacks) {
                        callbacks.location(fix(utcMs = System.currentTimeMillis() - 60_000.0))
                        callbacks.location(fix(utcMs = System.currentTimeMillis() - 3_000.0))
                    }
                    override fun stopRecording() {}
                },
                altimeter = null, deviceStatus = FakeDeviceStatus(), uploadQueue = null, clock = JvmClock, deviceId = "D", appVersion = "t",
                deviceInfo = SessionMetadata.Device("x", "x", "x"),
            ),
        )
        s.start()
        assertNull("a fix from before the start is written but is not a live fix", s.latest.gps)
        s.stop()
        assertEquals(1, readCsv(File(s.folder, "location.csv")).rows.size)
    }
}
