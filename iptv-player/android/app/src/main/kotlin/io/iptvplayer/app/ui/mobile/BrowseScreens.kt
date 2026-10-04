package io.iptvplayer.app.ui.mobile

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.ArrowDropDown
import androidx.compose.material.icons.filled.CalendarViewDay
import androidx.compose.material.icons.filled.Favorite
import androidx.compose.material.icons.filled.FavoriteBorder
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material.icons.automirrored.filled.Sort
import androidx.compose.material3.AssistChip
import androidx.compose.material3.Button
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilterChip
import androidx.compose.material3.FilterChipDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Tab
import androidx.compose.material3.PrimaryTabRow
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.navigation.NavHostController
import androidx.paging.compose.collectAsLazyPagingItems
import androidx.paging.compose.itemKey
import io.iptvplayer.app.ui.common.ErrorCard
import io.iptvplayer.app.ui.common.RemoteImage
import io.iptvplayer.app.ui.common.formatDuration
import io.iptvplayer.app.ui.common.formatTime
import io.iptvplayer.app.ui.common.sourceErrorText
import io.iptvplayer.app.ui.common.trialChip
import io.iptvplayer.app.ui.theme.Tokens
import io.iptvplayer.core.model.ContentKind
import io.iptvplayer.core.model.EpgProgram
import io.iptvplayer.core.sync.WatchHistory
import io.iptvplayer.shared.R
import io.iptvplayer.shared.db.CategoryEntity
import io.iptvplayer.shared.db.ChannelEntity
import io.iptvplayer.shared.db.ChannelRow
import io.iptvplayer.shared.db.LibraryEntity
import io.iptvplayer.shared.repo.SortOrder
import io.iptvplayer.shared.vm.DetailViewModel
import io.iptvplayer.shared.vm.FavoritesViewModel
import io.iptvplayer.shared.vm.HomeViewModel
import io.iptvplayer.shared.vm.LiveViewModel
import io.iptvplayer.shared.vm.MainViewModel
import io.iptvplayer.shared.vm.MoviesViewModel
import io.iptvplayer.shared.vm.OpenTarget
import io.iptvplayer.shared.vm.SearchViewModel
import io.iptvplayer.shared.vm.SeriesViewModel
import io.iptvplayer.shared.vm.SourceScopedViewModel
import io.iptvplayer.shared.vm.ViewModelFactory
import io.iptvplayer.shared.vm.VodViewModelBase
import kotlinx.coroutines.launch

/** Top bar of the tab screens: title, source picker, trial chip, search, settings (SCREENS §2, §3.2). */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun MainTopBar(title: String, main: MainViewModel, nav: NavHostController, extra: @Composable () -> Unit = {}) {
    val sources by main.sources.collectAsState()
    val selected by main.selectedSource.collectAsState()
    val lic by main.license.collectAsState()
    var picker by remember { mutableStateOf(false) }
    TopAppBar(
        title = {
            Column {
                Text(title, fontWeight = FontWeight.Bold)
                if ((sources?.size ?: 0) > 1) {
                    Row(Modifier.clickable { picker = true }, verticalAlignment = Alignment.CenterVertically) {
                        Text(selected?.name.orEmpty(), fontSize = 13.sp, color = Tokens.TextSecondary)
                        Icon(Icons.Filled.ArrowDropDown, stringResource(R.string.source_picker), tint = Tokens.TextSecondary)
                    }
                    DropdownMenu(picker, onDismissRequest = { picker = false }) {
                        sources.orEmpty().forEach { s ->
                            DropdownMenuItem(text = { Text(s.name) }, onClick = { main.selectSource(s.id); picker = false })
                        }
                    }
                }
            }
        },
        actions = {
            trialChip(lic)?.let { AssistChip(onClick = { nav.navigate(Routes.PAYWALL) }, label = { Text(it, fontSize = 12.sp) }) }
            extra()
            IconButton(onClick = { nav.navigate(Routes.SEARCH) }) { Icon(Icons.Filled.Search, stringResource(R.string.action_search)) }
            IconButton(onClick = { nav.navigate(Routes.SETTINGS) }) { Icon(Icons.Filled.Settings, stringResource(R.string.action_settings)) }
        },
        colors = TopAppBarDefaults.topAppBarColors(containerColor = Tokens.Bg),
            windowInsets = androidx.compose.foundation.layout.WindowInsets(0),
    )
}

