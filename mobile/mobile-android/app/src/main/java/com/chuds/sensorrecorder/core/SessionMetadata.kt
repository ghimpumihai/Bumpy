package com.chuds.sensorrecorder.core

import java.io.File

/**
 * `session.json` (spec §3.8), the same keys as the iOS app writes plus `device.platform` and
 * `device.osVersion`. Written at start, rewritten at stop (with stats) and on recovery. Every key
 * decodes with a default, so files written by other app versions still load.
 */
data class SessionMetadata(
    val sessionId: String,
    val appVersion: String,
    val device: Device,
    val timezone: String,
    val startedAtUtc: String,
    val startUptimeSec: Double,
    val endedAtUtc: String?,
    val vehicle: Vehicle = Vehicle(),
    val mount: Mount = Mount(),
    val people: People = People(),
    val conditions: Conditions = Conditions(),
    val requestedRatesHz: Map<String, Double> = REQUESTED_RATES,
    val recovered: Boolean = false,
    val recoveredAtUtc: String? = null,
    val syntheticSensors: Boolean,
    val folderName: String,
    val deviceId: String,
    val preflight: Preflight? = null,
    val stats: Stats? = null,
    /** Only for trips that started by themselves (D59); manual trips have no `autoStart` key at all. */
    val autoStart: AutoStart? = null,
) {
    /** `iosVersion` is a key of the session.json contract, so it stays and holds the Android version. */
    data class Device(val model: String, val name: String, val osVersion: String, val platform: String = "android") {
        fun json() = mapOf(
            "model" to model, "name" to name, "iosVersion" to osVersion, "osVersion" to osVersion, "platform" to platform,
        )
    }

    data class Vehicle(
        val type: String = "car",
        val makeModel: String = "",
        /** Bus/tram line number; `null` for other vehicles (spec §3.8). */
        val line: String? = null,
        val notes: String = "",
    ) {
        fun json() = mapOf("type" to type, "makeModel" to makeModel, "line" to line, "notes" to notes)
    }

    data class Mount(
        val location: String = "taped flat on center console",
        val phoneOrientation: String = "screen up, top of phone pointing to vehicle front",
        val rigid: Boolean = true,
        /** Phone held in the hand (no mount). The backend excludes these from roughness (02 §10). */
        val handheld: Boolean = false,
        val seatOverAxle: Boolean = false,
        val photoFile: String? = null,
    ) {
        fun json() = mapOf(
            "location" to location, "phoneOrientation" to phoneOrientation, "rigid" to rigid,
            "handheld" to handheld, "seatOverAxle" to seatOverAxle, "photoFile" to photoFile,
        )
    }

    data class People(
        val operatorSeat: String = "front passenger",
        val raterSeat: String = "rear left",
        val raterPosture: String = "seated",
        val passengerCount: Int = 2,
        val raterName: String = "",
    ) {
        fun json() = mapOf(
            "operatorSeat" to operatorSeat, "raterSeat" to raterSeat, "raterPosture" to raterPosture,
            "passengerCount" to passengerCount, "raterName" to raterName,
        )
    }

    data class Conditions(val weather: String = "dry", val notes: String = "") {
        fun json() = mapOf("weather" to weather, "notes" to notes)
    }

    data class StreamStats(
        val samples: Long,
        val meanRateHz: Double,
        val maxGapSec: Double,
        val gapsOver1s: Int,
        val droppedEstimate: Long,
        val fileBytes: Long?,
    ) {
        fun json() = buildMap<String, Any?> {
            put("samples", samples)
            put("meanRateHz", meanRateHz)
            put("maxGapSec", maxGapSec)
            put("gapsOver1s", gapsOver1s)
            put("droppedEstimate", droppedEstimate)
            if (fileBytes != null) put("fileBytes", fileBytes)
        }

        companion object {
            fun of(t: GapTracker, fileBytes: Long?) =
                StreamStats(t.count, t.meanRateHz, t.maxGap, t.gapsOver1s, t.droppedEstimate, fileBytes)
        }
    }

    data class Stats(
        val durationSec: Double,
        val streams: Map<String, StreamStats>,
        val labelsCount: Int,
        val fileSizes: Map<String, Long>,
        val totalBytes: Long,
        val writeErrors: Int,
        /** Batches queued for live upload (0 when upload was off). */
        val uploadBatchesCreated: Int,
        /**
         * 2 s windows that never entered the upload queue: the cloud copy has gaps there, so the trip
         * needs the laptop upload (D55). Omitted when 0, and kept out of the Stop copy (local only).
         */
        val uploadWindowsNotQueued: Int? = null,
    ) {
        fun json() = buildMap<String, Any?> {
            put("durationSec", durationSec)
            put("streams", streams.mapValues { it.value.json() })
            put("labelsCount", labelsCount)
            // Always 0 since MISC ratings were removed (D47); part of the Stop-copy fixture.
            put("sicknessRatings", 0)
            put("sicknessMissed", 0)
            put("fileSizes", fileSizes)
            put("totalBytes", totalBytes)
            put("writeErrors", writeErrors)
            put("uploadBatchesCreated", uploadBatchesCreated)
            if (uploadWindowsNotQueued != null) put("uploadWindowsNotQueued", uploadWindowsNotQueued)
        }
    }

    data class PreflightCheckResult(
        val id: String,
        val title: String,
        val status: String,
        val detail: String,
        val required: Boolean,
    ) {
        fun json() = mapOf("id" to id, "title" to title, "status" to status, "detail" to detail, "required" to required)
    }

    data class Preflight(
        val completedAtUtc: String,
        val overridden: Boolean,
        val checks: List<PreflightCheckResult>,
        /** Mean raw accelerometer vector during the stillness test (g, device frame, iOS sign). */
        val stillAccelMeanG: List<Double>? = null,
        /** Mean gravity vector during the stillness test (g, device frame). Points "down". */
        val stillGravityG: List<Double>? = null,
        val stillAccelStdG: List<Double>? = null,
        val measuredRatesHz: Map<String, Double>? = null,
    ) {
        fun json() = buildMap<String, Any?> {
            put("completedAtUtc", completedAtUtc)
            put("overridden", overridden)
            put("checks", checks.map { it.json() })
            if (stillAccelMeanG != null) put("stillAccelMeanG", stillAccelMeanG)
            if (stillGravityG != null) put("stillGravityG", stillGravityG)
            if (stillAccelStdG != null) put("stillAccelStdG", stillAccelStdG)
            if (measuredRatesHz != null) put("measuredRatesHz", measuredRatesHz)
        }
    }

    data class AutoStart(val detectedAtUtc: String, val cancelledAtUtc: String? = null) {
        fun json() = buildMap<String, Any?> {
            put("detectedAtUtc", detectedAtUtc)
            if (cancelledAtUtc != null) put("cancelledAtUtc", cancelledAtUtc)
        }
    }

    /** `endedAtUtc` and `stats` are explicit nulls until the end (spec shows them). */
    fun json(): Map<String, Any?> = buildMap {
        put("sessionId", sessionId)
        put("appVersion", appVersion)
        put("device", device.json())
        put("timezone", timezone)
        put("startedAtUtc", startedAtUtc)
        put("startUptimeSec", startUptimeSec)
        put("endedAtUtc", endedAtUtc)
        put("vehicle", vehicle.json())
        put("mount", mount.json())
        put("people", people.json())
        put("conditions", conditions.json())
        put("requestedRatesHz", requestedRatesHz)
        put("recovered", recovered)
        if (recoveredAtUtc != null) put("recoveredAtUtc", recoveredAtUtc)
        put("syntheticSensors", syntheticSensors)
        put("folderName", folderName)
        put("deviceId", deviceId)
        if (preflight != null) put("preflight", preflight.json())
        if (autoStart != null) put("autoStart", autoStart.json())
        put("stats", stats?.json())
    }

    fun jsonData(): ByteArray = Json.write(json(), pretty = true).toByteArray()

    fun write(file: File) = FileUtil.writeAtomically(jsonData(), file)

    companion object {
        val REQUESTED_RATES = mapOf("deviceMotion" to 100.0, "accel" to 100.0, "gyro" to 100.0, "mag" to 50.0)

        fun load(file: File): SessionMetadata = decode(file.readText())

        fun decode(text: String): SessionMetadata {
            val o = JsonObj(Json.parseObject(text))
            return SessionMetadata(
                sessionId = o.str("sessionId") ?: throw Json.JsonException("sessionId missing"),
                appVersion = o.str("appVersion") ?: "unknown",
                device = o.obj("device").let {
                    Device(
                        it.str("model") ?: "unknown", it.str("name") ?: "unknown",
                        it.str("osVersion") ?: it.str("iosVersion") ?: "unknown", it.str("platform") ?: "ios",
                    )
                },
                timezone = o.str("timezone") ?: "UTC",
                startedAtUtc = o.str("startedAtUtc") ?: throw Json.JsonException("startedAtUtc missing"),
                startUptimeSec = o.num("startUptimeSec") ?: 0.0,
                endedAtUtc = o.str("endedAtUtc"),
                vehicle = o.obj("vehicle").let {
                    Vehicle(it.str("type") ?: "car", it.str("makeModel") ?: "", it.str("line"), it.str("notes") ?: "")
                },
                mount = mount(o.obj("mount")),
                people = people(o.obj("people")),
                conditions = conditions(o.obj("conditions")),
                requestedRatesHz = o.numbers("requestedRatesHz") ?: REQUESTED_RATES,
                recovered = o.bool("recovered") ?: false,
                recoveredAtUtc = o.str("recoveredAtUtc"),
                syntheticSensors = o.bool("syntheticSensors") ?: false,
                folderName = o.str("folderName") ?: "",
                deviceId = o.str("deviceId") ?: "",
                preflight = if (o.has("preflight")) runCatching { preflight(o.obj("preflight")) }.getOrNull() else null,
                stats = if (o.has("stats")) runCatching { stats(o.obj("stats")) }.getOrNull() else null,
                autoStart = o.obj("autoStart").str("detectedAtUtc")?.let { AutoStart(it, o.obj("autoStart").str("cancelledAtUtc")) },
            )
        }

        fun mount(o: JsonObj): Mount {
            val d = Mount()
            return Mount(
                o.str("location") ?: d.location, o.str("phoneOrientation") ?: d.phoneOrientation, o.bool("rigid") ?: d.rigid,
                o.bool("handheld") ?: false, o.bool("seatOverAxle") ?: false, o.str("photoFile"),
            )
        }

        fun people(o: JsonObj): People {
            val d = People()
            return People(
                o.str("operatorSeat") ?: d.operatorSeat, o.str("raterSeat") ?: d.raterSeat,
                o.str("raterPosture") ?: d.raterPosture, o.int("passengerCount") ?: d.passengerCount, o.str("raterName") ?: "",
            )
        }

        fun conditions(o: JsonObj) = Conditions(o.str("weather") ?: "dry", o.str("notes") ?: "")

        private fun preflight(o: JsonObj) = Preflight(
            completedAtUtc = o.str("completedAtUtc")!!,
            overridden = o.bool("overridden")!!,
            checks = o.list("checks").map {
                val c = JsonObj(it)
                PreflightCheckResult(c.str("id")!!, c.str("title")!!, c.str("status")!!, c.str("detail")!!, c.bool("required")!!)
            },
            stillAccelMeanG = o.doubles("stillAccelMeanG"),
            stillGravityG = o.doubles("stillGravityG"),
            stillAccelStdG = o.doubles("stillAccelStdG"),
            measuredRatesHz = o.numbers("measuredRatesHz"),
        )

        private fun stats(o: JsonObj) = Stats(
            durationSec = o.num("durationSec")!!,
            streams = o.obj("streams").map.mapValues { (_, v) ->
                val s = JsonObj(v)
                StreamStats(
                    s.long("samples")!!, s.num("meanRateHz")!!, s.num("maxGapSec")!!, s.int("gapsOver1s")!!,
                    s.long("droppedEstimate")!!, s.long("fileBytes"),
                )
            },
            labelsCount = o.int("labelsCount")!!,
            fileSizes = o.obj("fileSizes").map.mapValues { (_, v) -> (v as Number).toLong() },
            totalBytes = o.long("totalBytes")!!,
            writeErrors = o.int("writeErrors")!!,
            uploadBatchesCreated = o.int("uploadBatchesCreated")!!,
            uploadWindowsNotQueued = o.int("uploadWindowsNotQueued"),
        )
    }
}

