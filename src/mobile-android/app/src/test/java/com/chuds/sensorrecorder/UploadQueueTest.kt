package com.chuds.sensorrecorder

import com.chuds.sensorrecorder.core.SessionMetadata
import com.chuds.sensorrecorder.upload.Gzip
import com.chuds.sensorrecorder.upload.TripCloudCopy
import com.chuds.sensorrecorder.upload.UploadConfig
import com.chuds.sensorrecorder.upload.UploadQueue
import com.chuds.sensorrecorder.upload.UploadQueue.MetaPhase
import com.chuds.sensorrecorder.upload.UploadQueue.Outcome
import com.chuds.sensorrecorder.upload.UrlConnectionTransport
import com.chuds.sensorrecorder.upload.HttpRequest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.io.IOException
import java.net.ServerSocket
import kotlin.concurrent.thread

class UploadQueueTest {
    private val dir = File(tempDir(), "upload_queue")
    private val transport = MockTransport()
    private val files = FlakyFiles()
    private var config = UploadConfig("https://example.test/base", "secret")
    private val background = FakeBackgroundTime()
    private val q = makeQueue()
    private val body = Gzip.compress("{}".toByteArray())

    private fun makeQueue() = UploadQueue(dir, transport, uptime = { 1.0 }, backgroundTime = background, files = files) { config }

    private fun batch(seq: Int, session: String = "S1", created: Long = 1_700_000_000_000 + seq) =
        q.enqueue(Gzip.compress("{\"batchSeq\":$seq}".toByteArray()), session, seq, created)

    private fun meta(phase: MetaPhase, session: String = "S1", created: Long = 1) =
        q.enqueueSessionMetadata("{}".toByteArray(), session, phase, created)

    private fun process(n: Int) = List(n) { q.processOnce() }
    private fun names() = dir.list()!!.filter { it.endsWith(".json.gz") }

    @Test fun fileNameRoundTrip() {
        val n = UploadQueue.fileName(1_700_000_000_123, "AB-CD", UploadQueue.Item.Batch(42))
        assertEquals("1700000000123_AB-CD_0000042.json.gz", n)
        assertEquals(UploadQueue.QueueFile(1_700_000_000_123, "AB-CD", UploadQueue.Item.Batch(42)), UploadQueue.parseItem(n))
        assertEquals("S:meta-stop", UploadQueue.parseItem(UploadQueue.fileName(1, "S", UploadQueue.Item.SessionMeta(MetaPhase.STOP)))!!.idempotencyKey)
        for (bad in listOf("x.json.gz", "1_S_0000042 2.json.gz", "1_S_meta-x.json.gz", "1__2.json.gz", "1_S_2.json")) assertNull(bad, UploadQueue.parseItem(bad))
    }

    @Test fun requestFormat() {
        batch(7)
        transport.enqueue(201)
        assertEquals(Outcome.Uploaded(201), q.processOnce())
        val r = transport.requests.single()
        assertEquals("POST", r.method)
        assertEquals("https://example.test/base/api/ingest", r.url)
        assertEquals(
            mapOf("Content-Type" to "application/json", "Content-Encoding" to "gzip", "x-device-key" to "secret", "x-idempotency-key" to "S1:7"),
            r.headers,
        )
        assertEquals("{\"batchSeq\":7}", String(Gzip.decompress(r.body)))
        assertEquals(0, q.pendingFiles().size)
        assertNotNull(q.status.lastSuccessUp)
        meta(MetaPhase.START)
        q.processOnce()
        assertEquals("PUT https://example.test/base/api/ingest/sessions/S1", transport.requests.last().let { "${it.method} ${it.url}" })
    }

    @Test fun oldestFirstEvenWhenTheWallClockStepsBack() {
        for (seq in 0..2) batch(seq, created = 1_700_000_000_000 - seq * 5_000L)
        process(3)
        assertEquals(listOf("S1:0", "S1:1", "S1:2"), transport.keys)
        assertEquals(Outcome.Empty, q.processOnce())
    }