/** Opens the player or the paywall when locked (CONTRACT §7.4). */
fun NavHostController.openPlayer(vm: SourceScopedViewModel, ok: Boolean) {
    if (!vm.canPlay()) navigate(Routes.PAYWALL) else if (ok) navigate(Routes.PLAYER)
}

// ------------------------------------------------------------------------------------------ Home

@Composable
fun HomeScreen(factory: ViewModelFactory, main: MainViewModel, nav: NavHostController) {
    val vm: HomeViewModel = viewModel(factory = factory)
    val rows by vm.rows.collectAsState()
    val source by vm.source.collectAsState()
    val scope = rememberCoroutineScope()
    Column(Modifier.fillMaxSize()) {
        MainTopBar(stringResource(R.string.nav_home), main, nav)
        LazyColumn(contentPadding = PaddingValues(bottom = 24.dp)) {
            if (rows.loaded && rows.isEmpty) {
                item { Text(stringResource(R.string.home_empty), color = Tokens.TextSecondary, modifier = Modifier.padding(24.dp)) }
            }
            if (rows.continueWatching.isNotEmpty()) item {
                Shelf(stringResource(R.string.home_continue)) {
                    items(rows.continueWatching, key = { it.key }) { e ->
                        ContinueCard(e) {
                            scope.launch { if (!vm.canPlay()) nav.navigate(Routes.PAYWALL) else if (vm.playResolved(e.contentKey)) nav.navigate(Routes.PLAYER) }
                        }
                    }
                }
            }
            if (rows.recentChannels.isNotEmpty()) item {
                Shelf(stringResource(R.string.home_recent_channels)) {
                    items(rows.recentChannels, key = { "r" + it.channel.id }) { r -> ChannelCard(r) { source?.let { nav.openPlayer(vm, vm.playChannel(it, r.channel)) } } }
                }
            }
            if (rows.favoriteChannels.isNotEmpty()) item {
                Shelf(stringResource(R.string.home_favorite_channels)) {
                    items(rows.favoriteChannels, key = { "f" + it.channel.id }) { r -> ChannelCard(r) { source?.let { nav.openPlayer(vm, vm.playChannel(it, r.channel, rows.favoriteChannels.map { c -> c.channel.id })) } } }
                }
            }
            if (rows.newMovies.isNotEmpty()) item {
                Shelf(stringResource(R.string.home_new_movies)) {
                    items(rows.newMovies, key = { it.id }) { m -> PosterCard(m.name, m.posterUrl, Modifier.width(120.dp)) { nav.navigate(Routes.movie(m.id)) } }
                }
            }
            if (rows.newSeries.isNotEmpty()) item {
                Shelf(stringResource(R.string.home_new_series)) {
                    items(rows.newSeries, key = { it.id }) { s -> PosterCard(s.name, s.posterUrl, Modifier.width(120.dp)) { nav.navigate(Routes.show(s.id)) } }
                }
            }
        }
    }
}

@Composable
fun Shelf(title: String, content: androidx.compose.foundation.lazy.LazyListScope.() -> Unit) {
    Column(Modifier.padding(top = 16.dp)) {
        Text(title, fontSize = 18.sp, fontWeight = FontWeight.SemiBold, color = Tokens.TextPrimary, modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp))
        LazyRow(contentPadding = PaddingValues(horizontal = 16.dp), horizontalArrangement = Arrangement.spacedBy(12.dp), content = content)
    }
}

