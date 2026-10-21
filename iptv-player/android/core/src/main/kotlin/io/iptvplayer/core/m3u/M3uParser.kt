package io.iptvplayer.core.m3u

import io.iptvplayer.core.error.SourceError
import io.iptvplayer.core.error.SourceException
import io.iptvplayer.core.model.ContentKind
import io.iptvplayer.core.util.UrlNormalizer
import io.iptvplayer.core.util.UrlParts
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.serialization.Serializable
import okio.BufferedSource
import java.util.Locale

/** Series info detected from an M3U title (CONTRACT §3.10). */
@Serializable
public data class M3uSeriesInfo(val name: String, val season: Int, val episode: Int)

/** Raw catch-up attributes of an M3U entry; [type] defaults to `default`, [days] to 0. */
@Serializable
public data class M3uCatchup(val type: String, val days: Int, val source: String?)

/**
 * One parsed M3U entry – exactly the expected-output schema of the `test-vectors/m3u` `.expected.json` files.
 *
 * @property duration `#EXTINF` duration in seconds, -1 when absent/unparsable.
 * @property series non-null only for [ContentKind.EPISODE] entries whose title matches the
 *   series regex.
 */
@Serializable
public data class M3uEntry(
    val name: String,
    val url: String,
    val kind: ContentKind,
    val tvgId: String? = null,
    val tvgName: String? = null,
    val logo: String? = null,
    val group: String? = null,
    val chno: Int? = null,
    val duration: Double = -1.0,
    val catchup: M3uCatchup? = null,
    val tvgShiftHours: Double? = null,
    val userAgent: String? = null,
    val referrer: String? = null,
    val drm: Boolean = false,
    val series: M3uSeriesInfo? = null,
)

/**
 * Summary of a parse run.
 * @property epgUrls `url-tvg` / `x-tvg-url` header values (deduplicated, order kept).
 * @property skipped dropped entries (bad scheme, `#EXTINF` without URL, garbage lines).
 * @property count emitted entries.
 */
public data class M3uParseResult(val epgUrls: List<String>, val skipped: Int, val count: Int)

/**
 * Streaming M3U parser of CONTRACT §3 – an incremental, line-based state machine.
 *
 * Usage (incremental): create with an [onEntry] callback, call [feedLine] for every line, then
 * [finish]. Usage (stream): [M3uParser.parse] reads an Okio [BufferedSource] line by line and
 * emits batches of ≤ `batchSize` entries; the playlist is never held in memory as one string.
 *
 * Not thread-safe; one instance per parse.
 */
public class M3uParser(private val onEntry: (M3uEntry) -> Unit) {
    private var firstLine = true
    private var sawHeader = false
    private var sawExtinf = false
    private val epgUrls = LinkedHashSet<String>()

    /** Number of dropped entries so far. */
    public var skipped: Int = 0
        private set

    /** Number of emitted entries so far. */
    public var count: Int = 0
        private set

    // Per-entry state (reset after each URL / dropped entry).
    private var pending: PendingInfo? = null
    private var extGroup: String? = null
    private var userAgent: String? = null
    private var referrer: String? = null
    private var drm = false

    private class PendingInfo(val duration: Double, val attrs: Map<String, String?>, val title: String)

    /** Feeds one raw line (line terminators may or may not be included). */
    public fun feedLine(rawLine: String) {
        var line = rawLine
        if (firstLine) {
            firstLine = false
            if (line.isNotEmpty() && line[0] == '﻿') line = line.substring(1)
        }
        line = line.trim()
        if (line.isEmpty()) return
        if (line[0] == '#') {
            when {
                line.startsWith("#EXTINF:", ignoreCase = true) -> onExtinf(line.substring(8))
                line.startsWith("#EXTM3U", ignoreCase = true) -> onHeader(line.substring(7))
                line.startsWith("#EXTGRP:", ignoreCase = true) -> extGroup = line.substring(8).trim().ifEmpty { null }
                line.startsWith("#EXTVLCOPT:", ignoreCase = true) -> onVlcOpt(line.substring(11))
                line.startsWith("#KODIPROP:", ignoreCase = true) -> onKodiProp(line.substring(10))
                else -> Unit // other directives are ignored
            }
        } else {
            onUrl(line)
        }
    }

    /**
     * Ends the input and validates the result (CONTRACT §3.11).
     * @throws SourceException with [SourceError.InvalidFormat] (no entries, no header, no
     *   `#EXTINF`) or [SourceError.Empty] (no entries otherwise).
     */
    public fun finish(): M3uParseResult {
        endOfInput()
        if (count == 0) {
            throw SourceException(if (!sawHeader && !sawExtinf) SourceError.InvalidFormat else SourceError.Empty)
        }
        return summary()
    }

