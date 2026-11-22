package com.chuds.sensorrecorder.upload

import java.net.HttpRetryException
import java.net.HttpURLConnection
import java.net.URL

class HttpRequest(
    val method: String,
    val url: String,
    val headers: Map<String, String>,
    val body: ByteArray,
    val timeoutMs: Int,
)

fun interface HttpTransport {
    /** Returns the HTTP status code. Throws on transport errors (no connectivity, timeout, TLS…). */
    fun send(request: HttpRequest): Int
}

object UrlConnectionTransport : HttpTransport {
    override fun send(request: HttpRequest): Int {
        val c = URL(request.url).openConnection() as HttpURLConnection
        try {
            c.requestMethod = request.method
            // Never follow redirects: a 307/308 would re-send the body *and the x-device-key header* to
            // another host. The redirect response is returned as-is (3xx → retried, logged).
            c.instanceFollowRedirects = false
            c.connectTimeout = request.timeoutMs
            c.readTimeout = request.timeoutMs
            c.useCaches = false
            c.doOutput = true
            for ((k, v) in request.headers) c.setRequestProperty(k, v)
            // Streaming mode: the stack neither buffers the body nor silently re-sends it.
            c.setFixedLengthStreamingMode(request.body.size)
            c.outputStream.use { it.write(request.body) }
            val code = c.responseCode
            // Drain the answer so the connection can be reused.
            (if (code >= 400) c.errorStream else c.inputStream)?.use { s ->
                val buf = ByteArray(4096)
                while (s.read(buf) >= 0) Unit
            }
            return code
        } catch (e: HttpRetryException) {
            return e.responseCode()
        }
    }
}
