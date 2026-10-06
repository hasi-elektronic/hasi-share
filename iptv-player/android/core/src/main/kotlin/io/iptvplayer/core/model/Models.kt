package io.iptvplayer.core.model

import io.iptvplayer.core.CoreJson
import io.iptvplayer.core.error.SourceError
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import java.util.Locale

// Domain model of CONTRACT §1. All timestamps are UTC epoch **milliseconds** (`…Ms`).
// The classes are immutable and serializable so the Android layer can map them 1:1 to Room
// entities / DataStore / JSON caches.

/** Kind of a source (CONTRACT §1). */
@Serializable
public enum class SourceType {
    @SerialName("M3U")
    M3U,

    @SerialName("XTREAM")
    XTREAM,
}

/** Kind of a content item; [wire] is the value used in content keys and sync JSON. */
@Serializable
public enum class ContentKind(public val wire: String) {
    @SerialName("live")
    LIVE("live"),

    @SerialName("movie")
    MOVIE("movie"),

    @SerialName("series")
    SERIES("series"),

    @SerialName("episode")
    EPISODE("episode"),
    ;

    public companion object {
        /** Parses a wire value (`live`, `movie`, `series`, `episode`), case-insensitive. */
        public fun fromWire(value: String?): ContentKind? =
            entries.firstOrNull { it.wire.equals(value?.trim(), ignoreCase = true) }
    }
}

/** Catch-up flavour of a channel (CONTRACT §1 `catchup.type`). */
@Serializable
public enum class CatchupType(public val wire: String) {
    @SerialName("none")
    NONE("none"),

    @SerialName("xtream")
    XTREAM("xtream"),

    @SerialName("default")
    DEFAULT("default"),

    @SerialName("append")
    APPEND("append"),

    @SerialName("shift")
    SHIFT("shift"),

    @SerialName("flussonic")
    FLUSSONIC("flussonic"),
    ;

    public companion object {
        /**
         * Maps a raw M3U `catchup`/`catchup-type` attribute. Known aliases: `fs`, `flussonic-hls`,
         * `flussonic-ts` → [FLUSSONIC]; `xc` → [XTREAM]; `timeshift` → [SHIFT].
         * Unknown non-empty values → [DEFAULT]; null/empty → [NONE].
         */
        public fun fromWire(raw: String?): CatchupType {
            val v = raw?.trim()?.lowercase(Locale.ROOT)
            if (v.isNullOrEmpty()) return NONE
            return when (v) {
                "none", "disabled", "0" -> NONE
                "xtream", "xc" -> XTREAM
                "default", "vod" -> DEFAULT
                "append" -> APPEND
                "shift", "timeshift" -> SHIFT
                "flussonic", "fs", "flussonic-hls", "flussonic-ts" -> FLUSSONIC
                else -> DEFAULT
            }
        }
    }
}

/** Catch-up capability of a channel. [days] = archive length; [source] = M3U `catchup-source` template. */
@Serializable
public data class CatchupInfo(
    val type: CatchupType = CatchupType.NONE,
    val days: Int = 0,
    val source: String? = null,
) {
    /** True when the channel offers an archive. */
    val available: Boolean get() = type != CatchupType.NONE && days > 0

    public companion object {
        /** No catch-up. */
        public val NONE: CatchupInfo = CatchupInfo()
    }
}

/**
 * Result of the last refresh of a source (`Source.lastRefreshResult`).
 * [errorCode] is a stable [SourceError.code] (persistable), null on success.
 */
@Serializable
public data class SourceStatus(
    val ok: Boolean,
    val errorCode: String? = null,
    val liveCount: Int = 0,
    val movieCount: Int = 0,
    val seriesCount: Int = 0,
    val epgProgrammeCount: Int = 0,
    /** EPG failures do not fail the refresh; they are reported separately. */
    val epgErrorCode: String? = null,
) {
    /** Decoded [errorCode]. */
    val error: SourceError? get() = errorCode?.let { SourceError.fromCode(it) }

    /** Decoded [epgErrorCode]. */
    val epgError: SourceError? get() = epgErrorCode?.let { SourceError.fromCode(it) }

    public companion object {
        /** Builds a failed status from [error]. */
        public fun failed(error: SourceError): SourceStatus = SourceStatus(ok = false, errorCode = error.code)
    }
}

/** Account information returned by Xtream `player_api.php` (CONTRACT §1, §4.4). */
@Serializable
public data class XtreamAccountInfo(
    val status: String? = null,
    val expiresAtMs: Long? = null,
    val maxConnections: Int? = null,
    val activeConnections: Int? = null,
    val allowedOutputFormats: List<String> = emptyList(),
    /** `server_info.timezone`, default `UTC`; used only for catch-up URLs (CONTRACT §4.5). */
    val serverTimezone: String = "UTC",
    val isTrial: Boolean = false,
    val createdAtMs: Long? = null,
)

/**
 * A configured IPTV source (CONTRACT §1). Contains **no secrets**: credentials and playlist
 * URLs live in [SourceSecrets], stored encrypted (Android Keystore) under [id].
 *
 * @property fingerprint content-key fingerprint (§1.1) – a hash, safe to persist; lets favorites
 *   and progress be keyed without loading the secrets.
 */
@Serializable
public data class Source(
    val id: String,
    val name: String,
    val type: SourceType,
    val displayHost: String,
    val fingerprint: String,
    val epgUrlOverride: Boolean = false,
    val epgShiftMinutes: Int = 0,
    val autoRefreshHours: Int = 24,
    val createdAtMs: Long,
    val lastRefreshAtMs: Long? = null,
    val lastRefreshResult: SourceStatus? = null,
    val xtreamAccount: XtreamAccountInfo? = null,
) {
    /** Content key of an item of this source (CONTRACT §1.1). */
    public fun contentKey(kind: ContentKind, itemId: String): String = "$fingerprint:${kind.wire}:$itemId"
}

