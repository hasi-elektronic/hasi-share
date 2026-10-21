package io.iptvplayer.shared.vm

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import androidx.paging.PagingData
import androidx.paging.cachedIn
import io.iptvplayer.core.model.ContentKind
import io.iptvplayer.core.model.EpgProgram
import io.iptvplayer.core.model.Source
import io.iptvplayer.core.sync.WatchHistory
import io.iptvplayer.core.xmltv.EpgSchedule
import io.iptvplayer.shared.db.CategoryEntity
import io.iptvplayer.shared.db.ChannelEntity
import io.iptvplayer.shared.db.ChannelRow
import io.iptvplayer.shared.db.EpisodeEntity
import io.iptvplayer.shared.db.LibraryEntity
import io.iptvplayer.shared.db.MovieEntity
import io.iptvplayer.shared.db.SeriesEntity
import io.iptvplayer.shared.di.AppGraph
import io.iptvplayer.shared.di.PlaybackRequest
import io.iptvplayer.shared.repo.ResolvedContent
import io.iptvplayer.shared.repo.SearchResults
import io.iptvplayer.shared.repo.SortOrder
import kotlinx.coroutines.FlowPreview
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.debounce
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.emptyFlow
import kotlinx.coroutines.flow.filterNotNull
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.flatMapLatest
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.flow.flowOf
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.mapLatest
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch

/** Common helpers for screens that depend on the selected source. */
abstract class SourceScopedViewModel(protected val graph: AppGraph) : ViewModel() {
    val source: StateFlow<Source?> = combine(graph.sources.sources, graph.settings.settings) { list, s ->
        list.firstOrNull { it.id == s.selectedSourceId } ?: list.firstOrNull()
    }.distinctUntilChanged().stateIn(viewModelScope, SharingStarted.Eagerly, null)

    val favoriteKeys: StateFlow<Set<String>> = graph.library.favoriteKeys.stateIn(viewModelScope, SharingStarted.Eagerly, emptySet())

    /** Minute ticker for now/next EPG (re-creates paging sources once per minute). */
    protected val minute: Flow<Long> = flow {
        while (true) {
            emit(graph.license.nowMs() / 60_000 * 60_000)
            delay(60_000)
        }
    }

    fun toggleFavorite(contentKey: String, title: String, kind: ContentKind, poster: String?) = viewModelScope.launch {
        graph.library.toggleFavorite(contentKey, title, kind, poster)
    }

    /** Opens the player; returns false (→ paywall) when playback is locked (CONTRACT §7.4). */
    fun canPlay(): Boolean = graph.license.state.value.canPlay

    protected fun request(r: PlaybackRequest) {
        graph.playback.value = r
    }

    fun playChannel(source: Source, c: ChannelEntity, queue: List<String> = emptyList()) =
        runCatching { request(PlaybackRequest(graph.catalog.playableChannel(source, c, graph.settingsState.value.liveFormat), queue)) }.isSuccess

    fun playMovie(source: Source, m: MovieEntity, fromStart: Boolean = false) =
        runCatching { request(PlaybackRequest(graph.catalog.playableMovie(source, m), startPositionMs = if (fromStart) 0 else null, resumeFromProgress = !fromStart)) }.isSuccess

    fun playEpisode(source: Source, s: SeriesEntity?, e: EpisodeEntity, fromStart: Boolean = false) =
        runCatching { request(PlaybackRequest(graph.catalog.playableEpisode(source, s, e), startPositionMs = if (fromStart) 0 else null, resumeFromProgress = !fromStart)) }.isSuccess

    fun playCatchup(source: Source, c: ChannelEntity, p: EpgProgram) =
        graph.catalog.playableCatchup(source, c, p)?.let { request(PlaybackRequest(it)); true } ?: false

    /** Plays a resolved library entry (home rows, favorites). Returns false when it cannot be resolved. */
    suspend fun playResolved(contentKey: String): Boolean = when (val r = graph.catalog.resolve(contentKey)) {
        is ResolvedContent.Live -> playChannel(r.source, r.channel)
        is ResolvedContent.Vod -> playMovie(r.source, r.movie)
        is ResolvedContent.Ep -> playEpisode(r.source, graph.catalog.series(r.source.id, r.episode.seriesId), r.episode)
        else -> false
    }
}

