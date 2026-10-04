package io.iptvplayer.core.sync

import io.iptvplayer.core.CoreJson
import io.iptvplayer.core.model.ContentKind
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.JsonElement

/** Kind of a synced item (CONTRACT §8). */
@Serializable
public enum class SyncKind(public val wire: String, public val keyPrefix: String) {
    @SerialName("favorite")
    FAVORITE("favorite", "fav:"),

    @SerialName("progress")
    PROGRESS("progress", "prog:"),
}

/**
 * Payload of a sync item (CONTRACT §8). Favorites use title/contentKind/posterUrl; progress
 * items add positionMs/durationMs/seriesKey (live channels: positionMs = 0).
 * [contentKind] is nullable only to tolerate foreign/old data from the server.
 */
@Serializable
public data class SyncItemData(
    val title: String = "",
    val contentKind: ContentKind? = null,
    val posterUrl: String? = null,
    val positionMs: Long? = null,
    val durationMs: Long? = null,
    /** Content key of the series for episodes ("continue S02E05"). */
    val seriesKey: String? = null,
) {
    /** Watched fraction 0…1, null without a positive duration. */
    val fraction: Double?
        get() {
            val p = positionMs ?: return null
            val d = durationMs ?: return null
            if (d <= 0) return null
            return (p.toDouble() / d).coerceIn(0.0, 1.0)
        }
}

/** A favorite or progress record, synchronized last-writer-wins (CONTRACT §8). */
@Serializable
public data class SyncItem(
    /** `"fav:" + contentKey` or `"prog:" + contentKey`. */
    val key: String,
    val kind: SyncKind,
    val data: SyncItemData = SyncItemData(),
    /** Client epoch ms of the last change. */
    val updatedAt: Long,
    val deleted: Boolean = false,
    /** Server sequence number (only on items received from the server). */
    val seq: Long? = null,
) {
    /** The content key embedded in [key]. */
    val contentKey: String get() = key.removePrefix(kind.keyPrefix)

    /** True when [key] matches [kind] and has a content key. */
    val isWellFormed: Boolean get() = key.startsWith(kind.keyPrefix) && key.length > kind.keyPrefix.length

    /** JSON for upload (without `seq`). */
    public fun toWireJson(): JsonElement = CoreJson.encodeToJsonElement(serializer(), copy(seq = null))

    public companion object {
        public fun favoriteKey(contentKey: String): String = SyncKind.FAVORITE.keyPrefix + contentKey

        public fun progressKey(contentKey: String): String = SyncKind.PROGRESS.keyPrefix + contentKey

        /** New/updated favorite (or a tombstone with [deleted]). */
        public fun favorite(
            contentKey: String,
            title: String,
            contentKind: ContentKind,
            posterUrl: String?,
            updatedAt: Long,
            deleted: Boolean = false,
        ): SyncItem = SyncItem(
            key = favoriteKey(contentKey),
            kind = SyncKind.FAVORITE,
            data = SyncItemData(title = title, contentKind = contentKind, posterUrl = posterUrl),
            updatedAt = updatedAt,
            deleted = deleted,
        )

        /** New/updated progress record (live channels always store positionMs = 0). */
        public fun progress(
            contentKey: String,
            title: String,
            contentKind: ContentKind,
            positionMs: Long,
            durationMs: Long,
            updatedAt: Long,
            posterUrl: String? = null,
            seriesKey: String? = null,
        ): SyncItem = SyncItem(
            key = progressKey(contentKey),
            kind = SyncKind.PROGRESS,
            data = SyncItemData(
                title = title,
                contentKind = contentKind,
                posterUrl = posterUrl,
                positionMs = if (contentKind == ContentKind.LIVE) 0 else positionMs,
                durationMs = durationMs,
                seriesKey = seriesKey,
            ),
            updatedAt = updatedAt,
        )
    }
}

/**
 * Last-writer-wins merge (CONTRACT §8): an incoming item replaces the stored one only if
 * `incoming.updatedAt > stored.updatedAt` (ties keep the stored item) – same rule as the server.
 */
public object SyncMerge {
    /** True when [incoming] must replace [stored]. */
    public fun shouldApply(incoming: SyncItem, stored: SyncItem?): Boolean =
        stored == null || incoming.updatedAt > stored.updatedAt

    /** Result of [merge]: the merged map and the items that were applied (persist / refresh UI). */
    public data class Result(val merged: Map<String, SyncItem>, val applied: List<SyncItem>)

    /** Merges [incoming] (in order) into [local] keyed by [SyncItem.key]. */
    public fun merge(local: Map<String, SyncItem>, incoming: List<SyncItem>): Result {
        val merged = LinkedHashMap(local)
        val applied = ArrayList<SyncItem>()
        for (item in incoming) {
            if (shouldApply(item, merged[item.key])) {
                merged[item.key] = item
                applied += item
            }
        }
        return Result(merged, applied)
    }

    /** Local items changed after [lastPushMs] (to upload), oldest first. */
    public fun pending(items: Collection<SyncItem>, lastPushMs: Long): List<SyncItem> =
        items.filter { it.updatedAt > lastPushMs }.sortedBy { it.updatedAt }

    /** Splits [items] into upload chunks of ≤ [size] (server limit 500 per request). */
    public fun chunks(items: List<SyncItem>, size: Int = MAX_ITEMS_PER_REQUEST): List<List<SyncItem>> = items.chunked(size)

    /** Server limit per `POST /v1/sync` and per page. */
    public const val MAX_ITEMS_PER_REQUEST: Int = 500
}

/** Home-screen selections over progress items (CONTRACT §8). */
public object WatchHistory {
    public const val COMPLETED_FRACTION: Double = 0.95
    public const val STARTED_FRACTION: Double = 0.05
    public const val RECENT_LIMIT: Int = 50

    /** ≥ 95 % watched. */
    public fun isCompleted(positionMs: Long, durationMs: Long): Boolean =
        durationMs > 0 && positionMs.toDouble() / durationMs >= COMPLETED_FRACTION

    /** "Continue watching": progress items with 5 % < position/duration < 95 %, newest first. */
    public fun continueWatching(items: Collection<SyncItem>, limit: Int? = null): List<SyncItem> {
        val list = items.filter { item ->
            val f = item.data.fraction
            item.kind == SyncKind.PROGRESS && !item.deleted && f != null && f > STARTED_FRACTION && f < COMPLETED_FRACTION
        }.sortedByDescending { it.updatedAt }
        return if (limit != null) list.take(limit) else list
    }

    /** "Recently watched": most recent progress items of any kind (or only [kind]), max [limit]. */
    public fun recentlyWatched(items: Collection<SyncItem>, kind: ContentKind? = null, limit: Int = RECENT_LIMIT): List<SyncItem> =
        items.filter { it.kind == SyncKind.PROGRESS && !it.deleted && (kind == null || it.data.contentKind == kind) }
            .sortedByDescending { it.updatedAt }
            .take(limit)
}
