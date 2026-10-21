package io.iptvplayer.shared.repo

import androidx.paging.Pager
import androidx.paging.PagingConfig
import androidx.paging.PagingData
import io.iptvplayer.core.error.PlaybackException
import io.iptvplayer.core.media.PlayerEngine
import io.iptvplayer.core.model.ContentKind
import io.iptvplayer.core.model.EpgProgram
import io.iptvplayer.core.model.Source
import io.iptvplayer.core.model.SourceSecrets
import io.iptvplayer.core.util.ContentKeys
import io.iptvplayer.core.xtream.LiveFormatPreference
import io.iptvplayer.core.xtream.XtreamUrlBuilder
import io.iptvplayer.shared.db.AppDatabase
import io.iptvplayer.shared.db.CategoryEntity
import io.iptvplayer.shared.db.ChannelEntity
import io.iptvplayer.shared.db.ChannelRow
import io.iptvplayer.shared.db.EpisodeEntity
import io.iptvplayer.shared.db.MovieEntity
import io.iptvplayer.shared.db.SeriesEntity
import io.iptvplayer.shared.db.toModel
import io.iptvplayer.shared.player.PlayableItem
import kotlinx.coroutines.flow.Flow

/** Sort orders of the movie / series grids (SCREENS §3.4). */
enum class SortOrder { ADDED, NAME, RATING }

/** Search result groups. */
data class SearchResults(
    val query: String,
    val channels: List<ChannelEntity> = emptyList(),
    val movies: List<MovieEntity> = emptyList(),
    val series: List<SeriesEntity> = emptyList(),
) {
    val isEmpty: Boolean get() = channels.isEmpty() && movies.isEmpty() && series.isEmpty()
}

/** A library entry resolved back to catalog content (favorites / continue watching). */
sealed interface ResolvedContent {
    val source: Source
    data class Live(override val source: Source, val channel: ChannelEntity) : ResolvedContent
    data class Vod(override val source: Source, val movie: MovieEntity) : ResolvedContent
    data class Show(override val source: Source, val series: SeriesEntity) : ResolvedContent
    data class Ep(override val source: Source, val episode: EpisodeEntity) : ResolvedContent
}

