package io.iptvplayer.core.xmltv

import io.iptvplayer.core.error.SourceError
import io.iptvplayer.core.net.HttpDefaults
import io.iptvplayer.core.net.SourceHttp
import io.iptvplayer.core.util.NameNormalizer
import java.util.Locale

/**
 * Channel ↔ EPG matching (CONTRACT §5): `programme.channel == Channel.epgId` (case-insensitive)
 * first; fallback by normalized name ([NameNormalizer]) against the XMLTV display names.
 *
 * Build it once per EPG import from the parsed `<channel>` list (+ the programme channel ids),
 * then resolve every source channel with [match]. The result is the XMLTV channel id under which
 * programmes are stored (`EpgProgram.channelEpgId`).
 */
public class EpgMatcher(channels: Collection<XmltvChannel>, extraChannelIds: Collection<String> = emptyList()) {
    private val byId = HashMap<String, String>()
    private val byName = HashMap<String, String>()

    init {
        for (c in channels) {
            byId.putIfAbsent(c.id.lowercase(Locale.ROOT), c.id)
        }
        for (id in extraChannelIds) byId.putIfAbsent(id.lowercase(Locale.ROOT), id)
        for (c in channels) {
            for (n in c.displayNames) {
                val key = NameNormalizer.normalize(n)
                if (key.isNotEmpty()) byName.putIfAbsent(key, c.id)
            }
        }
    }

    /** Number of distinct EPG channel ids known. */
    public val size: Int get() = byId.size

    /**
     * XMLTV channel id for a source channel with [epgId] (`tvg-id` / `epg_channel_id`) and
     * display [name] (also try `tvg-name` via [altNames]); null when nothing matches.
     */
    public fun match(epgId: String?, name: String?, vararg altNames: String?): String? {
        if (!epgId.isNullOrBlank()) byId[epgId.trim().lowercase(Locale.ROOT)]?.let { return it }
        for (n in sequenceOf(name, *altNames)) {
            if (n.isNullOrBlank()) continue
            val key = NameNormalizer.normalize(n)
            if (key.isNotEmpty()) byName[key]?.let { return it }
        }
        return null
    }
}

/**
 * EPG retention window (CONTRACT §5): `[now − max(catchupDays, 1 day), now + 7 days]`.
 */
public object EpgRetention {
    private const val DAY_MS = 86_400_000L

    /** Days of future EPG kept. */
    public const val FUTURE_DAYS: Int = 7

    /** The window in epoch ms. */
    public fun window(nowMs: Long, catchupDays: Int): LongRange =
        (nowMs - maxOf(catchupDays, 1) * DAY_MS)..(nowMs + FUTURE_DAYS * DAY_MS)

    /** True when the programme `[startMs, endMs)` overlaps [window]. */
    public fun keep(startMs: Long, endMs: Long, window: LongRange): Boolean =
        endMs > window.first && startMs < window.last

    /** Programmes ending before this instant can be deleted. */
    public fun purgeBefore(nowMs: Long, catchupDays: Int): Long = window(nowMs, catchupDays).first
}

/**
 * Downloads and parses an XMLTV guide (whole-call timeout 120 s, gzip auto-detect, retries).
 */
public class EpgClient(
    private val http: SourceHttp,
    private val parser: XmltvParser,
) {
    /**
     * Fetches [url] and streams channels/programmes to the callbacks.
     * @throws io.iptvplayer.core.error.SourceException on failure.
     */
    public suspend fun fetch(
        url: String,
        options: XmltvOptions = XmltvOptions(),
        userAgent: String? = null,
        callTimeoutMs: Long = HttpDefaults.PLAYLIST_CALL_TIMEOUT_MS,
        onChannels: suspend (List<XmltvChannel>) -> Unit = {},
        onProgrammes: suspend (List<XmltvProgramme>) -> Unit,
    ): XmltvParseResult = http.get(
        url = url,
        callTimeoutMs = callTimeoutMs,
        headers = userAgent?.let { mapOf("User-Agent" to it) } ?: emptyMap(),
        statusMapper = SourceError::fromListHttpStatus,
        tag = "Epg",
    ) { response ->
        val body = response.body ?: throw io.iptvplayer.core.error.SourceException(SourceError.InvalidFormat)
        parser.parse(body.source(), options, onChannels, onProgrammes)
    }
}
