package com.chuds.sensorrecorder

import com.chuds.sensorrecorder.core.Json
import com.chuds.sensorrecorder.core.JsonObj
import com.chuds.sensorrecorder.core.SessionMetadata
import com.chuds.sensorrecorder.core.SessionSetup
import com.chuds.sensorrecorder.core.SessionStore
import com.chuds.sensorrecorder.recording.AutoTripRules
import com.chuds.sensorrecorder.recording.RecordingSession
import com.chuds.sensorrecorder.upload.Gzip
import com.chuds.sensorrecorder.upload.UploadConfig
import com.chuds.sensorrecorder.upload.UploadQueue
import com.chuds.sensorrecorder.upload.UploadQueue.MetaPhase
import com.chuds.sensorrecorder.upload.UploadQueue.Outcome
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/** D59: the upload hold and Cancel of an automatic trip (data path). */
class UploadHoldTest {
    private val root = tempDir()
    private val dir = File(root, "upload_queue")
    private val transport = MockTransport()
    private val files = FlakyFiles()
    private var now = 1_763_716_323_000L
    private val q = makeQueue()

    private fun makeQueue() = UploadQueue(dir, transport, uptime = { 1.0 }, files = files, nowUtcMs = { now }) {
        UploadConfig("https://example.test", "k")
    }

    private fun batch(session: String, seq: Int) = q.enqueue(Gzip.compress("{}".toByteArray()), session, seq, now)
    private fun meta(session: String, phase: MetaPhase) = q.enqueueSessionMetadata("{}".toByteArray(), session, phase, now)

    @Test fun heldFilesWaitTwoMinutesWithoutBlockingOtherTrips() {
        assertTrue(q.hold("A"))
        meta("A", MetaPhase.START)
        batch("A", 0)
        batch("B", 0)
        assertEquals(Outcome.Uploaded(200), q.processOnce())
        assertEquals(listOf("B:0"), transport.keys)
        assertEquals(Outcome.Empty, q.processOnce())
        assertEquals("held files still count as queued", 2, q.status.queueCount)

        now += 60_000
        val relaunched = makeQueue() // the hold is on disk
        assertEquals(Outcome.Empty, relaunched.processOnce())

        now += 61_000
        assertEquals(Outcome.Uploaded(200), relaunched.processOnce())
        assertEquals(Outcome.Uploaded(200), relaunched.processOnce())
        assertEquals("order within the trip kept", listOf("B:0", "A:meta-start", "A:0"), transport.keys)
        assertTrue(relaunched.activeHolds().isEmpty())
        assertFalse("an ended hold is removed", File(root, "upload_held/A.txt").exists())
    }

    @Test fun aHoldEndingMoreThanTwoMinutesAheadEndsNow() {
        q.hold("A")
        batch("A", 0)
        now -= 10 * 60_000 // the wall clock stepped back
        assertNull(q.holdRemainingMs("A"))
        assertEquals(Outcome.Uploaded(200), q.processOnce())
    }

    @Test fun cancelWithinTheHoldRemovesEveryPartOfTheTrip() {
        q.hold("A")
        meta("A", MetaPhase.START)
        batch("A", 0)
        batch("B", 0)
        meta("A", MetaPhase.STOP)
        now += 100_000
        assertTrue(q.discardHeldSession("A"))
        assertEquals(listOf("B"), q.pendingFiles().map { UploadQueue.parseItem(it.name)!!.sessionId })
        assertNull(q.holdRemainingMs("A"))
        repeat(3) { q.processOnce() }
        assertEquals(listOf("B:0"), transport.keys)
        assertEquals(UploadQueue.TripState(), q.tripState("A"))
    }

    @Test fun cancelAfterTheHoldKeepsTheTrip() {
        q.hold("A")
        batch("A", 0)
        now += 121_000
        assertFalse(q.discardHeldSession("A"))
        assertEquals(1, q.pendingFiles().size)
    }

    @Test fun cancelKeepsATripPartOfWhichReachedTheServer() {
        batch("A", 0) // the hold could not be written: sent at once
        q.processOnce()
        q.hold("A") // what Cancel does before stopping the trip
        meta("A", MetaPhase.STOP)
        assertFalse(q.discardHeldSession("A"))
        assertEquals(1, q.pendingFiles().size)
    }

    @Test fun aFileThatCantBeDeletedKeepsTheTrip() {
        q.hold("A")
        batch("A", 0)
        files.failDelete = true
        assertFalse(q.discardHeldSession("A"))
        files.failDelete = false
        assertEquals(1, q.pendingFiles().size)
    }