/**
 * Secret part of a source (CONTRACT §1) – store ONLY encrypted (Keystore-backed), keyed by
 * `Source.id`, excluded from backups. [toString] never prints credentials.
 */
@Serializable
public sealed class SourceSecrets {
    /** Optional EPG URL override. */
    public abstract val epgUrl: String?

    /** M3U playlist secrets. */
    @Serializable
    @SerialName("m3u")
    public data class M3u(
        val url: String,
        override val epgUrl: String? = null,
        val userAgent: String? = null,
    ) : SourceSecrets() {
        override fun toString(): String = "SourceSecrets.M3u(url=***, epgUrl=${if (epgUrl == null) "null" else "***"}, userAgent=$userAgent)"
    }

    /** Xtream Codes secrets. [serverUrl] as typed by the user (normalized at use time, §4.1). */
    @Serializable
    @SerialName("xtream")
    public data class Xtream(
        val serverUrl: String,
        val username: String,
        val password: String,
        override val epgUrl: String? = null,
    ) : SourceSecrets() {
        override fun toString(): String = "SourceSecrets.Xtream(server=***, username=***, password=***)"
    }

    /** The source type. */
    public val type: SourceType
        get() = when (this) {
            is M3u -> SourceType.M3U
            is Xtream -> SourceType.XTREAM
        }

    /** Values that must be registered with the log [io.iptvplayer.core.util.Redactor]. */
    public fun secretValues(): List<String> = when (this) {
        is M3u -> listOfNotNull(url, epgUrl)
        is Xtream -> listOfNotNull(username, password, epgUrl)
    }

    /** JSON for encrypted storage. */
    public fun toJson(): String = CoreJson.encodeToString(serializer(), this)

    public companion object {
        /** Parses [toJson] output. */
        public fun fromJson(json: String): SourceSecrets = CoreJson.decodeFromString(serializer(), json)
    }
}

/** A category of live channels, movies or series (CONTRACT §1). [kind] is LIVE, MOVIE or SERIES. */
@Serializable
public data class Category(
    val sourceId: String,
    val id: String,
    val kind: ContentKind,
    val name: String,
    val sort: Int,
)

/**
 * A live channel (CONTRACT §1). [url], [userAgent], [referrer] and [tvgShiftHours] are M3U-only;
 * Xtream URLs are built at play time ([io.iptvplayer.core.xtream.XtreamUrlBuilder]).
 */
@Serializable
public data class Channel(
    val sourceId: String,
    val id: String,
    val name: String,
    val number: Int? = null,
    val logoUrl: String? = null,
    val categoryId: String? = null,
    val epgId: String? = null,
    val catchup: CatchupInfo = CatchupInfo.NONE,
    val url: String? = null,
    val userAgent: String? = null,
    val referrer: String? = null,
    val drm: Boolean = false,
    val sort: Int = 0,
    /** M3U `tvg-shift` (hours) – per-channel EPG correction, added to the source shift. */
    val tvgShiftHours: Double? = null,
    /** Every category of the item, primary ([categoryId]) first (CONTRACT §4.3: Xtream `category_ids`). */
    val categoryIds: List<String> = listOfNotNull(categoryId),
)

/** A VOD movie (CONTRACT §1). */
@Serializable
public data class Movie(
    val sourceId: String,
    val id: String,
    val name: String,
    val posterUrl: String? = null,
    val categoryId: String? = null,
    val rating: Double? = null,
    val year: Int? = null,
    val plot: String? = null,
    val containerExt: String? = null,
    val url: String? = null,
    val addedAtMs: Long? = null,
    val sort: Int = 0,
    /** Every category of the item, primary ([categoryId]) first (CONTRACT §4.3: Xtream `category_ids`). */
    val categoryIds: List<String> = listOfNotNull(categoryId),
)

/** A series (CONTRACT §1). */
@Serializable
public data class Series(
    val sourceId: String,
    val id: String,
    val name: String,
    val posterUrl: String? = null,
    val categoryId: String? = null,
    val plot: String? = null,
    val rating: Double? = null,
    val year: Int? = null,
    val sort: Int = 0,
    /** Xtream `last_modified` (used for "recently added series"). */
    val lastModifiedMs: Long? = null,
    /** Every category of the item, primary ([categoryId]) first (CONTRACT §4.3: Xtream `category_ids`). */
    val categoryIds: List<String> = listOfNotNull(categoryId),
)

/** An episode of a series (CONTRACT §1). */
@Serializable
public data class Episode(
    val sourceId: String,
    val id: String,
    val seriesId: String,
    val season: Int,
    val number: Int,
    val title: String,
    val containerExt: String? = null,
    val durationSec: Int? = null,
    val plot: String? = null,
    val posterUrl: String? = null,
    val url: String? = null,
)

/** One EPG programme (CONTRACT §1). [channelEpgId] is the XMLTV channel id. */
@Serializable
public data class EpgProgram(
    val sourceId: String,
    val channelEpgId: String,
    val startMs: Long,
    val endMs: Long,
    val title: String,
    val description: String? = null,
    val category: String? = null,
) {
    /** Duration in milliseconds. */
    val durationMs: Long get() = endMs - startMs

    /** True when [nowMs] is inside `[startMs, endMs)`. */
    public fun isLiveAt(nowMs: Long): Boolean = nowMs in startMs until endMs
}
