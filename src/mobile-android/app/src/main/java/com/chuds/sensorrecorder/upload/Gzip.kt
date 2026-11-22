package com.chuds.sensorrecorder.upload

import java.io.ByteArrayOutputStream
import java.util.zip.GZIPInputStream
import java.util.zip.GZIPOutputStream

object Gzip {
    /** One gzip member without trailing bytes, which is all the ingest function accepts. */
    fun compress(data: ByteArray): ByteArray {
        val out = ByteArrayOutputStream(data.size / 2 + 64)
        GZIPOutputStream(out).use { it.write(data) }
        return out.toByteArray()
    }

    fun decompress(data: ByteArray): ByteArray = GZIPInputStream(data.inputStream()).use { it.readBytes() }
}