data class HomeRows(
    val continueWatching: List<LibraryEntity> = emptyList(),
    val recentChannels: List<ChannelRow> = emptyList(),
    val favoriteChannels: List<ChannelRow> = emptyList(),
    val newMovies: List<MovieEntity> = emptyList(),
    val newSeries: List<SeriesEntity> = emptyList(),
    val loaded: Boolean = false,
) {
    val isEmpty: Boolean get() = continueWatching.isEmpty() && recentChannels.isEmpty() && favoriteChannels.isEmpty() && newMovies.isEmpty() && newSeries.isEmpty()
}

/** Home (SCREENS §3.2). */
class HomeViewModel(graph: AppGraph) : SourceScopedViewModel(graph) {
    val rows: StateFlow<HomeRows> = combine(
        source.filterNotNull(),
        graph.library.continueWatching,
        graph.library.recentChannels,
        graph.library.favorites,
        minute,
    ) { src, cont, recent, favs, now ->
        val chanIds = { list: List<LibraryEntity> ->
            list.mapNotNull { io.iptvplayer.core.util.ContentKeys.parse(it.contentKey) }
                .filter { it.fingerprint == src.fingerprint && it.kind == ContentKind.LIVE }.map { it.itemId }
        }
        val recentIds = chanIds(recent)
        val favIds = chanIds(favs)
        val recentRows = graph.catalog.channelRowsByIds(src.id, recentIds, now).sortedBy { recentIds.indexOf(it.channel.id) }
        HomeRows(
            continueWatching = cont,
            recentChannels = recentRows,
            favoriteChannels = graph.catalog.channelRowsByIds(src.id, favIds, now),
            newMovies = graph.catalog.recentMovies(src.id),
            newSeries = graph.catalog.recentSeries(src.id),
            loaded = true,
        )
    }.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), HomeRows())
}

/** Live TV (SCREENS §3.3). [FAVORITES] is the pseudo category "Favorites". */
class LiveViewModel(graph: AppGraph) : SourceScopedViewModel(graph) {
    val categories: StateFlow<List<CategoryEntity>> = source.filterNotNull().flatMapLatest {
        graph.catalog.categories(it.id, ContentKind.LIVE)
    }.stateIn(viewModelScope, SharingStarted.Eagerly, emptyList())

    private val _category = MutableStateFlow<String?>(null)
    val category: StateFlow<String?> = _category

    /** TV: index of the last opened channel (focus restoration after the player). */
    var lastOpenedIndex: Int = 0

    fun selectCategory(id: String?) {
        if (_category.value != id) lastOpenedIndex = 0
        _category.value = id
    }

    val channels: Flow<PagingData<ChannelRow>> = combine(source.filterNotNull(), _category, minute) { s, c, now -> Triple(s, c, now) }
        .flatMapLatest { (s, c, now) ->
            if (c == FAVORITES) {
                graph.library.favorites.mapLatest { favs ->
                    val ids = favs.mapNotNull { io.iptvplayer.core.util.ContentKeys.parse(it.contentKey) }
                        .filter { it.fingerprint == s.fingerprint && it.kind == ContentKind.LIVE }.map { it.itemId }
                    PagingData.from(graph.catalog.channelRowsByIds(s.id, ids, now))
                }
            } else {
                graph.catalog.channels(s.id, c, now)
            }
        }.cachedIn(viewModelScope)

    /** Ids of the current list (zapping queue for the player). */
    suspend fun queue(): List<String> {
        val s = source.value ?: return emptyList()
        val c = _category.value
        return if (c == FAVORITES) favoriteKeys.value.mapNotNull { io.iptvplayer.core.util.ContentKeys.parse(it) }.filter { it.fingerprint == s.fingerprint && it.kind == ContentKind.LIVE }.map { it.itemId }
        else graph.catalog.channelList(s.id, c).map { it.id }
    }

    fun play(c: ChannelEntity, onResult: (Boolean) -> Unit) = viewModelScope.launch {
        val s = source.value ?: return@launch onResult(false)
        onResult(playChannel(s, c, queue()))
    }

