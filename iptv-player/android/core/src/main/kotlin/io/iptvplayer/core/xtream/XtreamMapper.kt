package io.iptvplayer.core.xtream

import io.iptvplayer.core.model.CatchupInfo
import io.iptvplayer.core.model.CatchupType
import io.iptvplayer.core.model.Category
import io.iptvplayer.core.model.Channel
import io.iptvplayer.core.model.ContentKind
import io.iptvplayer.core.model.Episode
import io.iptvplayer.core.model.Movie
import io.iptvplayer.core.model.Series
import io.iptvplayer.core.util.Base64Codec
import io.iptvplayer.core.xtream.XtreamJson.get
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import java.time.DateTimeException
import java.time.LocalDateTime

/** One entry of `get_short_epg` / `get_simple_data_table` (CONTRACT §4.3). Times in epoch ms. */
@Serializable
public data class XtreamEpgEntry(
    val startMs: Long,
    val endMs: Long,
    val title: String?,
    val description: String?,
    val hasArchive: Boolean,
)

/** Series details of `get_series_info.info` (all optional; `info` may be `[]`). */
@Serializable
public data class XtreamSeriesDetails(
    val name: String? = null,
    val posterUrl: String? = null,
    val plot: String? = null,
    val genre: String? = null,
    val cast: String? = null,
    val director: String? = null,
    val rating: Double? = null,
    val year: Int? = null,
    val backdropUrl: String? = null,
    val categoryId: String? = null,
)

/** Result of `get_series_info`. */
public data class XtreamSeriesInfo(val details: XtreamSeriesDetails, val episodes: List<Episode>)

/** Result of `get_vod_info` (details screen). */
@Serializable
public data class XtreamVodInfo(
    val name: String? = null,
    val plot: String? = null,
    val genre: String? = null,
    val cast: String? = null,
    val director: String? = null,
    val rating: Double? = null,
    val year: Int? = null,
    val durationSec: Int? = null,
    val posterUrl: String? = null,
    val backdropUrl: String? = null,
    val containerExt: String? = null,
)

/**
 * Maps lenient Xtream panel JSON to the domain model (CONTRACT §4.3 and
 * `spec/test-vectors/README.md` "Xtream mapping details"). Items without an id are skipped;
 * a malformed item never fails the whole list. `sort` = position among the kept items.
 */
public object XtreamMapper {
    private fun id(e: JsonElement?): String? = XtreamJson.trimmed(e)

    /** One category item, or null when it has no `category_id`. */
    public fun category(item: JsonElement, sourceId: String, kind: ContentKind, sort: Int): Category? {
        val id = id(item["category_id"]) ?: return null
        return Category(sourceId, id, kind, XtreamJson.string(item["category_name"]) ?: "", sort)
    }

    /** `get_*_categories` → categories of [kind] (LIVE, MOVIE or SERIES). */
    public fun categories(json: JsonElement?, sourceId: String, kind: ContentKind): List<Category> =
        mapItems(json) { item, sort -> category(item, sourceId, kind, sort) }

    /** One `get_live_streams` item, or null without `stream_id`. */
    public fun channel(item: JsonElement, sourceId: String, sort: Int): Channel? {
        val id = id(item["stream_id"]) ?: return null
        val catchup = if (XtreamJson.bool(item["tv_archive"])) {
            CatchupInfo(CatchupType.XTREAM, XtreamJson.int(item["tv_archive_duration"]) ?: 0)
        } else {
            CatchupInfo.NONE
        }
        return Channel(
            sourceId = sourceId,
            id = id,
            name = XtreamJson.string(item["name"]) ?: "",
            number = XtreamJson.int(item["num"]),
            logoUrl = XtreamJson.trimmed(item["stream_icon"]),
            categoryId = categoryIds(item).firstOrNull(),
            categoryIds = categoryIds(item),
            epgId = XtreamJson.trimmed(item["epg_channel_id"]),
            catchup = catchup,
            sort = sort,
        )
    }

    /** `get_live_streams` → channels. */
    public fun channels(json: JsonElement?, sourceId: String): List<Channel> =
        mapItems(json) { item, sort -> channel(item, sourceId, sort) }

    /** One `get_vod_streams` item, or null without `stream_id`. */
    public fun movie(item: JsonElement, sourceId: String, sort: Int): Movie? {
        val id = id(item["stream_id"]) ?: return null
        return Movie(
            sourceId = sourceId,
            id = id,
            name = XtreamJson.string(item["name"]) ?: "",
            posterUrl = XtreamJson.trimmed(item["stream_icon"]),
            categoryId = categoryIds(item).firstOrNull(),
            categoryIds = categoryIds(item),
            rating = XtreamJson.double(item["rating"]),
            year = XtreamJson.int(item["year"])?.takeIf { it > 0 },
            plot = XtreamJson.string(item["plot"]),
            containerExt = XtreamJson.trimmed(item["container_extension"]),
            addedAtMs = epochMs(item["added"]),
            sort = sort,
        )
    }

    /** `get_vod_streams` → movies. */
    public fun movies(json: JsonElement?, sourceId: String): List<Movie> =
        mapItems(json) { item, sort -> movie(item, sourceId, sort) }

