package com.chuds.sensorrecorder.core

import java.math.BigDecimal
import java.math.RoundingMode
import kotlin.math.abs
import kotlin.math.roundToLong

/**
 * CSV formatting helpers, the same output as the iOS app's `CSV`. Always `.` decimal separator,
 * independent of the phone's locale. Integer arithmetic instead of `String.format`: at ~400 rows/s
 * with up to 18 values per row this keeps formatting cost negligible.
 */
object Csv {
    private val POW10 = longArrayOf(1, 10, 100, 1_000, 10_000, 100_000, 1_000_000, 10_000_000, 100_000_000, 1_000_000_000)

    /** 6 decimals: sensor values and `t_up`. */
    fun f6(v: Double): String = fixed(v, 6)

    /** 8 decimals: latitude / longitude. */
    fun f8(v: Double): String = fixed(v, 8)

    /** Integer Unix milliseconds. */
    fun ms(utcMs: Double): String = if (utcMs.isFinite()) roundHalfAway(utcMs).toString() else ""

    fun bool(b: Boolean?): String = when (b) { null -> ""; true -> "1"; false -> "0" }

    /** Fixed-point formatting. NaN / ±inf become an empty field (pandas reads that as NaN). */
    fun fixed(v: Double, decimals: Int): String {
        require(decimals in 0..9)
        if (!v.isFinite()) return ""
        val scaled = v * POW10[decimals]
        if (abs(scaled) >= 9.0e18) return BigDecimal(v).setScale(decimals, RoundingMode.HALF_UP).toPlainString()
        var n = roundHalfAway(scaled)
        if (decimals == 0) return n.toString()
        val negative = n < 0 // after rounding, so a tiny negative never prints as "-0.000000"
        if (negative) n = -n
        val div = POW10[decimals]
        val frac = (n % div).toString()
        val sb = StringBuilder(24)
        if (negative) sb.append('-')
        sb.append(n / div).append('.')
        repeat(decimals - frac.length) { sb.append('0') }
        return sb.append(frac).toString()
    }

    /** Swift's `.rounded()`: half away from zero (Kotlin's roundToLong rounds half up). */
    fun roundHalfAway(v: Double): Long = if (v < 0) -(-v).roundToLong() else v.roundToLong()

    fun row(vararg fields: String): String = fields.joinToString(",")
}