    /** Preview panel (TV) / guide: programmes of one channel. */
    suspend fun programmes(c: ChannelEntity, hoursBack: Int = 2, hoursAhead: Int = 12): List<EpgProgram> {
        val s = source.value ?: return emptyList()
        val key = c.epgKey ?: return emptyList()
        val now = graph.license.nowMs()
        return graph.catalog.programmes(s.id, key, now - hoursBack * 3_600_000L, now + hoursAhead * 3_600_000L)
    }

    /** EPG grid: channels of the current category (max [limit]) with their programmes in the window. */
    suspend fun guide(fromMs: Long, toMs: Long, limit: Int = 200): List<Pair<ChannelEntity, List<EpgProgram>>> {
        val s = source.value ?: return emptyList()
        val chans = graph.catalog.channelList(s.id, _category.value.takeIf { it != FAVORITES }).take(limit)
        val map = graph.catalog.programmesFor(s.id, chans.mapNotNull { it.epgKey }.distinct(), fromMs, toMs)
        return chans.map { it to (it.epgKey?.let { k -> map[k] } ?: emptyList()) }
    }

    fun nowMs(): Long = graph.license.nowMs()

    fun progress(start: Long?, end: Long?): Float =
        if (start == null || end == null) 0f else EpgSchedule.progress(start, end, nowMs()).toFloat()

    companion object {
        const val FAVORITES = "\u0000favorites"
    }
}

/** Movies or series grid (SCREENS §3.4/3.5). */
abstract class VodViewModelBase(graph: AppGraph, val kind: ContentKind) : SourceScopedViewModel(graph) {
    val categories: StateFlow<List<CategoryEntity>> = source.filterNotNull().flatMapLatest {
        graph.catalog.categories(it.id, kind)
    }.stateIn(viewModelScope, SharingStarted.Eagerly, emptyList())

    private val _category = MutableStateFlow<String?>(null)
    val category: StateFlow<String?> = _category
    private val _sort = MutableStateFlow(SortOrder.ADDED)
    val sort: StateFlow<SortOrder> = _sort

    fun selectCategory(id: String?) {
        _category.value = id
    }

    fun setSort(s: SortOrder) {
        _sort.value = s
    }

    val movies: Flow<PagingData<MovieEntity>> = if (kind != ContentKind.MOVIE) emptyFlow() else
        combine(source.filterNotNull(), _category, _sort) { s, c, o -> Triple(s, c, o) }
            .flatMapLatest { (s, c, o) -> graph.catalog.movies(s.id, c, o) }.cachedIn(viewModelScope)

    val series: Flow<PagingData<SeriesEntity>> = if (kind != ContentKind.SERIES) emptyFlow() else
        combine(source.filterNotNull(), _category, _sort) { s, c, o -> Triple(s, c, o) }
            .flatMapLatest { (s, c, o) -> graph.catalog.series(s.id, c, o) }.cachedIn(viewModelScope)

    val isEmpty: StateFlow<Boolean?> = source.filterNotNull().mapLatest {
        val (_, m, s) = graph.catalog.counts(it.id)
        if (kind == ContentKind.MOVIE) m == 0 else s == 0
    }.stateIn(viewModelScope, SharingStarted.Eagerly, null)
}

data class DetailState(
    val loading: Boolean = true,
    val source: Source? = null,
    val movie: MovieEntity? = null,
    val series: SeriesEntity? = null,
    val episodes: List<EpisodeEntity> = emptyList(),
    val progress: Map<String, LibraryEntity> = emptyMap(),
    /** Movie resume position / series "continue" episode. */
    val resumeMs: Long? = null,
    val continueEpisode: EpisodeEntity? = null,
    val error: io.iptvplayer.core.error.SourceError? = null,
) {
    val seasons: List<Int> get() = episodes.map { it.season }.distinct().sorted()
}

/** Movie / series detail (SCREENS §3.4, §3.5). */
class DetailViewModel(graph: AppGraph) : SourceScopedViewModel(graph) {
    private val _state = MutableStateFlow(DetailState())
    val state: StateFlow<DetailState> = _state