/** Typed access to a parsed JSON object; a missing key or a wrong type reads as null. */
class JsonObj(v: Any?) {
    @Suppress("UNCHECKED_CAST")
    val map: Map<String, Any?> = v as? Map<String, Any?> ?: emptyMap()

    fun has(k: String) = map[k] != null
    fun str(k: String) = map[k] as? String
    fun bool(k: String) = map[k] as? Boolean
    fun num(k: String) = (map[k] as? Number)?.toDouble()
    fun long(k: String) = (map[k] as? Number)?.toLong()
    fun int(k: String) = (map[k] as? Number)?.toInt()
    fun obj(k: String) = JsonObj(map[k])
    fun list(k: String): List<Any?> = map[k] as? List<*> ?: emptyList<Any?>()
    fun doubles(k: String): List<Double>? = (map[k] as? List<*>)?.map { (it as Number).toDouble() }
    fun numbers(k: String): Map<String, Double>? =
        (map[k] as? Map<*, *>)?.entries?.associate { (n, v) -> n as String to (v as Number).toDouble() }
}

/** The parts of the metadata that describe the trip's setup (no form since D51: remembered defaults). */
data class SessionSetup(
    val vehicle: SessionMetadata.Vehicle = SessionMetadata.Vehicle(),
    val mount: SessionMetadata.Mount = SessionMetadata.Mount(),
    val people: SessionMetadata.People = SessionMetadata.People(),
    val conditions: SessionMetadata.Conditions = SessionMetadata.Conditions(),
) {
    fun encode(): String =
        Json.write(mapOf("mount" to mount.json(), "people" to people.json(), "conditions" to conditions.json()))

    companion object {
        /**
         * Remembered values, except mount quality: it decides whether a trip counts for the road map,
         * so it is set for every trip, never carried over from the last one (D42).
         */
        fun decode(text: String): SessionSetup {
            val o = JsonObj(Json.parseObject(text))
            return SessionSetup(
                mount = SessionMetadata.mount(o.obj("mount")).copy(photoFile = null, rigid = true, handheld = false),
                people = SessionMetadata.people(o.obj("people")),
                conditions = SessionMetadata.conditions(o.obj("conditions")),
            )
        }
    }
}
