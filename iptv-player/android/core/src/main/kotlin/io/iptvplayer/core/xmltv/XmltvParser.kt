package io.iptvplayer.core.xmltv

import io.iptvplayer.core.error.SourceError
import io.iptvplayer.core.error.SourceException
import io.iptvplayer.core.model.EpgProgram
import io.iptvplayer.core.util.Gzip
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import okio.BufferedSource
import org.xmlpull.v1.XmlPullParser
import org.xmlpull.v1.XmlPullParserException
import java.io.IOException
import java.util.Locale
import kotlin.coroutines.cancellation.CancellationException

/** `<channel>` of an XMLTV document. */
public data class XmltvChannel(val id: String, val displayNames: List<String>, val icon: String?)

/**
 * A parsed `<programme>` (times already shifted, end filled in, invalid ones dropped).
 * [channel] is the XMLTV channel id exactly as in the document.
 */
public data class XmltvProgramme(
    val channel: String,
    val startMs: Long,
    val endMs: Long,
    val title: String,
    val description: String?,
    val category: String?,
) {
    /** Converts to the domain model. */
    public fun toEpgProgram(sourceId: String): EpgProgram =
        EpgProgram(sourceId, channel, startMs, endMs, title, description, category)
}

/**
 * Options of [XmltvParser.parse].
 * @property preferredLanguage UI language (`tr`, `en`); `title`/`desc` with a matching `lang`
 *   win, else the first one.
 * @property shiftMinutes the source's `epgShiftMinutes`, added to every time.
 * @property window optional retention window (epoch ms); programmes not overlapping it are
 *   skipped (see [EpgRetention]).
 */
public data class XmltvOptions(
    val preferredLanguage: String? = null,
    val shiftMinutes: Int = 0,
    val batchSize: Int = 1000,
    val window: LongRange? = null,
)

/**
 * Result of a parse run.
 * @property programmeChannelIds distinct `programme@channel` values (useful for [EpgMatcher]).
 * @property dropped programmes dropped as invalid (bad start, end ≤ start, no channel).
 * @property outsideWindow programmes skipped because of [XmltvOptions.window].
 */
public data class XmltvParseResult(
    val channelCount: Int,
    val programmeCount: Int,
    val dropped: Int,
    val outsideWindow: Int,
    val programmeChannelIds: Set<String>,
)

/**
 * Streaming XMLTV parser (CONTRACT §5) on the `org.xmlpull.v1` API.
 *
 * * Input may be gzip (magic `1f 8b`) regardless of extension.
 * * Missing/invalid `stop` ⇒ start of the next programme of the same channel, else
 *   start + 30 min. (Assumes programmes of one channel appear in chronological order, which is
 *   how XMLTV files are produced; out-of-order input still yields sane, possibly overlapping,
 *   programmes.)
 * * Programmes with invalid start or end ≤ start are dropped.
 * * Programmes are emitted in batches in document order (not sorted).
 *
 * @param parserFactory creates a fresh pull parser; on Android pass `{ Xml.newPullParser() }`,
 *   on the JVM `{ org.kxml2.io.KXmlParser() }`.
 */
public class XmltvParser(private val parserFactory: () -> XmlPullParser) {

    private class Pending(
        val channel: String,
        val startMs: Long,
        val title: String,
        val description: String?,
        val category: String?,
    )

