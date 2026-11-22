package com.chuds.sensorrecorder.core

import kotlin.math.abs
import kotlin.math.truncate

/**
 * Small JSON reader/writer, so `session.json` and the ingest batch need no library and the contract
 * tests run on the JVM. Integers read as Long, other numbers as Double. Objects are written with
 * sorted keys (as the iOS app does), so a re-sent body is byte-identical.
 */
object Json {
    fun write(v: Any?, pretty: Boolean = false): String =
        StringBuilder().also { write(it, v, pretty, 0) }.toString()

    private fun write(sb: StringBuilder, v: Any?, pretty: Boolean, depth: Int) {
        when (v) {
            null -> sb.append("null")
            is Boolean -> sb.append(v)
            is Int, is Long -> sb.append(v)
            is Double -> number(sb, v)
            is String -> string(sb, v)
            is DoubleList -> {
                sb.append('[')
                for (i in 0 until v.size) {
                    if (i > 0) sb.append(',')
                    number(sb, v[i])
                }
                sb.append(']')
            }
            is Map<*, *> -> {
                sb.append('{')
                v.keys.map { it as String }.sorted().forEachIndexed { i, k ->
                    if (i > 0) sb.append(',')
                    newline(sb, pretty, depth + 1)
                    string(sb, k)
                    sb.append(if (pretty) " : " else ":")
                    write(sb, v[k], pretty, depth + 1)
                }
                if (v.isNotEmpty()) newline(sb, pretty, depth)
                sb.append('}')
            }
            is Collection<*> -> {
                sb.append('[')
                v.forEachIndexed { i, x ->
                    if (i > 0) sb.append(',')
                    newline(sb, pretty, depth + 1)
                    write(sb, x, pretty, depth + 1)
                }
                if (v.isNotEmpty()) newline(sb, pretty, depth)
                sb.append(']')
            }
            else -> throw IllegalArgumentException("not a JSON value: ${v.javaClass}")
        }
    }

    private fun newline(sb: StringBuilder, pretty: Boolean, depth: Int) {
        if (!pretty) return
        sb.append('\n')
        repeat(depth) { sb.append("  ") }
    }

    /** Throws on NaN/∞ like Swift's JSONEncoder: the ingest contract takes only finite numbers. */
    private fun number(sb: StringBuilder, v: Double) {
        require(v.isFinite()) { "non-finite number in JSON" }
        if (v == truncate(v) && abs(v) < 1e15) sb.append(v.toLong()) else sb.append(v)
    }

    private fun string(sb: StringBuilder, s: String) {
        sb.append('"')
        for (c in s) when {
            c == '"' -> sb.append("\\\"")
            c == '\\' -> sb.append("\\\\")
            c == '\n' -> sb.append("\\n")
            c == '\r' -> sb.append("\\r")
            c == '\t' -> sb.append("\\t")
            c < ' ' -> sb.append("\\u").append(c.code.toString(16).padStart(4, '0'))
            else -> sb.append(c)
        }
        sb.append('"')
    }

    fun parse(text: String): Any? = Parser(text).document()

    @Suppress("UNCHECKED_CAST")
    fun parseObject(text: String): Map<String, Any?> =
        parse(text) as? Map<String, Any?> ?: throw JsonException("not a JSON object")

    class JsonException(message: String) : Exception(message)

    private class Parser(val s: String) {
        var i = 0
        var depth = 0

        fun document(): Any? {
            val v = value()
            space()
            if (i != s.length) fail()
            return v
        }

        private fun fail(): Nothing = throw JsonException("invalid JSON at offset $i")
        private fun space() { while (i < s.length && s[i] in " \t\r\n") i++ }
        private fun peek(): Char = if (i < s.length) s[i] else fail()
        private fun expect(c: Char) { if (peek() != c) fail(); i++ }

        private fun value(): Any? {
            space()
            if (++depth > 200) fail()
            val v: Any? = when (peek()) {
                '{' -> obj()
                '[' -> arr()
                '"' -> str()
                't' -> word("true", true)
                'f' -> word("false", false)
                'n' -> word("null", null)
                else -> num()
            }
            depth--
            return v
        }

        private fun <T> word(w: String, v: T): T {
            if (!s.startsWith(w, i)) fail()
            i += w.length
            return v
        }

        private fun obj(): Map<String, Any?> {
            val m = LinkedHashMap<String, Any?>()
            expect('{')
            space()
            if (peek() == '}') { i++; return m }
            while (true) {
                space()
                val k = str()
                space()
                expect(':')
                m[k] = value()
                space()
                if (peek() == ',') { i++; continue }
                expect('}')
                return m
            }
        }

        private fun arr(): List<Any?> {
            val l = ArrayList<Any?>()
            expect('[')
            space()
            if (peek() == ']') { i++; return l }
            while (true) {
                l.add(value())
                space()
                if (peek() == ',') { i++; continue }
                expect(']')
                return l
            }
        }

        private fun str(): String {
            expect('"')
            val sb = StringBuilder()
            while (true) {
                val c = peek()
                i++
                when {
                    c == '"' -> return sb.toString()
                    c == '\\' -> escape(sb)
                    c < ' ' -> fail()
                    else -> sb.append(c)
                }
            }
        }

        private fun escape(sb: StringBuilder) {
            val e = peek()
            i++
            when (e) {
                '"', '\\', '/' -> sb.append(e)
                'b' -> sb.append('\b')
                'f' -> sb.append('\u000C')
                'n' -> sb.append('\n')
                'r' -> sb.append('\r')
                't' -> sb.append('\t')
                'u' -> {
                    if (i + 4 > s.length) fail()
                    sb.append((s.substring(i, i + 4).toIntOrNull(16) ?: fail()).toChar())
                    i += 4
                }
                else -> fail()
            }
        }

        private fun num(): Any {
            val start = i
            while (i < s.length && (s[i] in '0'..'9' || s[i] in "+-.eE")) i++
            val t = s.substring(start, i)
            return t.toLongOrNull() ?: t.toDoubleOrNull()?.takeIf { it.isFinite() } ?: fail()
        }
    }
}

/** Growable double array: batch columns hold hundreds of values every 2 s, so no boxing. */
class DoubleList {
    private var a = DoubleArray(16)
    var size = 0
        private set

    fun add(v: Double) {
        if (size == a.size) a = a.copyOf(size * 2)
        a[size++] = v
    }

    operator fun get(i: Int): Double {
        require(i < size)
        return a[i]
    }

    fun toList(): List<Double> = List(size) { a[it] }
}
