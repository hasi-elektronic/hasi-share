package io.iptvplayer.core.util

import java.io.ByteArrayOutputStream

/**
 * Percent-encoding of CONTRACT §4.5: every UTF-8 byte except the RFC 3986 unreserved set
 * `A–Z a–z 0–9 - . _ ~` becomes `%XX` (upper-case hex). Used for path segments **and**
 * query values alike (space → `%20`, never `+`).
 */
public object PercentEncoding {
    private val HEX = "0123456789ABCDEF".toCharArray()

    /** Returns true for the RFC 3986 unreserved characters. */
    public fun isUnreserved(c: Int): Boolean =
        (c in 'A'.code..'Z'.code) || (c in 'a'.code..'z'.code) || (c in '0'.code..'9'.code) ||
            c == '-'.code || c == '.'.code || c == '_'.code || c == '~'.code

    /** Encodes [value] (UTF-8). */
    public fun encode(value: String): String {
        val bytes = value.encodeToByteArray()
        val sb = StringBuilder(bytes.size + 16)
        for (b in bytes) {
            val c = b.toInt() and 0xFF
            if (isUnreserved(c)) {
                sb.append(c.toChar())
            } else {
                sb.append('%').append(HEX[c ushr 4]).append(HEX[c and 0x0F])
            }
        }
        return sb.toString()
    }

    /** Decodes `%XX` sequences (UTF-8). `+` is kept literally. Invalid escapes are kept as-is. */
    public fun decode(value: String): String {
        if ('%' !in value) return value
        val out = ByteArrayOutputStream(value.length)
        var i = 0
        var runStart = 0
        fun flushRun(end: Int) {
            if (end > runStart) {
                val b = value.substring(runStart, end).encodeToByteArray()
                out.write(b, 0, b.size)
            }
        }
        while (i < value.length) {
            if (value[i] == '%' && i + 2 <= value.lastIndex) {
                val hi = Character.digit(value[i + 1], 16)
                val lo = Character.digit(value[i + 2], 16)
                if (hi >= 0 && lo >= 0) {
                    flushRun(i)
                    out.write((hi shl 4) or lo)
                    i += 3
                    runStart = i
                    continue
                }
            }
            i++
        }
        flushRun(value.length)
        return out.toByteArray().decodeToString()
    }

    /** Builds `k1=v1&k2=v2` with both keys and values encoded. Null values are skipped. */
    public fun query(params: List<Pair<String, String?>>): String =
        params.filter { it.second != null }.joinToString("&") { (k, v) -> encode(k) + "=" + encode(v!!) }
}