/** Read side of the catalog (paged lists, FTS search, EPG) and play-time URL building. */
class CatalogRepository(
    private val db: AppDatabase,
    private val sources: SourceRepository,
) {
    private val dao get() = db.catalog()
    private val paging = PagingConfig(pageSize = 60, prefetchDistance = 40, enablePlaceholders = false, initialLoadSize = 120)

    fun categories(sourceId: String, kind: ContentKind): Flow<List<CategoryEntity>> = dao.observeCategories(sourceId, kind.wire)

    fun channels(sourceId: String, categoryId: String?, nowMs: Long): Flow<PagingData<ChannelRow>> =
        Pager(paging) { dao.channelRows(sourceId, categoryId, nowMs) }.flow

    suspend fun channelRows(sourceId: String, categoryId: String?, nowMs: Long, limit: Int = 5000): List<ChannelRow> =
        dao.channelRowList(sourceId, categoryId, nowMs, limit)

    suspend fun channelRowsByIds(sourceId: String, ids: List<String>, nowMs: Long): List<ChannelRow> =
        if (ids.isEmpty()) emptyList() else dao.channelRowsByIds(sourceId, ids, nowMs)

    suspend fun channelList(sourceId: String, categoryId: String?): List<ChannelEntity> = dao.channelList(sourceId, categoryId)

    fun movies(sourceId: String, categoryId: String?, sort: SortOrder): Flow<PagingData<MovieEntity>> = Pager(paging) {
        when (sort) {
            SortOrder.ADDED -> dao.moviesByAdded(sourceId, categoryId)
            SortOrder.NAME -> dao.moviesByName(sourceId, categoryId)
            SortOrder.RATING -> dao.moviesByRating(sourceId, categoryId)
        }
    }.flow

    fun series(sourceId: String, categoryId: String?, sort: SortOrder): Flow<PagingData<SeriesEntity>> = Pager(paging) {
        when (sort) {
            SortOrder.ADDED -> dao.seriesByAdded(sourceId, categoryId)
            SortOrder.NAME -> dao.seriesByName(sourceId, categoryId)
            SortOrder.RATING -> dao.seriesByRating(sourceId, categoryId)
        }
    }.flow

    suspend fun recentMovies(sourceId: String, limit: Int = 20) = dao.recentMovies(sourceId, limit)
    suspend fun recentSeries(sourceId: String, limit: Int = 20) = dao.recentSeries(sourceId, limit)
    suspend fun movie(sourceId: String, id: String) = dao.movie(sourceId, id)
    suspend fun series(sourceId: String, id: String) = dao.series(sourceId, id)
    suspend fun channel(sourceId: String, id: String) = dao.channel(sourceId, id)

    suspend fun episodes(sourceId: String, seriesId: String, loadIfMissing: Boolean = true): List<EpisodeEntity> {
        val local = dao.episodes(sourceId, seriesId)
        if (local.isNotEmpty() || !loadIfMissing) return local
        sources.loadXtreamEpisodes(sourceId, seriesId)
        return dao.episodes(sourceId, seriesId)
    }

    suspend fun counts(sourceId: String): Triple<Int, Int, Int> =
        Triple(dao.channelCount(sourceId), dao.movieCount(sourceId), dao.seriesCount(sourceId))

    /** FTS4 prefix search (all tokens must match), debounced by the caller (250 ms). */
    suspend fun search(sourceId: String, query: String, limit: Int = 50): SearchResults {
        val match = ftsQuery(query) ?: return SearchResults(query)
        return SearchResults(
            query,
            dao.searchChannels(sourceId, match, limit),
            dao.searchMovies(sourceId, match, limit),
            dao.searchSeries(sourceId, match, limit),
        )
    }

    suspend fun programmes(sourceId: String, epgKey: String, fromMs: Long, toMs: Long): List<EpgProgram> =
        dao.programmes(sourceId, epgKey, fromMs, toMs).map { it.toModel() }

    suspend fun programmesFor(sourceId: String, epgKeys: List<String>, fromMs: Long, toMs: Long): Map<String, List<EpgProgram>> =
        if (epgKeys.isEmpty()) emptyMap() else dao.programmesFor(sourceId, epgKeys, fromMs, toMs).map { it.toModel() }.groupBy { it.channelEpgId }

    /** Resolves a content key (favorites, progress) to catalog content of a configured source. */
    suspend fun resolve(contentKey: String): ResolvedContent? {
        val p = ContentKeys.parse(contentKey) ?: return null
        val src = sources.byFingerprint(p.fingerprint) ?: return null
        return when (p.kind) {
            ContentKind.LIVE -> dao.channel(src.id, p.itemId)?.let { ResolvedContent.Live(src, it) }
            ContentKind.MOVIE -> dao.movie(src.id, p.itemId)?.let { ResolvedContent.Vod(src, it) }
            ContentKind.SERIES -> dao.series(src.id, p.itemId)?.let { ResolvedContent.Show(src, it) }
            ContentKind.EPISODE -> dao.episode(src.id, p.itemId)?.let { ResolvedContent.Ep(src, it) }
        }
    }

    // ------------------------------------------------------------------------- playback URLs

    /**
     * Builds a playable item. Xtream URLs contain credentials and are built here, at play time,
     * never persisted (CONTRACT §4.5).
     * @throws PlaybackException when the URL cannot be built (missing secrets).
     */
    fun playableChannel(source: Source, c: ChannelEntity, liveFormat: LiveFormatPreference): PlayableItem {
        val url = when (val s = sources.secrets(source.id)) {
            is SourceSecrets.Xtream -> XtreamUrlBuilder(s).live(
                c.id,
                XtreamUrlBuilder.liveExtension(PlayerEngine.MEDIA3, source.xtreamAccount?.allowedOutputFormats.orEmpty(), liveFormat),
            )
            else -> c.url
        } ?: throw missing()
        return PlayableItem(
            contentKey = source.contentKey(ContentKind.LIVE, c.id),
            kind = ContentKind.LIVE,
            sourceId = source.id,
            itemId = c.id,
            title = c.name,
            imageUrl = c.logoUrl,
            number = c.number,
            url = url,
            userAgent = c.userAgent ?: (sources.secrets(source.id) as? SourceSecrets.M3u)?.userAgent,
            referrer = c.referrer,
            drm = c.drm,
            epgKey = c.epgKey,
            categoryId = c.categoryId,
        )
    }

    /** Catch-up (Xtream timeshift) URL for a past programme (CONTRACT §4.5). */
    fun playableCatchup(source: Source, c: ChannelEntity, program: EpgProgram): PlayableItem? {
        val s = sources.secrets(source.id) as? SourceSecrets.Xtream ?: return null
        val url = XtreamUrlBuilder(s).timeshift(c.id, program.startMs, program.endMs, source.xtreamAccount?.serverTimezone, "ts")
        return playableChannel(source, c, LiveFormatPreference.AUTO).copy(url = url, title = "${c.name} – ${program.title}", isCatchup = true)
    }

    fun playableMovie(source: Source, m: MovieEntity): PlayableItem {
        val url = when (val s = sources.secrets(source.id)) {
            is SourceSecrets.Xtream -> XtreamUrlBuilder(s).movie(m.id, m.containerExt ?: "mp4")
            else -> m.url
        } ?: throw missing()
        return PlayableItem(
            contentKey = source.contentKey(ContentKind.MOVIE, m.id), kind = ContentKind.MOVIE, sourceId = source.id,
            itemId = m.id, title = m.name, imageUrl = m.posterUrl, url = url,
            userAgent = (sources.secrets(source.id) as? SourceSecrets.M3u)?.userAgent,
        )
    }

    fun playableEpisode(source: Source, series: SeriesEntity?, e: EpisodeEntity): PlayableItem {
        val url = when (val s = sources.secrets(source.id)) {
            is SourceSecrets.Xtream -> XtreamUrlBuilder(s).episode(e.id, e.containerExt ?: "mp4")
            else -> e.url
        } ?: throw missing()
        return PlayableItem(
            contentKey = source.contentKey(ContentKind.EPISODE, e.id), kind = ContentKind.EPISODE, sourceId = source.id,
            itemId = e.id, title = series?.let { "${it.name} · S%02dE%02d".format(e.season, e.number) } ?: e.title,
            imageUrl = e.posterUrl ?: series?.posterUrl, url = url,
            userAgent = (sources.secrets(source.id) as? SourceSecrets.M3u)?.userAgent,
            seriesKey = series?.let { source.contentKey(ContentKind.SERIES, it.id) },
            durationMs = e.durationSec?.let { it * 1000L },
        )
    }

    private fun missing() = PlaybackException(io.iptvplayer.core.error.PlaybackError.StreamOffline(404))

    companion object {
        /** `tok1* tok2*` – FTS4 prefix query (tokens are letters/digits only); null for blank input. */
        fun ftsQuery(query: String): String? {
            val tokens = query.lowercase().split(Regex("[^\\p{L}\\p{N}]+")).filter { it.isNotEmpty() }
            if (tokens.isEmpty()) return null
            return tokens.joinToString(" ") { "$it*" }
        }
    }
}