    @Test fun duplicate409IsSuccess() {
        batch(0)
        transport.enqueue(409)
        assertEquals(Outcome.Duplicate, q.processOnce())
        assertTrue(q.pendingFiles().isEmpty() && q.failedFiles().isEmpty())
    }

    @Test fun other4xxMovesToFailedAndContinues() {
        batch(0)
        batch(1)
        transport.enqueue(400, 200)
        assertEquals(Outcome.PermanentFailure(400), q.processOnce())
        assertEquals(1, q.status.failedCount)
        assertEquals(Outcome.Uploaded(200), q.processOnce())
        q.requeueFailed()
        assertEquals(1, q.pendingFiles().size)
        assertTrue(q.failedFiles().isEmpty())
    }

    @Test fun serverErrorsAndNetworkFailuresRetryWithBackoff() {
        batch(0)
        transport.enqueue(500, 503)
        transport.enqueueError(IOException("offline"))
        transport.enqueue(429, 401)
        val backoffs = List(5) {
            assertTrue(q.processOnce() is Outcome.Retry)
            q.status.currentBackoff
        }
        assertEquals(listOf(1.0, 2.0, 4.0, 8.0, 16.0), backoffs)
        assertEquals("file kept for retry", 1, q.pendingFiles().size)
        assertTrue("auth errors must not dump the queue into failed/", q.failedFiles().isEmpty())
        transport.enqueue(307, 404)
        process(2)
        assertEquals("capped at 30 s", 30.0, q.status.currentBackoff, 0.0)
        assertEquals(Outcome.Uploaded(200), q.processOnce())
        assertEquals("reset after success", 0.0, q.status.currentBackoff, 0.0)
    }

    @Test fun disabledWhenNoUrl() {
        batch(0)
        config = UploadConfig.DISABLED
        assertEquals(Outcome.Disabled, q.processOnce())
        assertTrue(transport.requests.isEmpty())
        assertEquals("batches stay queued for later", 1, q.pendingFiles().size)
        assertFalse(q.status.enabled)
    }

    @Test fun loopDrainsTheQueueAndKickWakesBackoff() {
        for (i in 0..4) batch(i)
        transport.enqueue(500)
        q.start()
        q.kick()
        val deadline = System.currentTimeMillis() + 60_000
        while (q.pendingFiles().isNotEmpty() && System.currentTimeMillis() < deadline) Thread.sleep(50)
        q.stop()
        assertTrue(q.pendingFiles().isEmpty())
        assertEquals(6, transport.requests.size)
    }

    // The stall bugs the iOS app had: the queue must never stall, re-order or hot-loop.

    @Test fun aLongOutageKeepsTheStopCopyQueuedAndLast() {
        batch(0, created = 1_000)
        batch(1, created = 3_000)
        meta(MetaPhase.STOP, created = 3_001)
        repeat(40) { transport.enqueue(503) }
        process(40)
        assertTrue(q.failedFiles().isEmpty())
        process(3)
        assertEquals(listOf("S1:0", "S1:1", "S1:meta-stop"), transport.keys.takeLast(3))
        assertTrue(q.pendingFiles().isEmpty())
    }

    @Test fun aForeignFileNameNeverBlocksTheQueue() {
        val copy = "0000000000001_S_0000042 2.json.gz" // sorts before everything we wrote
        File(dir, copy).writeBytes(byteArrayOf(1, 2))
        File(dir, "other.txt").writeText("left alone")
        batch(0, created = 1_000)
        assertEquals(Outcome.Uploaded(200), q.processOnce())
        assertEquals(listOf("S1:0"), transport.keys)
        assertEquals("set aside, not deleted", listOf(copy), q.failedFiles().map { it.name })
        assertTrue(File(dir, "other.txt").exists())
        assertEquals(Outcome.Empty, q.processOnce())
    }

    @Test fun anUnreadableFileIsSetAsideAndTheNextOneIsSent() {
        batch(0)
        batch(1)
        val head = q.pendingFiles().first().name
        files.failRead = { it.name == head }
        assertTrue(q.processOnce() is Outcome.Skipped)
        assertTrue(transport.requests.isEmpty())
        assertEquals(listOf(head), q.failedFiles().map { it.name })
        assertEquals(Outcome.Uploaded(200), q.processOnce())
        assertEquals(listOf("S1:1"), transport.keys)
    }