    /** One `get_series` item, or null without `series_id`. */
    public fun seriesItem(item: JsonElement, sourceId: String, sort: Int): Series? {
        val id = id(item["series_id"]) ?: return null
        return Series(
            sourceId = sourceId,
            id = id,
            name = XtreamJson.string(item["name"]) ?: "",
            posterUrl = XtreamJson.trimmed(item["cover"]),
            categoryId = categoryIds(item).firstOrNull(),
            categoryIds = categoryIds(item),
            plot = XtreamJson.string(item["plot"]),
            rating = XtreamJson.double(item["rating"]),
            year = year(item),
            sort = sort,
            lastModifiedMs = epochMs(item["last_modified"]),
        )
    }

    /** `get_series` → series. */
    public fun series(json: JsonElement?, sourceId: String): List<Series> =
        mapItems(json) { item, sort -> seriesItem(item, sourceId, sort) }

    /**
     * All categories of a list item (CONTRACT §4.3): `category_id` first, then the entries of
     * `category_ids` (XUI.one / newer panels: ints or strings; `category_id` may be null, `""` or
     * only the first of them). Empty/null entries are skipped, duplicates removed, order kept.
     */
    public fun categoryIds(item: JsonElement?): List<String> {
        val out = LinkedHashSet<String>()
        id(item["category_id"])?.let(out::add)
        XtreamJson.array(item["category_ids"])?.forEach { e -> id(e)?.let(out::add) }
        return out.toList()
    }

    /** `year` field, else the first 4 digits of `releaseDate` / `release_date`. */
    public fun year(item: JsonElement?): Int? {
        XtreamJson.int(item["year"])?.takeIf { it > 0 }?.let { return it }
        for (key in arrayOf("releaseDate", "release_date")) {
            val text = XtreamJson.trimmed(item[key]) ?: continue
            if (text.length >= 4 && text.substring(0, 4).all { it in '0'..'9' }) return text.substring(0, 4).toInt()
        }
        return null
    }

    /**
     * Episodes of `get_series_info` in both shapes: `{"1":[…],"2":[…]}` or `[[…],[…]]`
     * (also a flat list of episode objects). Season = `episode.season`, fallback object key or
     * array index + 1.
     */
    public fun episodes(json: JsonElement?, sourceId: String, seriesId: String): List<Episode> {
        val groups = ArrayList<Pair<Int, List<JsonElement>>>()
        when (val eps = json["episodes"]) {
            is JsonObject -> XtreamJson.sortedEntries(eps).forEachIndexed { index, (key, value) ->
                groups += (key.trim().toIntOrNull() ?: (index + 1)) to XtreamJson.listItems(value)
            }
            is JsonArray -> eps.forEachIndexed { index, value ->
                when {
                    value is JsonArray -> groups += (index + 1) to value
                    value is JsonObject && value.containsKey("id") -> groups += 1 to listOf(value)
                }
            }
            else -> Unit
        }
        val out = ArrayList<Episode>()
        for ((fallbackSeason, items) in groups) {
            for (item in items) {
                episode(item, sourceId, seriesId, fallbackSeason)?.let(out::add)
            }
        }
        return out
    }

    /** One episode item, or null without `id`. */
    public fun episode(item: JsonElement, sourceId: String, seriesId: String, fallbackSeason: Int): Episode? {
        if (item !is JsonObject) return null
        val id = id(item["id"]) ?: return null
        val info = XtreamJson.obj(item["info"]) ?: JsonObject(emptyMap())
        val duration = XtreamJson.int(info["duration_secs"])
            ?: XtreamJson.string(info["duration"])?.let(::parseClock)
        return Episode(
            sourceId = sourceId,
            id = id,
            seriesId = seriesId,
            season = XtreamJson.int(item["season"]) ?: fallbackSeason,
            number = XtreamJson.int(item["episode_num"]) ?: 0,
            title = XtreamJson.string(item["title"]) ?: "",
            containerExt = XtreamJson.trimmed(item["container_extension"]),
            durationSec = duration,
            plot = XtreamJson.string(info["plot"]),
            posterUrl = XtreamJson.trimmed(info["movie_image"]),
        )
    }

    /** `get_series_info.info` → details. */
    public fun seriesDetails(json: JsonElement?): XtreamSeriesDetails {
        val info = json["info"]
        return XtreamSeriesDetails(
            name = XtreamJson.string(info["name"]),
            posterUrl = XtreamJson.trimmed(info["cover"]),
            plot = XtreamJson.string(info["plot"]),
            genre = XtreamJson.string(info["genre"]),
            cast = XtreamJson.string(info["cast"]),
            director = XtreamJson.string(info["director"]),
            rating = XtreamJson.double(info["rating"]),
            year = year(info),
            backdropUrl = firstString(info["backdrop_path"]),
            categoryId = id(info["category_id"]),
        )
    }

    /** `get_series_info` → details + episodes. */
    public fun seriesInfo(json: JsonElement?, sourceId: String, seriesId: String): XtreamSeriesInfo =
        XtreamSeriesInfo(seriesDetails(json), episodes(json, sourceId, seriesId))