    /**
     * Parses [source].
     * @param onChannels receives `<channel>` elements in batches.
     * @param onProgrammes receives programmes in batches of ≤ `options.batchSize`.
     * @throws SourceException [SourceError.InvalidFormat] when the input is not XMLTV,
     *   [SourceError.Network] on I/O errors.
     */
    public suspend fun parse(
        source: BufferedSource,
        options: XmltvOptions = XmltvOptions(),
        onChannels: suspend (List<XmltvChannel>) -> Unit = {},
        onProgrammes: suspend (List<XmltvProgramme>) -> Unit,
    ): XmltvParseResult {
        val shiftMs = options.shiftMinutes * 60_000L
        val batchSize = options.batchSize.coerceAtLeast(1)
        val lang = options.preferredLanguage?.lowercase(Locale.ROOT)?.substringBefore('-')?.substringBefore('_')
        var programmes = ArrayList<XmltvProgramme>(minOf(batchSize, 1024))
        var channels = ArrayList<XmltvChannel>()
        val pending = HashMap<String, ArrayList<Pending>>()
        val programmeChannelIds = HashSet<String>()
        var channelCount = 0
        var programmeCount = 0
        var dropped = 0
        var outsideWindow = 0

        suspend fun emit(p: XmltvProgramme) {
            if (p.endMs <= p.startMs) {
                dropped++
                return
            }
            val w = options.window
            if (w != null && !(p.endMs > w.first && p.startMs < w.last)) {
                outsideWindow++
                return
            }
            programmes.add(p)
            programmeCount++
            if (programmes.size >= batchSize) {
                currentCoroutineContext().ensureActive()
                val full = programmes
                programmes = ArrayList(minOf(batchSize, 1024))
                onProgrammes(full)
            }
        }

        suspend fun resolvePending(channel: String, nextStart: Long) {
            val list = pending[channel] ?: return
            val it = list.iterator()
            while (it.hasNext()) {
                val p = it.next()
                if (p.startMs < nextStart) {
                    emit(XmltvProgramme(p.channel, p.startMs, nextStart, p.title, p.description, p.category))
                    it.remove()
                }
            }
            if (list.isEmpty()) pending.remove(channel)
        }

        val xpp = parserFactory()
        try {
            trySetFeature(xpp, XmlPullParser.FEATURE_PROCESS_NAMESPACES, false)
            trySetFeature(xpp, FEATURE_RELAXED, true)
            xpp.setInput(Gzip.maybeGunzip(source).inputStream(), null)
            var event = xpp.eventType
            var sawRoot = false
            var elements = 0
            while (event != XmlPullParser.END_DOCUMENT) {
                if (event == XmlPullParser.START_TAG) {
                    if (!sawRoot) {
                        if (xpp.name != "tv") throw SourceException(SourceError.InvalidFormat)
                        sawRoot = true
                    } else {
                        when (xpp.name) {
                            "channel" -> {
                                readChannel(xpp)?.let {
                                    channels.add(it)
                                    channelCount++
                                    if (channels.size >= batchSize) {
                                        val full = channels
                                        channels = ArrayList()
                                        onChannels(full)
                                    }
                                }
                            }
                            "programme" -> {
                                val raw = readProgramme(xpp, lang)
                                val start = XmltvTime.parse(raw.start)
                                if (start == null || raw.channel.isNullOrEmpty()) {
                                    dropped++
                                } else {
                                    val channel = raw.channel
                                    val s = start + shiftMs
                                    programmeChannelIds.add(channel)
                                    resolvePending(channel, s)
                                    val stop = XmltvTime.parse(raw.stop)
                                    if (stop != null) {
                                        emit(XmltvProgramme(channel, s, stop + shiftMs, raw.title, raw.description, raw.category))
                                    } else {
                                        pending.getOrPut(channel) { ArrayList(1) }
                                            .add(Pending(channel, s, raw.title, raw.description, raw.category))
                                    }
                                }
                                if (++elements and 0x3FF == 0) currentCoroutineContext().ensureActive()
                            }
                        }
                    }
                }
                event = xpp.next()
            }
            if (!sawRoot) throw SourceException(SourceError.InvalidFormat)
        } catch (e: XmlPullParserException) {
            throw SourceException(SourceError.InvalidFormat, e)
        } catch (e: IOException) {
            throw e
        } catch (e: CancellationException) {
            throw e
        } catch (e: RuntimeException) {
            // kxml throws runtime exceptions on some malformed input.
            throw SourceException(SourceError.InvalidFormat, e)
        }
        // Programmes without stop and without a successor: start + 30 min.
        for (list in pending.values) {
            for (p in list) emit(XmltvProgramme(p.channel, p.startMs, p.startMs + DEFAULT_DURATION_MS, p.title, p.description, p.category))
        }
        pending.clear()
        if (channels.isNotEmpty()) onChannels(channels)
        if (programmes.isNotEmpty()) onProgrammes(programmes)
        return XmltvParseResult(channelCount, programmeCount, dropped, outsideWindow, programmeChannelIds)
    }