    /** Current counters without validation. */
    public fun summary(): M3uParseResult = M3uParseResult(epgUrls.toList(), skipped, count)

    private fun endOfInput() {
        if (pending != null) {
            skipped++
            resetEntry()
        }
    }

    private fun resetEntry() {
        pending = null
        extGroup = null
        userAgent = null
        referrer = null
        drm = false
    }

    private fun onHeader(rest: String) {
        sawHeader = true
        val attrs = HashMap<String, String?>()
        parseAttributes(rest, 0, attrs)
        for (key in HEADER_EPG_KEYS) {
            attrs[key]?.split(',')?.forEach { u -> u.trim().takeIf { it.isNotEmpty() }?.let(epgUrls::add) }
        }
    }

    private fun onExtinf(text: String) {
        if (pending != null) {
            // #EXTINF followed by another #EXTINF: the first one is dropped.
            skipped++
            resetEntry()
        }
        sawExtinf = true
        val split = splitTitle(text)
        val head = split.first
        var i = 0
        while (i < head.length && head[i].isWhitespace()) i++
        val durStart = i
        while (i < head.length && !head[i].isWhitespace()) i++
        val duration = head.substring(durStart, i).toDoubleOrNull()?.takeIf { !it.isNaN() } ?: -1.0
        val attrs = HashMap<String, String?>(8)
        parseAttributes(head, i, attrs)
        pending = PendingInfo(duration, attrs, split.second.trim())
    }

    private fun onVlcOpt(text: String) {
        val eq = text.indexOf('=')
        if (eq <= 0) return
        val key = text.substring(0, eq).trim().lowercase(Locale.ROOT)
        val value = text.substring(eq + 1).trim().ifEmpty { null }
        when (key) {
            "http-user-agent" -> userAgent = value
            "http-referrer", "http-referer" -> referrer = value
        }
    }

    private fun onKodiProp(text: String) {
        val key = text.substringBefore('=').trim().lowercase(Locale.ROOT)
        if (text.contains('=') && (key == "inputstream.adaptive.license_type" || key == "inputstream.adaptive.license_key")) {
            drm = true
        }
    }

    private fun onUrl(url: String) {
        val scheme = schemeOf(url)
        if (scheme == null || scheme !in ALLOWED_SCHEMES) {
            skipped++
            resetEntry()
            return
        }
        val info = pending
        val attrs: Map<String, String?> = info?.attrs ?: emptyMap()
        val tvgName = attrs["tvg-name"]
        val title = info?.title.orEmpty()
        val name = title.ifEmpty { tvgName ?: UrlNormalizer.lastPathSegment(url) ?: url }
        val kind = classify(url, name)
        val catchupType = attrs["catchup"] ?: attrs["catchup-type"]
        val catchupDays = attrs["catchup-days"] ?: attrs["timeshift"]
        val catchupSource = attrs["catchup-source"]
        val catchup = if (catchupType != null || catchupDays != null || catchupSource != null) {
            M3uCatchup(type = catchupType ?: "default", days = parseIntLenient(catchupDays) ?: 0, source = catchupSource)
        } else {
            null
        }
        val entry = M3uEntry(
            name = name,
            url = url,
            kind = kind,
            tvgId = attrs["tvg-id"],
            tvgName = tvgName,
            logo = attrs["tvg-logo"],
            group = attrs["group-title"] ?: extGroup,
            chno = attrs["tvg-chno"]?.toIntOrNull(),
            duration = info?.duration ?: -1.0,
            catchup = catchup,
            tvgShiftHours = attrs["tvg-shift"]?.toDoubleOrNull()?.takeIf { !it.isNaN() && !it.isInfinite() },
            userAgent = userAgent,
            referrer = referrer,
            drm = drm,
            series = if (kind == ContentKind.EPISODE) detectSeries(name) else null,
        )
        resetEntry()
        count++
        onEntry(entry)
    }

