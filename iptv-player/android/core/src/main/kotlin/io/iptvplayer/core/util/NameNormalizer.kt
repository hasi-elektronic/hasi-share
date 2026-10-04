package io.iptvplayer.core.util

import java.text.Normalizer
import java.util.Locale

/**
 * Channel-name normalization for the EPG fallback match (CONTRACT §5,
 * `test-vectors/xmltv/name-normalization.json`). Locale-independent: lower-casing always uses
 * [Locale.ROOT] so a Turkish device locale does not turn `I` into `ı`.
 *
 * Algorithm:
 * 1. lowercase (ROOT)
 * 2. NFD, drop U+0300..U+036F, then map ı→i ß→ss ø→o æ→ae œ→oe ł→l đ→d
 * 3. remove `[..]` and `(..)` groups
 * 4. split on `[^a-z0-9]+`, drop empty and stop tokens {hd,fhd,uhd,4k,sd,hevc,h265,tr,de,en}
 * 5. join without separator
 * 6. if empty: result of steps 1–3 with all `[^a-z0-9]` removed
 */
public object NameNormalizer {
    private val STOP_TOKENS = setOf("hd", "fhd", "uhd", "4k", "sd", "hevc", "h265", "tr", "de", "en")
    private val COMBINING = Regex("[\\u0300-\\u036f]")
    private val GROUPS = Regex("\\[[^\\]]*]|\\([^)]*\\)")
    private val NON_ALNUM = Regex("[^a-z0-9]+")

    /** Normalizes [name]; see the class documentation. */
    public fun normalize(name: String): String {
        var s = name.lowercase(Locale.ROOT)
        s = COMBINING.replace(Normalizer.normalize(s, Normalizer.Form.NFD), "")
        s = mapSpecial(s)
        s = GROUPS.replace(s, " ")
        val joined = s.split(NON_ALNUM).filter { it.isNotEmpty() && it !in STOP_TOKENS }.joinToString("")
        return joined.ifEmpty { NON_ALNUM.replace(s, "") }
    }

    private fun mapSpecial(s: String): String {
        if (s.none { it == 'ı' || it == 'ß' || it == 'ø' || it == 'æ' || it == 'œ' || it == 'ł' || it == 'đ' }) return s
        val sb = StringBuilder(s.length + 4)
        for (c in s) {
            when (c) {
                'ı' -> sb.append('i')
                'ß' -> sb.append("ss")
                'ø' -> sb.append('o')
                'æ' -> sb.append("ae")
                'œ' -> sb.append("oe")
                'ł' -> sb.append('l')
                'đ' -> sb.append('d')
                else -> sb.append(c)
            }
        }
        return sb.toString()
    }
}