@Composable
fun ContinueCard(e: LibraryEntity, onClick: () -> Unit) {
    Column(Modifier.width(200.dp).clip(RoundedCornerShape(Tokens.CardRadius)).background(Tokens.Surface).clickable(onClick = onClick)) {
        RemoteImage(e.posterUrl, e.title, Modifier.fillMaxWidth().aspectRatio(16f / 9f))
        LinearProgressIndicator(
            progress = { ((e.positionMs ?: 0).toFloat() / (e.durationMs ?: 1).coerceAtLeast(1)).coerceIn(0f, 1f) },
            modifier = Modifier.fillMaxWidth().height(3.dp),
            color = Tokens.Primary,
            trackColor = Tokens.SurfaceElevated,
        )
        Text(e.title, maxLines = 1, overflow = TextOverflow.Ellipsis, color = Tokens.TextPrimary, modifier = Modifier.padding(8.dp))
    }
}

@Composable
fun ChannelCard(r: ChannelRow, onClick: () -> Unit) {
    Column(Modifier.width(160.dp).clip(RoundedCornerShape(Tokens.CardRadius)).background(Tokens.Surface).clickable(onClick = onClick).padding(8.dp)) {
        RemoteImage(r.channel.logoUrl, r.channel.name, Modifier.fillMaxWidth().aspectRatio(16f / 9f).clip(RoundedCornerShape(8.dp)), fit = true)
        Text(r.channel.name, maxLines = 1, overflow = TextOverflow.Ellipsis, color = Tokens.TextPrimary, modifier = Modifier.padding(top = 6.dp))
        Text(r.nowTitle ?: "", maxLines = 1, overflow = TextOverflow.Ellipsis, color = Tokens.TextSecondary, fontSize = 13.sp)
    }
}

@Composable
fun PosterCard(title: String, poster: String?, modifier: Modifier = Modifier, onClick: () -> Unit) {
    Column(modifier.clickable(onClick = onClick)) {
        RemoteImage(poster, title, Modifier.fillMaxWidth().aspectRatio(2f / 3f).clip(RoundedCornerShape(Tokens.PosterRadius)))
        Text(title, maxLines = 2, overflow = TextOverflow.Ellipsis, color = Tokens.TextPrimary, fontSize = 14.sp, modifier = Modifier.padding(top = 4.dp))
    }
}

// ------------------------------------------------------------------------------------------ Live TV