    @Test fun aFileThatCannotBeDeletedIsNotResentInAHotLoop() {
        batch(0)
        batch(1)
        files.failDelete = true
        files.failMove = true
        transport.enqueue(200, 400)
        assertEquals(listOf(Outcome.Uploaded(200), Outcome.PermanentFailure(400)), process(2))
        assertTrue("both are done; neither is sent again", process(5).all { it == Outcome.Empty })
        assertEquals(2, names().size)
        assertEquals(0, q.status.queueCount)
        files.failDelete = false
        files.failMove = false
        q.processOnce()
        assertEquals("finished once possible", emptyList<String>(), names())
        assertEquals(1, q.failedFiles().size)
        assertEquals(listOf("S1:0", "S1:1"), transport.keys)
    }

    @Test fun transientMetadata404IsRetriedThenSetAside() {
        meta(MetaPhase.START)
        batch(0, created = 2_000)
        transport.enqueue(404, 404, 405, 404)
        assertTrue(process(4).all { it is Outcome.Retry })
        process(2)
        assertEquals(listOf("S1:meta-start", "S1:0"), transport.keys.takeLast(2))
        assertTrue(q.failedFiles().isEmpty())

        meta(MetaPhase.START, session = "S2", created = 5_000)
        repeat(8) { transport.enqueue(404) }
        val o = process(8)
        assertTrue(o.take(7).all { it is Outcome.Retry })
        assertEquals(Outcome.PermanentFailure(404), o.last())
        assertEquals(1, q.failedFiles().size)
    }

    @Test fun theStopCopyHoldsBackgroundTimeUntilTheQueueIsEmpty() {
        meta(MetaPhase.START)
        batch(0, created = 2_000)
        assertEquals("only Stop asks (recording keeps the app alive)", 0, background.begins)
        meta(MetaPhase.STOP, created = 3_000)
        assertEquals(1, background.begins)
        transport.enqueue(503)
        process(4) // 503 + three uploads
        assertEquals("held while anything is queued", 0, background.ends)
        q.processOnce()
        assertEquals(1, background.ends)
        assertFalse(q.isHoldingBackgroundTime)
        q.processOnce()
        assertEquals("released once", 1, background.ends)

        meta(MetaPhase.STOP, session = "T", created = 4_000)
        assertEquals(2, background.begins)
        background.expire() // the system takes the time back
        assertFalse(q.isHoldingBackgroundTime)
        process(2)
        assertEquals(1, background.ends)
    }

    @Test fun aRelaunchContinuesAfterTheFilesOnDisk() {
        meta(MetaPhase.START, created = 10_000)
        batch(0, created = 9_000) // the clock stepped back 1 s
        batch(1, created = 12_000)
        meta(MetaPhase.STOP, created = 11_000)
        File(dir, "1_S1_0000009.json.gz.tmp").writeText("half-written enqueue of a killed run")
        val relaunched = makeQueue()
        assertFalse(File(dir, "1_S1_0000009.json.gz.tmp").exists())
        relaunched.enqueue(body, "U", 0, 5_000)
        repeat(5) { relaunched.processOnce() }
        assertEquals(listOf("S1:meta-start", "S1:0", "S1:1", "S1:meta-stop", "U:0"), transport.keys)
    }

    @Test fun aFailedEnqueueLeavesNoFileBehind() {
        files.failWrite = true
        runCatching { batch(0) }
        assertEquals(emptyList<String>(), names())
        assertEquals(0, q.status.queueCount)
    }

    // D55: which parts of a trip the backend acknowledged, and when a trip may be deleted.

    private fun queueTrip(id: String, n: Int) {
        meta(MetaPhase.START, id)
        for (seq in 0 until n) q.enqueue(body, id, seq, 2L + seq)
        meta(MetaPhase.STOP, id, 100)
    }

    private fun drain() {
        while (true) {
            val o = q.processOnce()
            assertFalse("unexpected retry", o is Outcome.Retry)
            if (o == Outcome.Empty) return
        }
    }