    /** `get_vod_info` → details. */
    public fun vodInfo(json: JsonElement?): XtreamVodInfo {
        val info = json["info"]
        val movie = json["movie_data"]
        return XtreamVodInfo(
            name = XtreamJson.string(info["name"]) ?: XtreamJson.string(movie["name"]),
            plot = XtreamJson.string(info["plot"]) ?: XtreamJson.string(info["description"]),
            genre = XtreamJson.string(info["genre"]),
            cast = XtreamJson.string(info["cast"]) ?: XtreamJson.string(info["actors"]),
            director = XtreamJson.string(info["director"]),
            rating = XtreamJson.double(info["rating"]),
            year = year(info) ?: year(movie),
            durationSec = XtreamJson.int(info["duration_secs"]) ?: XtreamJson.string(info["duration"])?.let(::parseClock),
            posterUrl = XtreamJson.trimmed(info["movie_image"]) ?: XtreamJson.trimmed(info["cover_big"]),
            backdropUrl = firstString(info["backdrop_path"]),
            containerExt = XtreamJson.trimmed(movie["container_extension"]),
        )
    }

    /**
     * `get_short_epg` / `get_simple_data_table` → entries. Titles/descriptions are base64
     * (UTF-8; raw string when decoding fails; empty → null). Times prefer
     * `start_timestamp`/`stop_timestamp` (epoch s, UTC); fallback `start`/`end` strings
     * (`yyyy-MM-dd HH:mm:ss` in the server timezone). Entries without parsable times are skipped.
     */
    public fun shortEpg(json: JsonElement?, serverTimezone: String? = null): List<XtreamEpgEntry> {
        val listings = json["epg_listings"]?.let { XtreamJson.listItems(it) } ?: XtreamJson.listItems(json)
        val out = ArrayList<XtreamEpgEntry>()
        for (item in listings) {
            val start = epochSecondsToMs(item["start_timestamp"]) ?: panelTime(item["start"], serverTimezone) ?: continue
            val end = epochSecondsToMs(item["stop_timestamp"])
                ?: epochSecondsToMs(item["end_timestamp"])
                ?: panelTime(item["end"], serverTimezone)
                ?: panelTime(item["stop"], serverTimezone)
                ?: continue
            out += XtreamEpgEntry(
                startMs = start,
                endMs = end,
                title = decodeBase64Text(XtreamJson.string(item["title"])),
                description = decodeBase64Text(XtreamJson.string(item["description"])),
                hasArchive = XtreamJson.bool(item["has_archive"]),
            )
        }
        return out
    }

    /** Base64 (UTF-8) → text; the raw input when it is not base64/UTF-8. Blank → null. */
    public fun decodeBase64Text(raw: String?): String? {
        if (raw.isNullOrEmpty()) return null
        val decoded = Base64Codec.decodeUtf8OrNull(raw)?.takeIf { text ->
            text.none { it < ' ' && it != '\n' && it != '\r' && it != '\t' }
        }
        val text = (decoded ?: raw).trim()
        return text.ifEmpty { null }
    }

    /** "HH:MM:SS" / "MM:SS" → seconds. */
    public fun parseClock(text: String): Int? {
        val parts = text.split(':').map { it.trim().toIntOrNull() ?: return null }
        if (parts.isEmpty() || parts.size > 3) return null
        return parts.fold(0) { acc, v -> acc * 60 + v }
    }

    private fun firstString(e: JsonElement?): String? =
        if (e is JsonArray) e.firstNotNullOfOrNull { XtreamJson.trimmed(it) } else XtreamJson.trimmed(e)

    /** Epoch seconds (number or string, > 0) → ms. */
    internal fun epochMs(e: JsonElement?): Long? = XtreamJson.long(e)?.takeIf { it > 0 }?.let { it * 1000 }

    private fun epochSecondsToMs(e: JsonElement?): Long? = XtreamJson.long(e)?.let { it * 1000 }

    private fun panelTime(e: JsonElement?, zone: String?): Long? {
        val text = XtreamJson.trimmed(e) ?: return null
        val parts = text.split('-', ' ', ':', 'T').filter { it.isNotEmpty() }.map { it.toIntOrNull() ?: return null }
        if (parts.size < 5) return null
        return try {
            LocalDateTime.of(parts[0], parts[1], parts[2], parts[3], parts[4], parts.getOrElse(5) { 0 })
                .atZone(XtreamUrlBuilder.zoneOrUtc(zone)).toInstant().toEpochMilli()
        } catch (_: DateTimeException) {
            null
        }
    }

    private inline fun <T : Any> mapItems(json: JsonElement?, map: (JsonElement, Int) -> T?): List<T> {
        val out = ArrayList<T>()
        for (item in XtreamJson.listItems(json)) {
            if (item is JsonNull) continue
            val mapped = try {
                map(item, out.size)
            } catch (_: RuntimeException) {
                null // malformed item: skip, never fail the list (§4.3)
            }
            if (mapped != null) out += mapped
        }
        return out
    }
}