    @Test fun aLateCancelIsWrittenIntoSessionJsonAndTheStopCopy() {
        val queue = UploadQueue(File(root, "q2/upload_queue"), MockTransport(), uptime = JvmClock::uptime) { UploadConfig("https://example.test", "k") }
        val s = RecordingSession(
            SessionStore(File(root, "sessions")), SessionSetup(), null,
            RecordingSession.Dependencies(
                motion = SyntheticMotionSource(), location = FakeLocationSource(), altimeter = FakeAltimeter(),
                deviceStatus = FakeDeviceStatus(), uploadQueue = queue, clock = JvmClock, deviceId = "DEV",
                appVersion = "1.0.0 (1) test", deviceInfo = SessionMetadata.Device("x", "x", "x"),
            ),
            autoStart = SessionMetadata.AutoStart("2026-11-21T09:12:00.000Z"),
        )
        val start = Json.parseObject(String(Gzip.decompress(queue.pendingFiles().first().readBytes())))
        assertEquals(mapOf("detectedAtUtc" to "2026-11-21T09:12:00.000Z"), start["autoStart"])
        s.start()
        Thread.sleep(300)
        s.markAutoCancelled("2026-11-21T09:20:00.000Z")
        val meta = s.stop()
        assertEquals(SessionMetadata.AutoStart("2026-11-21T09:12:00.000Z", "2026-11-21T09:20:00.000Z"), meta.autoStart)
        assertEquals(meta.autoStart, SessionMetadata.load(File(s.folder, "session.json")).autoStart)
        val stopFile = queue.pendingFiles().last { UploadQueue.parseItem(it.name)!!.item == UploadQueue.Item.SessionMeta(MetaPhase.STOP) }
        val stop = JsonObj(Json.parseObject(String(Gzip.decompress(stopFile.readBytes()))))
        assertEquals("2026-11-21T09:20:00.000Z", stop.obj("autoStart").str("cancelledAtUtc"))
    }

    @Test fun manualTripsHaveNoAutoStartKey() {
        assertFalse("autoStart" in sampleMetadata().json())
        val auto = sampleMetadata().copy(autoStart = SessionMetadata.AutoStart("2026-11-21T09:12:00.000Z"))
        assertEquals(auto.autoStart, SessionMetadata.decode(String(auto.jsonData())).autoStart)
        assertFalse("cancelledAtUtc is omitted until a Cancel", String(auto.jsonData()).contains("cancelledAtUtc"))
    }
}

/** D59: when an automatic trip starts and stops. */
class AutoTripRulesTest {
    private val r = AutoTripRules()

    /** GPS at 1 Hz with [speed] from [from] for [seconds]. */
    private fun drive(from: Double, seconds: Int, speed: Double) {
        for (i in 0..seconds) r.onGpsFix(from + i, speed)
    }

    @Test fun startsAfter30sAbove20KmhWithoutSteps() {
        drive(1000.0, 29, 8.0)
        assertTrue(r.isCandidate(1029.0))
        assertFalse(r.shouldStart(1029.0))
        drive(1030.0, 2, 8.0)
        assertTrue(r.shouldStart(1031.0))
    }

    @Test fun stopAndGoCountsWithin90s() {
        drive(1000.0, 15, 8.0)
        drive(1016.0, 30, 1.0) // red light
        drive(1047.0, 16, 8.0)
        assertTrue(r.fastSeconds(1063.0) >= 30)
        assertTrue(r.shouldStart(1063.0))
        r.reset()
        drive(1000.0, 15, 8.0)
        drive(1016.0, 80, 1.0)
        drive(1097.0, 16, 8.0)
        assertFalse("the first stretch left the 90 s window", r.shouldStart(1113.0))
    }

    @Test fun stepsInTheLastMinuteMeanNoCandidate() {
        r.onStep(990.0)
        drive(1000.0, 40, 8.0) // a cyclist would pass: Android has no activity recognition without Play Services
        assertFalse(r.isCandidate(1040.0))
        assertFalse(r.shouldStart(1040.0))
        drive(1041.0, 10, 8.0)
        assertTrue(r.shouldStart(1051.0))
    }

    @Test fun coarseFixesWithoutSpeedMakeACandidateOnlyBeyondTheirError() {
        r.onCoarseFix(AutoTripRules.CoarseFix(1000.0, 46.77, 23.62, 100.0, -1.0))
        r.onCoarseFix(AutoTripRules.CoarseFix(1020.0, 46.7705, 23.62, 100.0, -1.0)) // 56 m, inside the error
        assertFalse(r.isCandidate(1020.0))
        r.onCoarseFix(AutoTripRules.CoarseFix(1040.0, 46.775, 23.62, 100.0, -1.0)) // ~500 m in 20 s
        assertTrue(r.isCandidate(1040.0))
        assertFalse("3 min without movement", r.isCandidate(1040.0 + AutoTripRules.CANDIDATE_TIMEOUT_S + 1))
    }

    @Test fun stopsAfter10MinutesSlow() {
        drive(1000.0, 40, 8.0)
        r.tripStarted(1040.0)
        drive(1041.0, 300, 1.0)
        assertFalse(r.shouldStop(1341.0))
        drive(1342.0, 10, 3.0) // moving again resets the 10 min
        drive(1353.0, 590, 1.0)
        assertFalse(r.shouldStop(1943.0))
        assertTrue(r.shouldStop(1953.0))
    }

    @Test fun stopsAfter60sOfWalkingBelow2ms() {
        r.tripStarted(1000.0)
        drive(1001.0, 100, 8.0)
        for (i in 0..59) {
            r.onStep(1102.0 + i)
            r.onGpsFix(1102.0 + i, 1.2)
        }
        assertFalse(r.shouldStop(1161.0))
        r.onStep(1162.0)
        assertTrue(r.shouldStop(1162.0))
    }

    @Test fun swayingInATramAtSpeedIsNotWalking() {
        r.tripStarted(1000.0)
        for (i in 0..120) {
            r.onStep(1001.0 + i)
            r.onGpsFix(1001.0 + i, 7.0)
        }
        assertFalse(r.shouldStop(1121.0))
    }

    @Test fun manualTripsNeverStop() {
        drive(1000.0, 1000, 0.0)
        assertFalse(r.shouldStop(2000.0))
    }
}