    private fun stopped(id: String, stats: SessionMetadata.Stats?) =
        sampleMetadata().copy(sessionId = id, endedAtUtc = "2026-11-21T10:00:00.000Z", stats = stats)

    private fun copy(id: String, stats: SessionMetadata.Stats) = TripCloudCopy(stats, q.tripState(id))
    private fun refusal(id: String, stats: SessionMetadata.Stats?) = TripCloudCopy.deleteRefusal(stopped(id, stats), q.tripState(id))
    private fun notInCloud(r: TripCloudCopy.DeleteRefusal?) = (r as TripCloudCopy.DeleteRefusal.NotInCloud).parts

    @Test fun everyAcceptedPartIsRecordedAndTheTripIsComplete() {
        queueTrip("S", 3)
        q.enqueue(body, "T", 0, 50)
        transport.enqueue(200, 200, 409, 200, 200, 200)
        drain()
        assertEquals(setOf(0, 1, 2) to true, q.acknowledged("S"))
        assertEquals("per trip", setOf(0) to false, q.acknowledged("T"))
        val c = copy("S", sampleStats(3))
        assertTrue(c.isComplete)
        assertEquals(100, c.percent)
        assertNull(refusal("S", sampleStats(3)))
    }

    @Test fun whileUploadingThePercentNeverSays100() {
        queueTrip("S", 3)
        process(4) // Start copy + batches 0-2; Stop copy still queued
        val c = copy("S", sampleStats(3))
        assertEquals(listOf(3, 4, 75), listOf(c.sentParts, c.totalParts, c.percent))
        assertFalse(c.stopMissing)
        assertEquals(1, (refusal("S", sampleStats(3)) as TripCloudCopy.DeleteRefusal.StillQueued).parts)
    }

    @Test fun windowsLeftOutOfTheLiveUploadMeanGaps() {
        queueTrip("S", 2)
        drain()
        val c = copy("S", sampleStats(2, 16))
        assertFalse(c.isComplete)
        assertEquals(listOf(19, 300 / 19, 16), listOf(c.totalParts, c.percent, c.partsNeverQueued))
        assertEquals(16, notInCloud(refusal("S", sampleStats(2, 16))))
        // Upload off for the whole trip, and a Stop copy that could not be queued.
        assertEquals(301, notInCloud(refusal("OFF", sampleStats(0, 300))))
        q.enqueue(body, "N", 0, 200)
        drain()
        assertTrue(copy("N", sampleStats(1)).stopMissing)
        assertEquals(1, notInCloud(refusal("N", sampleStats(1))))
    }

    @Test fun deleteIsRefusedForUnreadableRecoveredOrIncompleteTrips() {
        queueTrip("S", 2)
        drain()
        assertTrue(TripCloudCopy.deleteRefusal(null, q.tripState("S")) is TripCloudCopy.DeleteRefusal.Unreadable)
        val recovered = stopped("S", sampleStats(2)).copy(endedAtUtc = null, recovered = true)
        assertNotNull(TripCloudCopy.deleteRefusal(recovered, q.tripState("S")))
        assertNotNull(refusal("S", null))
        assertEquals("a batch the ack record doesn't have", 1, notInCloud(refusal("S", sampleStats(3))))
        assertNull(refusal("S", sampleStats(2)))
        q.forgetAcknowledged("S")
        assertEquals(3, notInCloud(refusal("S", sampleStats(2))))
    }

    @Test fun rejectedPartsCanBeRetriedFromSettings() {
        queueTrip("S", 2)
        transport.enqueue(200, 422, 200, 200) // batch 0 rejected
        drain()
        assertEquals(1, q.failedFiles().size)
        val c = copy("S", sampleStats(2))
        assertEquals(listOf(1, 66), listOf(c.rejectedParts, c.percent))
        assertEquals(1, (refusal("S", sampleStats(2)) as TripCloudCopy.DeleteRefusal.Rejected).parts)
        q.requeueFailed()
        drain()
        assertNull(refusal("S", sampleStats(2)))
    }

