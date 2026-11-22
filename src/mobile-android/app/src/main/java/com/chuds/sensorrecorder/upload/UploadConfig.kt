package com.chuds.sensorrecorder.upload

import java.net.URI

/** Upload configuration entered at runtime (spec §6: never hard-coded in the repo). */
data class UploadConfig(val baseUrl: String?, val deviceKey: String) {
    val isEnabled: Boolean get() = baseUrl != null

    val ingestUrl: String? get() = baseUrl?.let { "$it/$INGEST_PATH" }

    /** Spec §6.1: `PUT {API}/api/ingest/sessions/{sessionId}`. */
    fun sessionUrl(sessionId: String): String? = ingestUrl?.let { "$it/sessions/$sessionId" }

    companion object {
        /** Spec §6: the ingest route, relative to the base URL. */
        const val INGEST_PATH = "api/ingest"

        val DISABLED = UploadConfig(null, "")

        /**
         * Accepts `https://host[:port][/path]` (trailing slash ignored). Empty / invalid -> null (= upload
         * off). A pasted full endpoint (`…/api/ingest`) is reduced to its base, because the app appends
         * `api/ingest` itself (otherwise every request would 404).
         */
        fun parseBaseUrl(raw: String): String? {
            var s = raw.trim().trimEnd('/')
            val endpoint = "/$INGEST_PATH"
            val pasted = parse(s)
            if (pasted != null && pasted.rawQuery == null && pasted.rawFragment == null &&
                (pasted.rawPath ?: "").lowercase().endsWith(endpoint) && s.lowercase().endsWith(endpoint)
            ) {
                s = s.dropLast(endpoint.length).trimEnd('/')
            }
            if (s.isEmpty()) return null
            val url = parse(s) ?: return null
            val scheme = url.scheme?.lowercase()
            if (scheme != "https" && scheme != "http") return null
            val host = url.host
            if (host.isNullOrEmpty() || url.rawUserInfo != null || url.rawQuery != null || url.rawFragment != null) return null
            // Plain http would send x-device-key in cleartext: allow it only for local test servers.
            if (scheme == "http" && !isLocalHost(host)) return null
            return s
        }

        private fun parse(s: String): URI? = runCatching { URI(s) }.getOrNull()

        /**
         * localhost, loopback, RFC 1918 private IPv4, link-local, or mDNS `.local` names. IPv4 must be an
         * exact dotted quad: `192.168.1.1.attacker.com` or `+10.0.0.1` are NOT local.
         */
        fun isLocalHost(host: String): Boolean {
            val h = host.lowercase()
            if (h == "localhost" || h == "::1" || h == "[::1]") return true
            if (h.endsWith(".local") && h.length > ".local".length && h.all { it.isLetterOrDigit() || it == '-' || it == '.' }) return true
            val labels = h.split('.')
            if (labels.size != 4) return false
            val o = labels.map { l ->
                // digits only, no sign/whitespace/leading zeros (octal ambiguity), 0...255
                if (l.isEmpty() || l.length > 3 || !l.all { it in '0'..'9' } || (l != "0" && l.startsWith('0'))) return false
                l.toInt().also { if (it > 255) return false }
            }
            return o[0] == 127 || o[0] == 10 || (o[0] == 192 && o[1] == 168) || (o[0] == 169 && o[1] == 254) ||
                (o[0] == 172 && o[1] in 16..31)
        }
    }
}
