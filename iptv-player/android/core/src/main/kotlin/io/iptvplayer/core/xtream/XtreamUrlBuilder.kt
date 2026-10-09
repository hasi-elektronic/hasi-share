package io.iptvplayer.core.xtream

import io.iptvplayer.core.error.PlaybackError
import io.iptvplayer.core.error.PlaybackException
import io.iptvplayer.core.media.PlayerEngine
import io.iptvplayer.core.model.SourceSecrets
import io.iptvplayer.core.util.PercentEncoding
import io.iptvplayer.core.util.UrlNormalizer
import java.time.DateTimeException
import java.time.Instant
import java.time.ZoneId
import java.time.ZoneOffset
import java.time.format.DateTimeFormatter
import java.util.Locale

/** User preference "live stream format" (Settings → Playback; Android only). */
public enum class LiveFormatPreference { AUTO, TS, HLS }

/**
 * Builds Xtream Codes URLs (CONTRACT §4.2, §4.5). Username and password are percent-encoded
 * with the unreserved-only rule ([PercentEncoding]).
 *
 * Stream URLs contain credentials: build them at play time, never persist or log them
 * unredacted.
 *
 * @param serverUrl user-typed server URL; normalized with [UrlNormalizer.xtreamBase].
 */
public class XtreamUrlBuilder(serverUrl: String, username: String, password: String) {
    /** Normalized base `scheme://host[:port][/path]`. */
    public val base: String = UrlNormalizer.xtreamBase(serverUrl)
    private val u = PercentEncoding.encode(username)
    private val p = PercentEncoding.encode(password)

    public constructor(secrets: SourceSecrets.Xtream) : this(secrets.serverUrl, secrets.username, secrets.password)

    /**
     * `{base}/player_api.php?username=U&password=P[&action=A][&k=v…]`.
     * [params] values are percent-encoded; null values are skipped.
     */
    public fun api(action: String? = null, vararg params: Pair<String, String?>): String = buildString {
        append(base).append("/player_api.php?username=").append(u).append("&password=").append(p)
        if (action != null) append("&action=").append(PercentEncoding.encode(action))
        for ((k, v) in params) if (v != null) append('&').append(PercentEncoding.encode(k)).append('=').append(PercentEncoding.encode(v))
    }

    /** `{base}/xmltv.php?username=U&password=P` (full XMLTV guide). */
    public fun xmltv(): String = "$base/xmltv.php?username=$u&password=$p"

    /** `{base}/live/U/P/{streamId}.{ext}` – ext from [liveExtension]. */
    public fun live(streamId: String, ext: String): String = path("live", streamId, ext)

    /** `{base}/movie/U/P/{streamId}.{containerExt}`. */
    public fun movie(streamId: String, containerExt: String): String = path("movie", streamId, containerExt)

    /** `{base}/series/U/P/{episodeId}.{containerExt}`. */
    public fun episode(episodeId: String, containerExt: String): String = path("series", episodeId, containerExt)

    /**
     * Catch-up URL `{base}/timeshift/U/P/{durationMinutes}/{start}/{streamId}.{ext}` where
     * `start` is the programme start formatted `yyyy-MM-dd:HH-mm` in the **server** timezone
     * ([serverTimezone], fallback UTC) and `durationMinutes = ceil((end − start) / 60 s)`.
     */
    public fun timeshift(streamId: String, startMs: Long, endMs: Long, serverTimezone: String?, ext: String): String {
        val minutes = timeshiftDurationMinutes(startMs, endMs)
        val start = formatTimeshiftStart(startMs, serverTimezone)
        return "$base/timeshift/$u/$p/$minutes/$start/${PercentEncoding.encode(streamId)}.${PercentEncoding.encode(ext)}"
    }

    private fun path(kind: String, id: String, ext: String): String =
        "$base/$kind/$u/$p/${PercentEncoding.encode(id)}.${PercentEncoding.encode(ext)}"

    override fun toString(): String = "XtreamUrlBuilder(base=$base, credentials=***)"

    public companion object {
        private val TIMESHIFT_FORMAT: DateTimeFormatter = DateTimeFormatter.ofPattern("yyyy-MM-dd:HH-mm", Locale.ROOT)

        /** `ceil((end − start) / 60 s)`, at least 1. */
        public fun timeshiftDurationMinutes(startMs: Long, endMs: Long): Long {
            val ms = (endMs - startMs).coerceAtLeast(1)
            return (ms + 59_999) / 60_000
        }

        /** Formats [startMs] as `yyyy-MM-dd:HH-mm` in [serverTimezone] (fallback UTC). */
        public fun formatTimeshiftStart(startMs: Long, serverTimezone: String?): String =
            TIMESHIFT_FORMAT.format(Instant.ofEpochMilli(startMs).atZone(zoneOrUtc(serverTimezone)))

        /** Parses an IANA zone id, falling back to UTC when null/blank/invalid. */
        public fun zoneOrUtc(id: String?): ZoneId {
            if (id.isNullOrBlank()) return ZoneOffset.UTC
            return try {
                ZoneId.of(id.trim())
            } catch (_: DateTimeException) {
                ZoneOffset.UTC
            }
        }

        /**
         * Live extension selection (CONTRACT §4.5): Android (Media3) → `ts` if allowed else
         * `m3u8`; Apple (AVPlayer) → `m3u8`; Apple with only `ts` allowed →
         * [PlaybackError.UnsupportedFormat] (`mpegts`). Missing/empty
         * `allowed_output_formats` ⇒ both allowed. [preference] (Android setting) can force HLS.
         *
         * @throws PlaybackException for the Apple-only-TS case.
         */
        public fun liveExtension(
            engine: PlayerEngine,
            allowedOutputFormats: List<String>,
            preference: LiveFormatPreference = LiveFormatPreference.AUTO,
        ): String {
            val allowed = allowedOutputFormats.map { it.trim().lowercase(Locale.ROOT) }.filter { it.isNotEmpty() }.toSet()
            val tsAllowed = allowed.isEmpty() || "ts" in allowed
            val hlsAllowed = allowed.isEmpty() || "m3u8" in allowed || "hls" in allowed
            return when (engine) {
                PlayerEngine.MEDIA3 -> when (preference) {
                    LiveFormatPreference.HLS -> if (hlsAllowed) "m3u8" else "ts"
                    LiveFormatPreference.AUTO, LiveFormatPreference.TS -> if (tsAllowed) "ts" else "m3u8"
                }
                PlayerEngine.AVPLAYER -> {
                    if (!hlsAllowed && tsAllowed) throw PlaybackException(PlaybackError.UnsupportedFormat("mpegts"))
                    "m3u8"
                }
            }
        }
    }
}