    fun load(kind: ContentKind, id: String) = viewModelScope.launch {
        val src = source.value ?: source.filterNotNull().first()
        _state.value = DetailState(loading = true, source = src)
        if (kind == ContentKind.MOVIE) {
            val m = graph.catalog.movie(src.id, id)
            val p = m?.let { graph.library.progress(src.contentKey(ContentKind.MOVIE, it.id)) }
            val resume = p?.positionMs?.takeIf { pos -> p.durationMs != null && pos > 5_000 && !WatchHistory.isCompleted(pos, p.durationMs) }
            _state.value = DetailState(false, src, movie = m, resumeMs = resume)
        } else {
            val s = graph.catalog.series(src.id, id)
            val eps = try {
                graph.catalog.episodes(src.id, id)
            } catch (e: io.iptvplayer.core.error.SourceException) {
                _state.value = DetailState(false, src, series = s, error = e.error)
                return@launch
            } catch (e: Exception) {
                emptyList()
            }
            val seriesKey = src.contentKey(ContentKind.SERIES, id)
            val prog = graph.library.progressForSeries(seriesKey).associateBy { it.contentKey }
            val epKeys = eps.associateBy { src.contentKey(ContentKind.EPISODE, it.id) }
            val last = prog.values.maxByOrNull { it.updatedAt }
            val cont = last?.let { l ->
                val ep = epKeys[l.contentKey]
                if (ep != null && l.positionMs != null && l.durationMs != null && WatchHistory.isCompleted(l.positionMs, l.durationMs)) {
                    eps.getOrNull(eps.indexOf(ep) + 1) ?: ep
                } else {
                    ep
                }
            } ?: eps.firstOrNull()
            _state.value = DetailState(false, src, series = s, episodes = eps, progress = prog, continueEpisode = cont)
        }
    }

    fun episodeKey(e: EpisodeEntity): String? = _state.value.source?.contentKey(ContentKind.EPISODE, e.id)
}

/** Favorites (SCREENS §3.6). */
class FavoritesViewModel(graph: AppGraph) : SourceScopedViewModel(graph) {
    val favorites: StateFlow<List<LibraryEntity>> = graph.library.favorites.stateIn(viewModelScope, SharingStarted.Eagerly, emptyList())
    val lastSync = graph.sync.status

    fun remove(e: LibraryEntity) = viewModelScope.launch {
        graph.library.setFavorite(e.contentKey, e.title, ContentKind.fromWire(e.contentKind) ?: ContentKind.LIVE, e.posterUrl, false)
    }

    /** Opens a favorite: live/movie/episode → player, series → detail id. */
    suspend fun open(e: LibraryEntity): OpenTarget = when (val r = graph.catalog.resolve(e.contentKey)) {
        is ResolvedContent.Show -> OpenTarget.SeriesDetail(r.series.id)
        is ResolvedContent.Vod -> OpenTarget.MovieDetail(r.movie.id)
        null -> OpenTarget.Unavailable
        else -> if (!canPlay()) OpenTarget.Paywall else if (playResolved(e.contentKey)) OpenTarget.Player else OpenTarget.Unavailable
    }
}

sealed interface OpenTarget {
    data object Player : OpenTarget
    data object Paywall : OpenTarget
    data class MovieDetail(val id: String) : OpenTarget
    data class SeriesDetail(val id: String) : OpenTarget
    data object Unavailable : OpenTarget
}

/** Search (FTS, 250 ms debounce – SCREENS §3.3). */
@OptIn(FlowPreview::class)
class SearchViewModel(graph: AppGraph) : SourceScopedViewModel(graph) {
    val query = MutableStateFlow("")
    val results: StateFlow<SearchResults> = combine(query.debounce(250), source.filterNotNull()) { q, s -> q to s }
        .mapLatest { (q, s) -> if (q.isBlank()) SearchResults(q) else graph.catalog.search(s.id, q) }
        .stateIn(viewModelScope, SharingStarted.Eagerly, SearchResults(""))

    fun play(c: ChannelEntity): Boolean = source.value?.let { playChannel(it, c) } ?: false
}

/** Exposes a flow for previews/tests. */
internal fun <T> just(v: T): Flow<T> = flowOf(v)