    @Test fun aTornAckLineNeverBecomesAnotherBatchNumber() {
        queueTrip("S", 1)
        drain()
        val ack = File(dir.parentFile, "upload_acked/S.txt")
        ack.appendText("12") // "123\n" torn by a power loss
        assertEquals(setOf(0) to true, q.acknowledged("S"))
        q.enqueue(body, "S", 3, 300)
        drain()
        assertEquals(setOf(0, 3) to true, q.acknowledged("S"))
    }

    @Test fun probe() {
        fun probe(code: Int) = UploadQueue.testConnection(config, "DEV", { transport.requests.add(it); code })
        assertEquals("Connected", probe(400).short)
        assertEquals("{\"deviceId\":\"DEV\",\"probe\":true}", String(Gzip.decompress(transport.requests.last().body)))
        assertEquals("1", transport.requests.last().headers["x-probe"])
        assertEquals(
            listOf("Wrong device key", "Key belongs to another phone", "Wrong server address", "Server error (HTTP 503)"),
            listOf(401, 403, 404, 503).map { probe(it).short },
        )
        assertEquals("Server unreachable", UploadQueue.testConnection(config, "DEV", { throw IOException("x") }).short)
        assertFalse(UploadQueue.testConnection(UploadConfig.DISABLED, "DEV").ok)
    }
}

class UploadConfigTest {
    @Test fun parseBaseUrl() {
        for ((raw, base) in listOf(
            " https://api.example.com/ " to "https://api.example.com", "http://localhost:8080" to "http://localhost:8080",
            "https://fn.azurewebsites.net/api/ingest" to "https://fn.azurewebsites.net",
            " https://fn.azurewebsites.net/API/Ingest/ " to "https://fn.azurewebsites.net",
            "https://host.test/prod/api/ingest" to "https://host.test/prod",
            "http://192.168.1.20:8765/api/ingest" to "http://192.168.1.20:8765",
            "http://10.0.2.2:8765" to "http://10.0.2.2:8765",
            "https://api/ingest" to "https://api/ingest", // host "api", path "/ingest": kept
        )) assertEquals(raw, base, UploadConfig.parseBaseUrl(raw))
        for (bad in listOf(
            "", "   ", "not a url", "ftp://x.y", "example.com", "https://", "/api/ingest", "https://u:p@x.y", "https://x.y?code=1", "https://x.y#f",
            "http://example.com", "http://192.168.1.1.attacker.com", "http://+10.0.0.1", "http://172.32.0.1", "http://010.0.0.1", "http://256.0.0.1",
        )) assertNull(bad, UploadConfig.parseBaseUrl(bad))
        val cfg = UploadConfig(UploadConfig.parseBaseUrl("https://fn.test/api/ingest"), "k")
        assertEquals("https://fn.test/api/ingest", cfg.ingestUrl)
        assertEquals("https://fn.test/api/ingest/sessions/S", cfg.sessionUrl("S"))
    }
}

class UrlConnectionTransportTest {
    /** The device key must never travel to the host a redirect names, and 4xx must not throw. */
    @Test fun statusesAreReturnedAndRedirectsAreNotFollowed() {
        ServerSocket(0).use { server ->
            val seen = ArrayList<String>()
            for (status in listOf("200 OK", "307 Temporary Redirect", "401 Unauthorized", "503 Service Unavailable")) {
                val t = thread {
                    server.accept().use { s ->
                        val input = s.getInputStream()
                        val head = StringBuilder()
                        while (!head.endsWith("\r\n\r\n")) head.append(input.read().toChar())
                        repeat(3) { input.read() }
                        seen.add(head.toString())
                        s.getOutputStream().write(
                            "HTTP/1.1 $status\r\nLocation: http://127.0.0.1:1/stolen\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok".toByteArray(),
                        )
                    }
                }
                val code = UrlConnectionTransport.send(
                    HttpRequest("POST", "http://127.0.0.1:${server.localPort}/api/ingest", mapOf("x-device-key" to "k"), byteArrayOf(1, 2, 3), 10_000),
                )
                t.join()
                assertEquals(status.take(3).toInt(), code)
            }
            assertEquals(4, seen.size)
            assertTrue(seen.all { it.contains("x-device-key: k") && it.contains("Content-Length: 3") })
        }
    }
}
