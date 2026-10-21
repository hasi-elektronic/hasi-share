package io.iptvplayer.core.xmltv

import java.time.DateTimeException
import java.time.LocalDateTime
import java.time.ZoneOffset

/**
 * XMLTV time parsing (CONTRACT §5, `test-vectors/xmltv/time-parsing.json`):
 * `YYYYMMDDhhmm[ss][ ±hhmm]` – the offset may follow with or without a space; missing offset
 * ⇒ UTC. Leading/trailing whitespace is ignored. Returns epoch **milliseconds** or null.
 */
public object XmltvTime {
    private val PATTERN = Regex("""^(\d{4})(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})?\s*(?:([+-])(\d{2}):?(\d{2}))?$""")

    /** Parses [value]; null when invalid. */
    public fun parse(value: String?): Long? {
        if (value == null) return null
        val m = PATTERN.matchEntire(value.trim()) ?: return null
        val g = m.groupValues
        return try {
            val ldt = LocalDateTime.of(
                g[1].toInt(), g[2].toInt(), g[3].toInt(), g[4].toInt(), g[5].toInt(),
                if (g[6].isEmpty()) 0 else g[6].toInt(),
            )
            val offsetSeconds = if (g[7].isEmpty()) {
                0
            } else {
                val secs = g[8].toInt() * 3600 + g[9].toInt() * 60
                if (g[7] == "-") -secs else secs
            }
            ldt.toEpochSecond(ZoneOffset.ofTotalSeconds(offsetSeconds)) * 1000L
        } catch (_: DateTimeException) {
            null
        }
    }
}