@OptIn(ExperimentalFoundationApi::class)
@Composable
fun LiveScreen(factory: ViewModelFactory, main: MainViewModel, nav: NavHostController) {
    val vm: LiveViewModel = viewModel(factory = factory)
    val cats by vm.categories.collectAsState()
    val cat by vm.category.collectAsState()
    val favs by vm.favoriteKeys.collectAsState()
    val source by vm.source.collectAsState()
    val items = vm.channels.collectAsLazyPagingItems()
    val ctx = LocalContext.current
    val res = androidx.compose.ui.platform.LocalResources.current
    Column(Modifier.fillMaxSize()) {
        MainTopBar(stringResource(R.string.nav_live), main, nav) {
            IconButton(onClick = { nav.navigate(Routes.GUIDE) }) { Icon(Icons.Filled.CalendarViewDay, stringResource(R.string.action_guide)) }
        }
        CategoryChips(cats, cat, withFavorites = true, onSelect = vm::selectCategory)
        if (items.itemCount == 0 && items.loadState.refresh !is androidx.paging.LoadState.Loading) {
            Text(stringResource(R.string.live_empty), color = Tokens.TextSecondary, modifier = Modifier.padding(24.dp))
        }
        LazyColumn(Modifier.fillMaxSize()) {
            items(items.itemCount, key = items.itemKey { it.channel.rowId }) { i ->
                val r = items[i] ?: return@items
                val key = source?.contentKey(ContentKind.LIVE, r.channel.id)
                val isFav = key != null && key in favs
                Row(
                    Modifier.fillMaxWidth()
                        .combinedClickable(
                            onClick = { vm.play(r.channel) { ok -> nav.openPlayer(vm, ok) } },
                            onLongClick = { key?.let { vm.toggleFavorite(it, r.channel.name, ContentKind.LIVE, r.channel.logoUrl) } },
                        )
                        .padding(horizontal = 16.dp, vertical = 10.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Text(r.channel.number?.toString() ?: "", color = Tokens.TextSecondary, modifier = Modifier.width(36.dp), fontSize = 14.sp)
                    RemoteImage(r.channel.logoUrl, null, Modifier.size(64.dp, 36.dp).clip(RoundedCornerShape(6.dp)), fit = true)
                    Spacer(Modifier.width(12.dp))
                    Column(Modifier.weight(1f)) {
                        Text(r.channel.name, color = Tokens.TextPrimary, maxLines = 1, overflow = TextOverflow.Ellipsis, fontWeight = FontWeight.Medium)
                        Text(r.nowTitle ?: stringResource(R.string.epg_no_info), color = Tokens.TextSecondary, fontSize = 13.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
                        if (r.nowStart != null && r.nowEnd != null) {
                            LinearProgressIndicator(
                                progress = { vm.progress(r.nowStart, r.nowEnd) },
                                modifier = Modifier.fillMaxWidth().padding(top = 4.dp).height(2.dp),
                                color = Tokens.Primary,
                                trackColor = Tokens.SurfaceElevated,
                            )
                        }
                    }
                    Column(horizontalAlignment = Alignment.End, modifier = Modifier.padding(start = 8.dp)) {
                        if (isFav) Icon(Icons.Filled.Favorite, stringResource(R.string.action_remove_favorite), tint = Tokens.Live, modifier = Modifier.size(16.dp))
                        r.nextStart?.let { Text(ctx.formatTime(it), color = Tokens.TextSecondary, fontSize = 12.sp) }
                    }
                }
            }
        }
    }
}

@Composable
fun CategoryChips(cats: List<CategoryEntity>, selected: String?, withFavorites: Boolean, onSelect: (String?) -> Unit) {
    Row(Modifier.horizontalScroll(rememberScrollState()).padding(horizontal = 12.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        val colors = FilterChipDefaults.filterChipColors(selectedContainerColor = Tokens.Primary, selectedLabelColor = Tokens.TextPrimary)
        FilterChip(selected == null, onClick = { onSelect(null) }, label = { Text(stringResource(R.string.all)) }, colors = colors)
        if (withFavorites) FilterChip(selected == LiveViewModel.FAVORITES, onClick = { onSelect(LiveViewModel.FAVORITES) }, label = { Text(stringResource(R.string.nav_favorites)) }, colors = colors)
        cats.forEach { c -> FilterChip(selected == c.id, onClick = { onSelect(c.id) }, label = { Text(c.name) }, colors = colors) }
    }
}

/** EPG grid: horizontal time axis, 30 min = 120 dp, red "now" line (SCREENS §3.3). */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun GuideScreen(factory: ViewModelFactory, nav: NavHostController) {
    val vm: LiveViewModel = viewModel(factory = factory)
    val source by vm.source.collectAsState()
    val ctx = LocalContext.current
    val res = androidx.compose.ui.platform.LocalResources.current
    val now = remember { vm.nowMs() }
    val from = now - 30 * 60_000L - now % (30 * 60_000L)
    val to = from + 12 * 3_600_000L
    val rows by produceState(initialValue = emptyList<Pair<ChannelEntity, List<EpgProgram>>>(), source) {
        if (source != null) value = vm.guide(from, to)
    }
    val dpPerMs = 120f / (30 * 60_000f)
    val hScroll = rememberScrollState()
    Column(Modifier.fillMaxSize()) {
        TopAppBar(
            title = { Text(stringResource(R.string.action_guide)) },
            navigationIcon = { IconButton(onClick = { nav.popBackStack() }) { Icon(Icons.AutoMirrored.Filled.ArrowBack, stringResource(R.string.action_back)) } },
            colors = TopAppBarDefaults.topAppBarColors(containerColor = Tokens.Bg),
            windowInsets = androidx.compose.foundation.layout.WindowInsets(0),
        )
        Row {
            Spacer(Modifier.width(120.dp))
            Row(Modifier.horizontalScroll(hScroll)) {
                var t = from
                while (t < to) {
                    Text(ctx.formatTime(t), color = Tokens.TextSecondary, fontSize = 12.sp, modifier = Modifier.width(120.dp).padding(start = 4.dp))
                    t += 30 * 60_000L
                }
            }
        }
        LazyColumn(Modifier.fillMaxSize()) {
            items(rows, key = { it.first.rowId }) { (c, progs) ->
                Row(Modifier.height(56.dp)) {
                    Box(Modifier.width(120.dp).fillMaxSize().background(Tokens.Surface).padding(6.dp), contentAlignment = Alignment.CenterStart) {
                        Text(c.name, maxLines = 2, fontSize = 13.sp, color = Tokens.TextPrimary, overflow = TextOverflow.Ellipsis)
                    }
                    Box(Modifier.horizontalScroll(hScroll).width(((to - from) * dpPerMs).dp).fillMaxSize()) {
                        progs.forEach { p ->
                            val start = maxOf(p.startMs, from)
                            val end = minOf(p.endMs, to)
                            if (end > start) {
                                val live = p.isLiveAt(now)
                                Box(
                                    Modifier.padding(start = ((start - from) * dpPerMs).dp).width(((end - start) * dpPerMs).dp).fillMaxSize().padding(1.dp)
                                        .clip(RoundedCornerShape(4.dp)).background(if (live) Tokens.SurfaceElevated else Tokens.Surface)
                                        .clickable(enabled = live) { source?.let { nav.openPlayer(vm, vm.playChannel(it, c)) } }
                                        .padding(6.dp),
                                ) {
                                    Text(p.title, maxLines = 2, fontSize = 12.sp, color = Tokens.TextPrimary, overflow = TextOverflow.Ellipsis)
                                }
                            }
                        }
                        Box(Modifier.padding(start = ((now - from) * dpPerMs).dp).width(2.dp).fillMaxSize().background(Tokens.Live))
                    }
                }
            }
        }
    }
}

// ------------------------------------------------------------------------------------------ Movies / Series

@Composable
fun VodScreen(factory: ViewModelFactory, main: MainViewModel, nav: NavHostController, kind: ContentKind) {
    val vm: VodViewModelBase = if (kind == ContentKind.MOVIE) viewModel<MoviesViewModel>(factory = factory) else viewModel<SeriesViewModel>(factory = factory)
    val cats by vm.categories.collectAsState()
    val cat by vm.category.collectAsState()
    val empty by vm.isEmpty.collectAsState()
    var sortMenu by remember { mutableStateOf(false) }
    val movies = vm.movies.collectAsLazyPagingItems()
    val series = vm.series.collectAsLazyPagingItems()
    val width = LocalConfiguration.current.screenWidthDp
    val columns = (width / 110).coerceIn(3, 10)
    Column(Modifier.fillMaxSize()) {
        MainTopBar(stringResource(if (kind == ContentKind.MOVIE) R.string.nav_movies else R.string.nav_series), main, nav) {
            Box {
                IconButton(onClick = { sortMenu = true }) { Icon(Icons.AutoMirrored.Filled.Sort, stringResource(R.string.action_sort)) }
                DropdownMenu(sortMenu, onDismissRequest = { sortMenu = false }) {
                    listOf(SortOrder.ADDED to R.string.sort_added, SortOrder.NAME to R.string.sort_az, SortOrder.RATING to R.string.sort_rating).forEach { (o, l) ->
                        DropdownMenuItem(text = { Text(stringResource(l)) }, onClick = { vm.setSort(o); sortMenu = false })
                    }
                }
            }
        }
        CategoryChips(cats, cat, withFavorites = false, onSelect = vm::selectCategory)
        if (empty == true) {
            Text(stringResource(if (kind == ContentKind.MOVIE) R.string.movies_empty else R.string.series_empty), color = Tokens.TextSecondary, modifier = Modifier.padding(24.dp))
        }
        LazyVerticalGrid(
            columns = GridCells.Fixed(columns),
            contentPadding = PaddingValues(12.dp),
            horizontalArrangement = Arrangement.spacedBy(10.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            if (kind == ContentKind.MOVIE) {
                items(movies.itemCount, key = movies.itemKey { it.rowId }) { i ->
                    movies[i]?.let { m -> PosterCard(m.name, m.posterUrl) { nav.navigate(Routes.movie(m.id)) } }
                }
            } else {
                items(series.itemCount, key = series.itemKey { it.rowId }) { i ->
                    series[i]?.let { s -> PosterCard(s.name, s.posterUrl) { nav.navigate(Routes.show(s.id)) } }
                }
            }
        }
    }
}

/** Movie / series detail with resume + episodes (SCREENS §3.4, §3.5). */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun DetailScreen(factory: ViewModelFactory, nav: NavHostController, kind: ContentKind, id: String) {
    val vm: DetailViewModel = viewModel(factory = factory)
    val st by vm.state.collectAsState()
    val favs by vm.favoriteKeys.collectAsState()
    val ctx = LocalContext.current
    val res = androidx.compose.ui.platform.LocalResources.current
    LaunchedEffect(id) { vm.load(kind, id) }
    var season by remember { mutableIntStateOf(-1) }
    val src = st.source
    Column(Modifier.fillMaxSize()) {
        TopAppBar(
            title = { Text(st.movie?.name ?: st.series?.name ?: "", maxLines = 1, overflow = TextOverflow.Ellipsis) },
            navigationIcon = { IconButton(onClick = { nav.popBackStack() }) { Icon(Icons.AutoMirrored.Filled.ArrowBack, stringResource(R.string.action_back)) } },
            colors = TopAppBarDefaults.topAppBarColors(containerColor = Tokens.Bg),
            windowInsets = androidx.compose.foundation.layout.WindowInsets(0),
        )
        LazyColumn(Modifier.fillMaxSize(), contentPadding = PaddingValues(16.dp)) {
            item {
                val poster = st.movie?.posterUrl ?: st.series?.posterUrl
                val plot = st.movie?.plot ?: st.series?.plot
                val year = st.movie?.year ?: st.series?.year
                val rating = st.movie?.rating ?: st.series?.rating
                Row {
                    RemoteImage(poster, null, Modifier.width(120.dp).aspectRatio(2f / 3f).clip(RoundedCornerShape(Tokens.PosterRadius)))
                    Spacer(Modifier.width(16.dp))
                    Column {
                        Text(listOfNotNull(year?.toString(), rating?.let { "★ %.1f".format(it) }).joinToString(" · "), color = Tokens.TextSecondary)
                        Spacer(Modifier.height(8.dp))
                        if (src != null && st.movie != null) {
                            val m = st.movie!!
                            Button(onClick = { nav.openPlayer(vm, vm.playMovie(src, m)) }) {
                                Text(st.resumeMs?.let { stringResource(R.string.action_resume_at, formatDuration(it)) } ?: stringResource(R.string.action_play))
                            }
                            if (st.resumeMs != null) OutlinedButton(onClick = { nav.openPlayer(vm, vm.playMovie(src, m, fromStart = true)) }) { Text(stringResource(R.string.action_play_from_start)) }
                        }
                        if (src != null && st.continueEpisode != null) {
                            val e = st.continueEpisode!!
                            Button(onClick = { nav.openPlayer(vm, vm.playEpisode(src, st.series, e)) }) {
                                Text(stringResource(R.string.continue_episode, "S%02dE%02d".format(e.season, e.number)))
                            }
                        }
                        val key = src?.let { s -> st.movie?.let { s.contentKey(ContentKind.MOVIE, it.id) } ?: st.series?.let { s.contentKey(ContentKind.SERIES, it.id) } }
                        if (key != null) {
                            val fav = key in favs
                            TextButton(onClick = { vm.toggleFavorite(key, st.movie?.name ?: st.series?.name.orEmpty(), kind, poster) }) {
                                Icon(if (fav) Icons.Filled.Favorite else Icons.Filled.FavoriteBorder, null, tint = if (fav) Tokens.Live else Tokens.TextPrimary)
                                Spacer(Modifier.width(6.dp))
                                Text(stringResource(if (fav) R.string.action_remove_favorite else R.string.action_add_favorite))
                            }
                        }
                    }
                }
                plot?.let { Text(it, color = Tokens.TextSecondary, modifier = Modifier.padding(top = 12.dp)) }
                st.error?.let { e -> ctx.sourceErrorText(e)?.let { ErrorCard(it, onAction = { vm.load(kind, id) }, modifier = Modifier.padding(top = 12.dp)) } }
            }
            if (st.seasons.isNotEmpty()) {
                item {
                    val sel = if (season in st.seasons) season else st.continueEpisode?.season ?: st.seasons.first()
                    if (season != sel) season = sel
                    Row(Modifier.horizontalScroll(rememberScrollState()).padding(vertical = 12.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        st.seasons.forEach { s ->
                            FilterChip(s == sel, onClick = { season = s }, label = { Text(stringResource(R.string.season_n, s.toString())) })
                        }
                    }
                }
                items(st.episodes.filter { it.season == season }, key = { it.id }) { e ->
                    val p = vm.episodeKey(e)?.let { st.progress[it] }
                    val done = p?.positionMs != null && p.durationMs != null && WatchHistory.isCompleted(p.positionMs!!, p.durationMs!!)
                    Row(
                        Modifier.fillMaxWidth().clickable { src?.let { nav.openPlayer(vm, vm.playEpisode(it, st.series, e)) } }.padding(vertical = 10.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Text("${e.number}", color = Tokens.TextSecondary, modifier = Modifier.width(32.dp))
                        Column(Modifier.weight(1f)) {
                            Text(e.title, color = Tokens.TextPrimary, maxLines = 2, overflow = TextOverflow.Ellipsis)
                            e.durationSec?.let { Text(stringResource(R.string.minutes_short, (it / 60).toString()), color = Tokens.TextSecondary, fontSize = 13.sp) }
                            if (p != null && !done && (p.durationMs ?: 0) > 0) {
                                LinearProgressIndicator(progress = { (p.positionMs ?: 0).toFloat() / p.durationMs!! }, modifier = Modifier.fillMaxWidth().height(2.dp), color = Tokens.Primary)
                            }
                        }
                        if (done) Text("✓ " + stringResource(R.string.watched), color = Tokens.Success, fontSize = 13.sp)
                    }
                }
            }
        }
    }
}

// ------------------------------------------------------------------------------------------ Favorites

@Composable
fun FavoritesScreen(factory: ViewModelFactory, main: MainViewModel, nav: NavHostController) {
    val vm: FavoritesViewModel = viewModel(factory = factory)
    val favs by vm.favorites.collectAsState()
    val sync by vm.lastSync.collectAsState()
    var tab by remember { mutableIntStateOf(0) }
    val scope = rememberCoroutineScope()
    val ctx = LocalContext.current
    val res = androidx.compose.ui.platform.LocalResources.current
    var message by remember { mutableStateOf<String?>(null) }
    val kinds = listOf(setOf(ContentKind.LIVE.wire), setOf(ContentKind.MOVIE.wire), setOf(ContentKind.SERIES.wire, ContentKind.EPISODE.wire))
    Column(Modifier.fillMaxSize()) {
        MainTopBar(stringResource(R.string.nav_favorites), main, nav)
        PrimaryTabRow(selectedTabIndex = tab, containerColor = Tokens.Bg) {
            listOf(R.string.favorites_channels, R.string.favorites_movies, R.string.favorites_series).forEachIndexed { i, l ->
                Tab(tab == i, onClick = { tab = i }, text = { Text(stringResource(l)) })
            }
        }
        sync.lastSyncMs?.let { Text(stringResource(R.string.last_synced, ctx.formatTime(it)), color = Tokens.TextSecondary, fontSize = 12.sp, modifier = Modifier.padding(horizontal = 16.dp, vertical = 4.dp)) }
        message?.let { Text(it, color = Tokens.Warning, modifier = Modifier.padding(16.dp)) }
        val list = favs.filter { it.contentKind in kinds[tab] }
        if (list.isEmpty()) Text(stringResource(R.string.favorites_empty), color = Tokens.TextSecondary, modifier = Modifier.padding(24.dp))
        LazyColumn {
            items(list, key = { it.key }) { e ->
                Row(
                    Modifier.fillMaxWidth().clickable {
                        scope.launch {
                            when (val t = vm.open(e)) {
                                OpenTarget.Player -> nav.navigate(Routes.PLAYER)
                                OpenTarget.Paywall -> nav.navigate(Routes.PAYWALL)
                                is OpenTarget.MovieDetail -> nav.navigate(Routes.movie(t.id))
                                is OpenTarget.SeriesDetail -> nav.navigate(Routes.show(t.id))
                                OpenTarget.Unavailable -> message = res.getString(R.string.item_unavailable)
                            }
                        }
                    }.padding(horizontal = 16.dp, vertical = 8.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    RemoteImage(e.posterUrl, null, Modifier.size(64.dp, 40.dp).clip(RoundedCornerShape(6.dp)), fit = e.contentKind == ContentKind.LIVE.wire)
                    Spacer(Modifier.width(12.dp))
                    Text(e.title, color = Tokens.TextPrimary, modifier = Modifier.weight(1f), maxLines = 1, overflow = TextOverflow.Ellipsis)
                    TextButton(onClick = { vm.remove(e) }) { Text(stringResource(R.string.action_remove)) }
                }
            }
        }
    }
}

// ------------------------------------------------------------------------------------------ Search

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SearchScreen(factory: ViewModelFactory, nav: NavHostController) {
    val vm: SearchViewModel = viewModel(factory = factory)
    val q by vm.query.collectAsState()
    val r by vm.results.collectAsState()
    Column(Modifier.fillMaxSize()) {
        Row(Modifier.padding(8.dp), verticalAlignment = Alignment.CenterVertically) {
            IconButton(onClick = { nav.popBackStack() }) { Icon(Icons.AutoMirrored.Filled.ArrowBack, stringResource(R.string.action_back)) }
            OutlinedTextField(q, { vm.query.value = it }, placeholder = { Text(stringResource(R.string.search_hint)) }, singleLine = true, modifier = Modifier.fillMaxWidth())
        }
        if (q.isNotBlank() && r.query == q && r.isEmpty) Text(stringResource(R.string.search_no_results, q), color = Tokens.TextSecondary, modifier = Modifier.padding(24.dp))
        LazyColumn {
            if (r.channels.isNotEmpty()) item { SectionTitle(stringResource(R.string.nav_live)) }
            items(r.channels, key = { "c" + it.rowId }) { c ->
                Row(Modifier.fillMaxWidth().clickable { nav.openPlayer(vm, vm.play(c)) }.padding(horizontal = 16.dp, vertical = 8.dp), verticalAlignment = Alignment.CenterVertically) {
                    RemoteImage(c.logoUrl, null, Modifier.size(56.dp, 32.dp), fit = true)
                    Spacer(Modifier.width(12.dp))
                    Text(c.name, color = Tokens.TextPrimary)
                }
            }
            if (r.movies.isNotEmpty()) item { SectionTitle(stringResource(R.string.nav_movies)) }
            items(r.movies, key = { "m" + it.rowId }) { m ->
                Text(m.name, color = Tokens.TextPrimary, modifier = Modifier.fillMaxWidth().clickable { nav.navigate(Routes.movie(m.id)) }.padding(horizontal = 16.dp, vertical = 10.dp))
            }
            if (r.series.isNotEmpty()) item { SectionTitle(stringResource(R.string.nav_series)) }
            items(r.series, key = { "s" + it.rowId }) { s ->
                Text(s.name, color = Tokens.TextPrimary, modifier = Modifier.fillMaxWidth().clickable { nav.navigate(Routes.show(s.id)) }.padding(horizontal = 16.dp, vertical = 10.dp))
            }
        }
    }
}

@Composable
fun SectionTitle(t: String) = Text(t, color = Tokens.Primary, fontWeight = FontWeight.SemiBold, modifier = Modifier.padding(start = 16.dp, top = 16.dp, bottom = 4.dp))