    private class RawProgramme(
        val start: String?,
        val stop: String?,
        val channel: String?,
        val title: String,
        val description: String?,
        val category: String?,
    )

    private fun readChannel(xpp: XmlPullParser): XmltvChannel? {
        val id = xpp.getAttributeValue(null, "id")?.trim()
        val depth = xpp.depth
        val names = ArrayList<String>(2)
        var icon: String? = null
        while (true) {
            val ev = xpp.next()
            if (ev == XmlPullParser.END_DOCUMENT) break
            if (ev == XmlPullParser.END_TAG && xpp.depth == depth) break
            if (ev == XmlPullParser.START_TAG) {
                when (xpp.name) {
                    "display-name" -> readText(xpp).takeIf { it.isNotEmpty() }?.let(names::add)
                    "icon" -> if (icon == null) icon = xpp.getAttributeValue(null, "src")?.trim()?.ifEmpty { null }
                }
            }
        }
        if (id.isNullOrEmpty()) return null
        return XmltvChannel(id, names, icon)
    }

    private fun readProgramme(xpp: XmlPullParser, lang: String?): RawProgramme {
        val start = xpp.getAttributeValue(null, "start")
        val stop = xpp.getAttributeValue(null, "stop")
        val channel = xpp.getAttributeValue(null, "channel")?.trim()
        val depth = xpp.depth
        var title: String? = null
        var titleMatched = false
        var desc: String? = null
        var descMatched = false
        var category: String? = null
        while (true) {
            val ev = xpp.next()
            if (ev == XmlPullParser.END_DOCUMENT) break
            if (ev == XmlPullParser.END_TAG && xpp.depth == depth) break
            if (ev == XmlPullParser.START_TAG && xpp.depth == depth + 1) {
                when (xpp.name) {
                    "title" -> {
                        val matches = langMatches(xpp.getAttributeValue(null, "lang"), lang)
                        val text = readText(xpp)
                        if (!titleMatched && (title == null || matches) && text.isNotEmpty()) {
                            title = text
                            titleMatched = matches
                        }
                    }
                    "desc" -> {
                        val matches = langMatches(xpp.getAttributeValue(null, "lang"), lang)
                        val text = readText(xpp)
                        if (!descMatched && (desc == null || matches) && text.isNotEmpty()) {
                            desc = text
                            descMatched = matches
                        }
                    }
                    "category" -> {
                        val text = readText(xpp)
                        if (category == null && text.isNotEmpty()) category = text
                    }
                }
            }
        }
        return RawProgramme(start, stop, channel, title.orEmpty(), desc, category)
    }

    /** Collects all text (incl. CDATA, resolved entities) until the end tag of the current element. */
    private fun readText(xpp: XmlPullParser): String {
        val depth = xpp.depth
        val sb = StringBuilder()
        while (true) {
            val ev = xpp.next()
            when (ev) {
                XmlPullParser.TEXT, XmlPullParser.CDSECT, XmlPullParser.ENTITY_REF -> xpp.text?.let(sb::append)
                XmlPullParser.END_TAG -> if (xpp.depth == depth) break
                XmlPullParser.END_DOCUMENT -> break
            }
        }
        return sb.toString().trim()
    }

    private fun langMatches(attr: String?, lang: String?): Boolean {
        if (attr == null || lang == null) return false
        val a = attr.trim().lowercase(Locale.ROOT)
        return a == lang || a.startsWith("$lang-") || a.startsWith("${lang}_")
    }

    private fun trySetFeature(xpp: XmlPullParser, name: String, value: Boolean) {
        try {
            xpp.setFeature(name, value)
        } catch (_: XmlPullParserException) {
            // Feature not supported by this implementation – fine.
        } catch (_: RuntimeException) {
        }
    }

    public companion object {
        /** Duration used when a programme has neither `stop` nor a successor. */
        public const val DEFAULT_DURATION_MS: Long = 30 * 60_000L

        /** kxml / Android KXmlParser "relaxed" mode (tolerates unknown entities). */
        public const val FEATURE_RELAXED: String = "http://xmlpull.org/v1/doc/features.html#relaxed"
    }
}
