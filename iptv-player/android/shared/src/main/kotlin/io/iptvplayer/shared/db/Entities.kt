package io.iptvplayer.shared.db

import androidx.room.ColumnInfo
import androidx.room.Embedded
import androidx.room.Entity
import androidx.room.Fts4
import androidx.room.Index
import androidx.room.PrimaryKey

// Room schema (ARCHITECTURE §2/§3.1). Content tables carry a `gen` (generation) column: a refresh
// writes a NEW generation in batches and finally switches `sources.activeGen` in one transaction
// (and deletes the old generation) – readers never see a half-written list (atomic refresh).
// Every read query filters on the active generation of its source.

@Entity(tableName = "sources")
data class SourceEntity(
    @PrimaryKey val id: String,
    val name: String,
    val type: String,
    val displayHost: String,
    val fingerprint: String,
    val epgUrlOverride: Boolean = false,
    val epgShiftMinutes: Int = 0,
    val autoRefreshHours: Int = 24,
    val createdAtMs: Long,
    val lastRefreshAtMs: Long? = null,
    /** JSON of `SourceStatus`. */
    val statusJson: String? = null,
    /** JSON of `XtreamAccountInfo`. */
    val accountJson: String? = null,
    /** EPG URLs announced by the M3U header (`url-tvg`), comma separated – not secret. */
    val headerEpgUrls: String? = null,
    val activeGen: Int = 0,
    val epgGen: Int = 0,
    val lastEpgAtMs: Long? = null,
    val sort: Int = 0,
)

@Entity(
    tableName = "categories",
    primaryKeys = ["sourceId", "gen", "kind", "id"],
)
data class CategoryEntity(
    val sourceId: String,
    val gen: Int,
    val kind: String,
    val id: String,
    val name: String,
    val sort: Int,
)

@Entity(
    tableName = "channels",
    indices = [
        Index(value = ["sourceId", "gen", "id"], unique = true),
        Index(value = ["sourceId", "gen", "categoryId", "sort"]),
        Index(value = ["sourceId", "gen", "sort"]),
    ],
)
data class ChannelEntity(
    @PrimaryKey(autoGenerate = true) val rowId: Long = 0,
    val sourceId: String,
    val gen: Int,
    val id: String,
    val name: String,
    val number: Int? = null,
    val logoUrl: String? = null,
    val categoryId: String? = null,
    val epgId: String? = null,
    /** XMLTV channel id matched during the last EPG import (CONTRACT §5). */
    val epgKey: String? = null,
    val catchupType: String = "none",
    val catchupDays: Int = 0,
    val catchupSource: String? = null,
    /** M3U only (content, app-private DB excluded from backup). Xtream URLs are never stored. */
    val url: String? = null,
    val userAgent: String? = null,
    val referrer: String? = null,
    val drm: Boolean = false,
    val sort: Int = 0,
    val tvgShiftHours: Double? = null,
)

@Fts4(contentEntity = ChannelEntity::class)
@Entity(tableName = "channels_fts")
data class ChannelFts(val name: String)

@Entity(
    tableName = "movies",
    indices = [
        Index(value = ["sourceId", "gen", "id"], unique = true),
        Index(value = ["sourceId", "gen", "categoryId", "sort"]),
        Index(value = ["sourceId", "gen", "addedAtMs"]),
    ],
)
data class MovieEntity(
    @PrimaryKey(autoGenerate = true) val rowId: Long = 0,
    val sourceId: String,
    val gen: Int,
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
)

@Fts4(contentEntity = MovieEntity::class)
@Entity(tableName = "movies_fts")
data class MovieFts(val name: String)

@Entity(
    tableName = "series",
    indices = [
        Index(value = ["sourceId", "gen", "id"], unique = true),
        Index(value = ["sourceId", "gen", "categoryId", "sort"]),
    ],
)
data class SeriesEntity(
    @PrimaryKey(autoGenerate = true) val rowId: Long = 0,
    val sourceId: String,
    val gen: Int,
    val id: String,
    val name: String,
    val posterUrl: String? = null,
    val categoryId: String? = null,
    val plot: String? = null,
    val rating: Double? = null,
    val year: Int? = null,
    val sort: Int = 0,
    val lastModifiedMs: Long? = null,
)

@Fts4(contentEntity = SeriesEntity::class)
@Entity(tableName = "series_fts")
data class SeriesFts(val name: String)

@Entity(
    tableName = "episodes",
    primaryKeys = ["sourceId", "gen", "id"],
    indices = [Index(value = ["sourceId", "gen", "seriesId", "season", "number"])],
)
data class EpisodeEntity(
    val sourceId: String,
    val gen: Int,
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

@Entity(
    tableName = "epg",
    primaryKeys = ["sourceId", "gen", "channelEpgId", "startMs"],
    indices = [Index(value = ["sourceId", "gen", "channelEpgId", "endMs"])],
)
data class EpgEntity(
    val sourceId: String,
    val gen: Int,
    val channelEpgId: String,
    val startMs: Long,
    val endMs: Long,
    val title: String,
    val description: String? = null,
    val category: String? = null,
)

/**
 * Local copy of favorites and watch progress as [io.iptvplayer.core.sync.SyncItem]s (CONTRACT §8):
 * keyed by `fav:<contentKey>` / `prog:<contentKey>`, LWW on [updatedAt]; [dirty] = not pushed yet.
 */
@Entity(
    tableName = "library",
    indices = [Index(value = ["kind", "deleted", "updatedAt"]), Index(value = ["contentKey"])],
)
data class LibraryEntity(
    @PrimaryKey val key: String,
    val kind: String,
    val contentKey: String,
    val contentKind: String?,
    val title: String,
    val posterUrl: String? = null,
    val positionMs: Long? = null,
    val durationMs: Long? = null,
    val seriesKey: String? = null,
    val updatedAt: Long,
    val deleted: Boolean = false,
    val dirty: Boolean = true,
    /** Manual order of favorites (mobile edit mode). */
    val sortOrder: Int = 0,
)

/** Channel row with now/next programme (correlated sub-queries on the EPG index). */
data class ChannelRow(
    @Embedded val channel: ChannelEntity,
    @ColumnInfo(name = "nowTitle") val nowTitle: String?,
    @ColumnInfo(name = "nowStart") val nowStart: Long?,
    @ColumnInfo(name = "nowEnd") val nowEnd: Long?,
    @ColumnInfo(name = "nextTitle") val nextTitle: String?,
    @ColumnInfo(name = "nextStart") val nextStart: Long?,
)

/** Minimal channel projection for EPG matching. */
data class ChannelMatchRow(val rowId: Long, val epgId: String?, val name: String)

/** Counts of one catalog generation. */
data class GenCounts(val live: Int, val movies: Int, val series: Int)