    public companion object {
        /** Default batch size (CONTRACT §3.12). */
        public const val DEFAULT_BATCH_SIZE: Int = 1000

        /** Longest accepted line; longer lines are truncated (protects memory on garbage input). */
        public const val MAX_LINE_BYTES: Long = 1L shl 20

        /** Allowed URL schemes (CONTRACT §3.7). */
        public val ALLOWED_SCHEMES: Set<String> = setOf("http", "https", "rtmp", "rtmps", "rtsp", "udp", "rtp")

        /** VOD file extensions (CONTRACT §3.9). */
        public val VOD_EXTENSIONS: Set<String> = setOf("mp4", "mkv", "avi", "mov", "m4v", "wmv", "flv", "webm", "mpg", "mpeg")

        private val HEADER_EPG_KEYS = listOf("url-tvg", "x-tvg-url")

        /** Series regex of CONTRACT §3.10. */
        public val SERIES_REGEX: Regex =
            Regex("""^(.*?)[\s._-]*S(\d{1,2})[\s._-]*E(\d{1,3})\b""", RegexOption.IGNORE_CASE)

        /**
         * Streams [source] line by line and emits batches of at most [batchSize] entries to
         * [onBatch]. Checks for coroutine cancellation between batches; cancel the HTTP call
         * to abort a blocked read.
         *
         * @throws SourceException [SourceError.InvalidFormat] / [SourceError.Empty] (§3.11).
         */
        public suspend fun parse(
            source: BufferedSource,
            batchSize: Int = DEFAULT_BATCH_SIZE,
            onBatch: suspend (List<M3uEntry>) -> Unit,
        ): M3uParseResult {
            require(batchSize > 0)
            var batch = ArrayList<M3uEntry>(minOf(batchSize, 1024))
            val parser = M3uParser { batch.add(it) }
            val reader = LineReader(source, MAX_LINE_BYTES)
            var lines = 0
            while (true) {
                val line = reader.readLine() ?: break
                parser.feedLine(line)
                if (batch.size >= batchSize) {
                    currentCoroutineContext().ensureActive()
                    val full = batch
                    batch = ArrayList(minOf(batchSize, 1024))
                    onBatch(full)
                } else if (++lines and 0xFFF == 0) {
                    currentCoroutineContext().ensureActive()
                }
            }
            parser.endOfInput()
            if (batch.isNotEmpty()) onBatch(batch)
            return parser.finish()
        }

        /** Blocking variant of [parse] (no coroutine needed). */
        public fun parseBlocking(
            source: BufferedSource,
            batchSize: Int = DEFAULT_BATCH_SIZE,
            onBatch: (List<M3uEntry>) -> Unit,
        ): M3uParseResult {
            require(batchSize > 0)
            var batch = ArrayList<M3uEntry>(minOf(batchSize, 1024))
            val parser = M3uParser { batch.add(it) }
            val reader = LineReader(source, MAX_LINE_BYTES)
            while (true) {
                val line = reader.readLine() ?: break
                parser.feedLine(line)
                if (batch.size >= batchSize) {
                    val full = batch
                    batch = ArrayList(minOf(batchSize, 1024))
                    onBatch(full)
                }
            }
            parser.endOfInput()
            if (batch.isNotEmpty()) onBatch(batch)
            return parser.finish()
        }

        /** Parses a whole (small) playlist text – convenience for tests and pasted lists. */
        public fun parseText(text: String): Pair<List<M3uEntry>, M3uParseResult> {
            val out = ArrayList<M3uEntry>()
            val parser = M3uParser { out.add(it) }
            text.split('\n').forEach(parser::feedLine)
            return out to parser.finish()
        }

        /** Kind classification of CONTRACT §3.9. */
        public fun classify(url: String, title: String): ContentKind {
            val path = (UrlParts.parse(url)?.path ?: url.substringBefore('?')).lowercase(Locale.ROOT)
            return when {
                path.contains("/movie/") -> ContentKind.MOVIE
                path.contains("/series/") -> ContentKind.EPISODE
                extensionOf(path) in VOD_EXTENSIONS ->
                    if (SERIES_REGEX.containsMatchIn(title)) ContentKind.EPISODE else ContentKind.MOVIE
                else -> ContentKind.LIVE
            }
        }

        /** Applies the series regex (CONTRACT §3.10); null when the title does not match. */
        public fun detectSeries(title: String): M3uSeriesInfo? {
            val m = SERIES_REGEX.find(title) ?: return null
            val season = m.groupValues[2].toIntOrNull() ?: return null
            val episode = m.groupValues[3].toIntOrNull() ?: return null
            return M3uSeriesInfo(m.groupValues[1].trim(), season, episode)
        }

        private fun extensionOf(path: String): String? {
            val seg = path.substringAfterLast('/')
            val dot = seg.lastIndexOf('.')
            return if (dot < 0 || dot == seg.lastIndex) null else seg.substring(dot + 1)
        }

        private fun parseIntLenient(v: String?): Int? =
            v?.trim()?.let { it.toIntOrNull() ?: it.toDoubleOrNull()?.takeIf { d -> !d.isNaN() }?.toInt() }

        /** Lower-case scheme of `scheme://…`, or null when the line has none. */
        internal fun schemeOf(url: String): String? {
            val sep = url.indexOf("://")
            if (sep <= 0) return null
            for (i in 0 until sep) {
                val c = url[i]
                val ok = if (i == 0) c.isLetter() else (c.isLetterOrDigit() || c == '+' || c == '-' || c == '.')
                if (!ok || c.code > 127) return null
            }
            return url.substring(0, sep).lowercase(Locale.ROOT)
        }

        /**
         * Splits the text after `#EXTINF:` into (head, title) at the first comma that is not
         * inside quotes; a quote opens only right after `=`. Unbalanced quotes → last comma.
         * No comma → title empty.
         */
        internal fun splitTitle(text: String): Pair<String, String> {
            var quote = 0.toChar()
            var inQuote = false
            for (i in text.indices) {
                val c = text[i]
                if (inQuote) {
                    if (c == quote) inQuote = false
                    continue
                }
                if (c == ',') return text.substring(0, i) to text.substring(i + 1)
                if ((c == '"' || c == '\'') && i > 0 && text[i - 1] == '=') {
                    inQuote = true
                    quote = c
                }
            }
            if (inQuote) {
                val last = text.lastIndexOf(',')
                if (last >= 0) return text.substring(0, last) to text.substring(last + 1)
            }
            return text to ""
        }

        /**
         * Parses `key=value` attributes from [s] starting at [from]. Values may be in double or
         * single quotes or unquoted (until whitespace); an unterminated quoted value extends to the
         * end. Keys are lower-cased; empty values become null; the first occurrence of a key wins.
         */
        internal fun parseAttributes(s: String, from: Int, into: MutableMap<String, String?>) {
            var i = from
            val n = s.length
            while (i < n) {
                while (i < n && s[i].isWhitespace()) i++
                if (i >= n) break
                val keyStart = i
                while (i < n && s[i] != '=' && !s[i].isWhitespace()) i++
                if (i >= n || s[i] != '=') continue // bare token without value
                val key = s.substring(keyStart, i)
                i++ // '='
                val value: String
                if (i < n && (s[i] == '"' || s[i] == '\'')) {
                    val q = s[i]
                    val end = s.indexOf(q, i + 1)
                    if (end < 0) {
                        value = s.substring(i + 1)
                        i = n
                    } else {
                        value = s.substring(i + 1, end)
                        i = end + 1
                    }
                } else {
                    val vs = i
                    while (i < n && !s[i].isWhitespace()) i++
                    value = s.substring(vs, i)
                }
                if (key.isNotEmpty()) {
                    val k = key.lowercase(Locale.ROOT)
                    if (!into.containsKey(k)) into[k] = value.trim().ifEmpty { null }
                }
            }
        }
    }
}

/**
 * Reads UTF-8 lines from an Okio source without loading it entirely. Lines longer than
 * [maxLineBytes] are truncated (the remainder up to the next newline is skipped).
 * Terminators (`\n`, `\r\n`) are not included.
 */
public class LineReader(private val source: BufferedSource, private val maxLineBytes: Long = M3uParser.MAX_LINE_BYTES) {
    private companion object {
        const val SKIP_CHUNK = 64L * 1024
    }

    /** Next line, or null at end of input. */
    public fun readLine(): String? {
        val nl = source.indexOf('\n'.code.toByte(), 0, maxLineBytes)
        if (nl >= 0) {
            val line = source.readUtf8(nl)
            source.skip(1)
            return line.removeSuffix("\r")
        }
        val buffered = source.buffer.size
        if (buffered == 0L && source.exhausted()) return null
        if (buffered < maxLineBytes) {
            // End of input without trailing newline.
            return source.readUtf8().removeSuffix("\r")
        }
        // Over-long line: keep the first maxLineBytes, drop the rest of the line.
        val line = source.readUtf8(maxLineBytes)
        while (true) {
            val idx = source.indexOf('\n'.code.toByte(), 0, SKIP_CHUNK)
            if (idx >= 0) {
                source.skip(idx + 1)
                break
            }
            if (!source.request(1)) break // end of input
            source.skip(minOf(source.buffer.size, SKIP_CHUNK))
        }
        return line
    }
}
