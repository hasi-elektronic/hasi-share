package io.iptvplayer.app.ui.tv

import android.view.KeyEvent as AndroidKeyEvent
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxHeight
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
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.OutlinedTextField
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
import androidx.compose.ui.ExperimentalComposeUiApi
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.focusRestorer
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.input.key.KeyEventType
import androidx.compose.ui.input.key.key
import androidx.compose.ui.input.key.nativeKeyCode
import androidx.compose.ui.input.key.onPreviewKeyEvent
import androidx.compose.ui.input.key.type
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.paging.compose.collectAsLazyPagingItems
import androidx.paging.compose.itemKey
import androidx.tv.material3.Button
import androidx.tv.material3.FilterChip
import androidx.tv.material3.ListItem
import androidx.tv.material3.MaterialTheme
import androidx.tv.material3.OutlinedButton
import androidx.tv.material3.Text
import io.iptvplayer.app.ui.common.ErrorCard
import io.iptvplayer.app.ui.common.QrCode
import io.iptvplayer.app.ui.common.RemoteImage
import io.iptvplayer.app.ui.common.findActivity
import io.iptvplayer.app.ui.common.formatDate
import io.iptvplayer.app.ui.common.formatDuration
import io.iptvplayer.app.ui.common.formatTime
import io.iptvplayer.app.ui.common.progressLabel
import io.iptvplayer.app.ui.common.remainingText
import io.iptvplayer.app.ui.common.sourceErrorText
import io.iptvplayer.app.ui.common.trialChip
import io.iptvplayer.app.ui.mobile.PurchaseEventsMessage
import io.iptvplayer.app.ui.theme.Tokens
import io.iptvplayer.core.error.ErrorAction
import io.iptvplayer.core.license.AccessState
import io.iptvplayer.core.model.ContentKind
import io.iptvplayer.core.model.EpgProgram
import io.iptvplayer.core.model.SourceType
import io.iptvplayer.core.sync.WatchHistory
import io.iptvplayer.core.xmltv.EpgSchedule
import io.iptvplayer.shared.R
import io.iptvplayer.shared.db.ChannelEntity
import io.iptvplayer.shared.db.ChannelRow
import io.iptvplayer.shared.license.TrialStartResult
import io.iptvplayer.shared.pairing.PairingState
import io.iptvplayer.shared.player.AspectMode
import io.iptvplayer.shared.settings.BufferMode
import io.iptvplayer.shared.vm.AddSourceState
import io.iptvplayer.shared.vm.AddSourceViewModel
import io.iptvplayer.shared.vm.DetailViewModel
import io.iptvplayer.shared.vm.FavoritesViewModel
import io.iptvplayer.shared.vm.HomeViewModel
import io.iptvplayer.shared.vm.LiveViewModel
import io.iptvplayer.shared.vm.MainViewModel
import io.iptvplayer.shared.vm.MoviesViewModel
import io.iptvplayer.shared.vm.OpenTarget
import io.iptvplayer.shared.vm.PairingViewModel
import io.iptvplayer.shared.vm.SearchViewModel
import io.iptvplayer.shared.vm.SeriesViewModel
import io.iptvplayer.shared.vm.SettingsViewModel
import io.iptvplayer.shared.vm.SourceScopedViewModel
import io.iptvplayer.shared.vm.ViewModelFactory
import io.iptvplayer.shared.vm.VodViewModelBase
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

private fun TvNav.play(vm: SourceScopedViewModel, ok: Boolean) {
    if (!vm.canPlay()) push(TvRoute.Paywall) else if (ok) push(TvRoute.Player)
}

private val pagePadding = Modifier.padding(horizontal = Tokens.TvHorizontal, vertical = Tokens.TvVertical)

@Composable
private fun Title(text: String, modifier: Modifier = Modifier) =
    Text(text, style = MaterialTheme.typography.headlineMedium, modifier = modifier)

@Composable
private fun Secondary(text: String, modifier: Modifier = Modifier) =
    Text(text, style = MaterialTheme.typography.bodyMedium, color = Tokens.TextSecondary, modifier = modifier)

/** Requests focus once when composed (★ default focus element of each screen). */
@Composable
fun rememberDefaultFocus(key: Any? = Unit): FocusRequester {
    val fr = remember { FocusRequester() }
    LaunchedEffect(key) {
        delay(50)
        runCatching { fr.requestFocus() }
    }
    return fr
}

// ------------------------------------------------------------------------------------- welcome

/** TV welcome: trial card + add source, ★ "Add with phone (QR)" (SCREENS §3.1). */
@Composable
fun TvWelcome(main: MainViewModel, nav: TvNav) {
    val qr = rememberDefaultFocus()
    Row(Modifier.fillMaxSize().then(pagePadding), verticalAlignment = Alignment.CenterVertically) {
        Column(Modifier.weight(1f).padding(end = 48.dp)) {
            Title(stringResource(R.string.welcome_title))
            Secondary(stringResource(R.string.welcome_subtitle))
            Spacer(Modifier.height(24.dp))
            TvTrialCard(main)
            Spacer(Modifier.height(24.dp))
            Secondary(stringResource(R.string.legal_no_content))
        }
        Column(Modifier.width(380.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
            Text(stringResource(R.string.add_source), style = MaterialTheme.typography.titleLarge)
            Button(onClick = { nav.push(TvRoute.Pair) }, modifier = Modifier.fillMaxWidth().focusRequester(qr)) { Text(stringResource(R.string.add_source_qr)) }
            OutlinedButton(onClick = { nav.push(TvRoute.Add("m3u")) }, modifier = Modifier.fillMaxWidth()) { Text(stringResource(R.string.add_source_m3u)) }
            OutlinedButton(onClick = { nav.push(TvRoute.Add("xtream")) }, modifier = Modifier.fillMaxWidth()) { Text(stringResource(R.string.add_source_xtream)) }
        }
    }
}

@Composable
fun TvTrialCard(main: MainViewModel) {
    val lic by main.license.collectAsState()
    val bill by main.billing.collectAsState()
    val busy by main.busy.collectAsState()
    val ctx = LocalContext.current
    val res = androidx.compose.ui.platform.LocalResources.current
    val activity = findActivity()
    var message by remember { mutableStateOf<String?>(null) }
    PurchaseEventsMessage(main) { message = it }
    LaunchedEffect(Unit) {
        main.trialResult.collect { r ->
            message = when (r) {
                TrialStartResult.Started -> null
                TrialStartResult.AlreadyUsed -> res.getString(R.string.trial_used_on_device)
                is TrialStartResult.BackendUnavailable -> res.getString(R.string.trial_backend_unavailable)
            }
        }
    }
    val price = bill.formattedPrice ?: "—"
    Column(Modifier.fillMaxWidth().clip(RoundedCornerShape(Tokens.CardRadius)).background(Tokens.Surface).padding(24.dp)) {
        when (lic.decision.state) {
            AccessState.PURCHASED -> Text(stringResource(R.string.purchase_owned), color = Tokens.Success)
            AccessState.TRIAL_ACTIVE -> Text(stringResource(R.string.trial_active_until, ctx.formatDate(lic.decision.trialEndMs ?: 0)), color = Tokens.Success)
            AccessState.TRIAL_EXPIRED -> Text(stringResource(R.string.trial_expired), color = Tokens.Warning)
            AccessState.TRIAL_NOT_STARTED -> Text(pluralStringResource(R.plurals.trial_info, lic.trialDays, lic.trialDays, price))
        }
        if (lic.decision.pendingPurchase) Text(stringResource(R.string.purchase_pending), color = Tokens.Warning)
        Spacer(Modifier.height(16.dp))
        Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            if (lic.decision.state == AccessState.TRIAL_NOT_STARTED) {
                Button(onClick = { message = null; main.startTrial() }, enabled = !busy) { Text(stringResource(R.string.trial_start)) }
            }
            if (lic.decision.state != AccessState.PURCHASED) {
                OutlinedButton(onClick = { activity?.let { main.buy(it) } }) { Text(stringResource(R.string.purchase_buy, price)) }
                OutlinedButton(onClick = { main.restore() }) { Text(stringResource(R.string.purchase_restore)) }
            }
        }
        message?.let { Text(it, color = Tokens.Warning, modifier = Modifier.padding(top = 12.dp)) }
    }
}

// ------------------------------------------------------------------------------------- pairing

/** QR pairing: big QR + code + URL + 10 min countdown; payload → source is added (SCREENS §3.1). */
@Composable
fun TvPairing(factory: ViewModelFactory, nav: TvNav) {
    val vm: PairingViewModel = viewModel(factory = factory)
    val add: AddSourceViewModel = viewModel(factory = factory)
    val st by vm.state.collectAsState()
    val addState by add.state.collectAsState()
    val ctx = LocalContext.current
    val res = androidx.compose.ui.platform.LocalResources.current
    LaunchedEffect(Unit) { vm.start() }
    LaunchedEffect(st) { (st as? PairingState.Received)?.let { add.addPayload(it.payload) } }
    val newCode = rememberDefaultFocus(st is PairingState.Expired || st is PairingState.Failed)
    Box(Modifier.fillMaxSize().then(pagePadding), contentAlignment = Alignment.Center) {
        when (val s = st) {
            is PairingState.Waiting -> Row(verticalAlignment = Alignment.CenterVertically) {
                QrCode(s.pairUrl, 300.dp)
                Spacer(Modifier.width(48.dp))
                Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    Title(stringResource(R.string.pair_title))
                    Text(stringResource(R.string.pair_step1, s.baseUrl))
                    Text(stringResource(R.string.pair_step2, s.displayCode), style = MaterialTheme.typography.headlineLarge, color = Tokens.Primary)
                    Secondary(stringResource(R.string.pair_expires_in, "%d:%02d".format(s.remainingSec / 60, s.remainingSec % 60)))
                    Secondary(stringResource(R.string.pair_e2e))
                }
            }
            is PairingState.Received -> when (val a = addState) {
                is AddSourceState.Running -> Column(horizontalAlignment = Alignment.CenterHorizontally) {
                    Title(stringResource(R.string.pair_received))
                    Text(progressLabel(a.progress))
                }
                is AddSourceState.Success -> Column(horizontalAlignment = Alignment.CenterHorizontally) {
                    val fr = rememberDefaultFocus()
                    Title(stringResource(R.string.source_added_title))
                    Text(stringResource(R.string.source_summary, "%,d".format(a.status.liveCount), "%,d".format(a.status.movieCount), "%,d".format(a.status.seriesCount)))
                    Spacer(Modifier.height(16.dp))
                    Button(onClick = { add.reset(); nav.stack.clear() }, modifier = Modifier.focusRequester(fr)) { Text(stringResource(R.string.action_continue)) }
                }
                is AddSourceState.Failure -> ctx.sourceErrorText(a.error)?.let { t ->
                    ErrorCard(t, focusFirst = true, onAction = { act -> if (act == ErrorAction.RETRY) add.addPayload((st as PairingState.Received).payload) else nav.pop() })
                }
                else -> Title(stringResource(R.string.pair_received))
            }
            PairingState.Expired, is PairingState.Failed -> Column(horizontalAlignment = Alignment.CenterHorizontally) {
                Title(stringResource(if (s is PairingState.Expired) R.string.pair_expired else R.string.trial_backend_unavailable))
                Spacer(Modifier.height(16.dp))
                Button(onClick = { vm.start() }, modifier = Modifier.focusRequester(newCode)) { Text(stringResource(R.string.action_new_code)) }
            }
            else -> Text(stringResource(R.string.loading))
        }
    }
}

// ------------------------------------------------------------------------------------- home

@Composable
fun TvHome(factory: ViewModelFactory, main: MainViewModel, nav: TvNav) {
    val vm: HomeViewModel = viewModel(factory = factory)
    val rows by vm.rows.collectAsState()
    val source by vm.source.collectAsState()
    val lic by main.license.collectAsState()
    val scope = rememberCoroutineScope()
    val first = rememberDefaultFocus(rows.loaded)
    LazyColumn(Modifier.fillMaxSize(), contentPadding = PaddingValues(vertical = Tokens.TvVertical)) {
        item {
            Row(Modifier.padding(horizontal = Tokens.TvHorizontal), verticalAlignment = Alignment.CenterVertically) {
                Title(stringResource(R.string.nav_home), Modifier.weight(1f))
                source?.let { Secondary(it.name) }
                trialChip(lic)?.let {
                    Spacer(Modifier.width(16.dp))
                    OutlinedButton(onClick = { nav.push(TvRoute.Paywall) }) { Text(it) }
                }
            }
        }
        if (rows.loaded && rows.isEmpty) item { Secondary(stringResource(R.string.home_empty), Modifier.padding(Tokens.TvHorizontal)) }
        var firstAssigned = false
        fun firstMod(): Modifier = if (!firstAssigned) { firstAssigned = true; Modifier.focusRequester(first) } else Modifier
        if (rows.continueWatching.isNotEmpty()) {
            val m = firstMod()
            item {
                TvShelf(stringResource(R.string.home_continue)) {
                    items(rows.continueWatching, key = { it.key }) { e ->
                        Column(Modifier.width(260.dp).then(if (e == rows.continueWatching.first()) m else Modifier)) {
                            TvCard({ scope.launch { if (!vm.canPlay()) nav.push(TvRoute.Paywall) else if (vm.playResolved(e.contentKey)) nav.push(TvRoute.Player) } }, Modifier.fillMaxWidth().aspectRatio(16f / 9f)) {
                                RemoteImage(e.posterUrl, e.title, Modifier.fillMaxSize())
                            }
                            Text(e.title, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.padding(top = 6.dp))
                        }
                    }
                }
            }
        }
        listOf(R.string.home_recent_channels to rows.recentChannels, R.string.home_favorite_channels to rows.favoriteChannels).forEach { (title, list) ->
            if (list.isNotEmpty()) {
                val m = firstMod()
                item(key = "shelf$title") {
                    TvShelf(stringResource(title)) {
                        items(list, key = { "$title" + it.channel.id }) { r ->
                            Box(if (r == list.first()) m else Modifier) {
                                TvLogoCard(r.channel.name, r.channel.logoUrl, r.nowTitle, onClick = { source?.let { nav.play(vm, vm.playChannel(it, r.channel, list.map { c -> c.channel.id })) } })
                            }
                        }
                    }
                }
            }
        }
        if (rows.newMovies.isNotEmpty()) {
            val m = firstMod()
            item {
                TvShelf(stringResource(R.string.home_new_movies)) {
                    items(rows.newMovies, key = { it.id }) { mv -> Box(if (mv == rows.newMovies.first()) m else Modifier) { TvPoster(mv.name, mv.posterUrl, onClick = { nav.push(TvRoute.Detail(ContentKind.MOVIE, mv.id)) }) } }
                }
            }
        }
        if (rows.newSeries.isNotEmpty()) {
            val m = firstMod()
            item {
                TvShelf(stringResource(R.string.home_new_series)) {
                    items(rows.newSeries, key = { it.id }) { s -> Box(if (s == rows.newSeries.first()) m else Modifier) { TvPoster(s.name, s.posterUrl, onClick = { nav.push(TvRoute.Detail(ContentKind.SERIES, s.id)) }) } }
                }
            }
        }
    }
}

// ------------------------------------------------------------------------------------- live TV

/** 3 columns: categories | channels ★ | preview (SCREENS §3.3). Menu / long OK = favorite. */
@OptIn(ExperimentalComposeUiApi::class)
@Composable
fun TvLive(factory: ViewModelFactory, nav: TvNav) {
    val vm: LiveViewModel = viewModel(factory = factory)
    val cats by vm.categories.collectAsState()
    val cat by vm.category.collectAsState()
    val favs by vm.favoriteKeys.collectAsState()
    val source by vm.source.collectAsState()
    val items = vm.channels.collectAsLazyPagingItems()
    var focused by remember { mutableStateOf<ChannelRow?>(null) }
    val ctx = LocalContext.current
    val res = androidx.compose.ui.platform.LocalResources.current
    // Back from the player: focus returns to the channel that was opened (SCREENS §2 rule 2).
    val restoreIndex = vm.lastOpenedIndex.coerceAtMost((items.itemCount - 1).coerceAtLeast(0))
    val channelsFocus = rememberDefaultFocus(items.itemCount > 0)
    val listState = androidx.compose.foundation.lazy.rememberLazyListState(initialFirstVisibleItemIndex = (restoreIndex - 3).coerceAtLeast(0))
    Row(Modifier.fillMaxSize().padding(vertical = Tokens.TvVertical)) {
        // -- categories
        LazyColumn(Modifier.width(220.dp).fillMaxHeight().focusRestorer(), contentPadding = PaddingValues(horizontal = 12.dp)) {
            item {
                OutlinedButton(onClick = { nav.push(TvRoute.Guide) }, modifier = Modifier.fillMaxWidth().padding(bottom = 8.dp)) { Text(stringResource(R.string.action_guide)) }
            }
            item { ListItem(selected = cat == null, onClick = { vm.selectCategory(null) }, headlineContent = { Text(stringResource(R.string.all)) }) }
            item { ListItem(selected = cat == LiveViewModel.FAVORITES, onClick = { vm.selectCategory(LiveViewModel.FAVORITES) }, headlineContent = { Text(stringResource(R.string.nav_favorites)) }) }
            items(cats, key = { it.id }) { c ->
                ListItem(selected = cat == c.id, onClick = { vm.selectCategory(c.id) }, headlineContent = { Text(c.name, maxLines = 1, overflow = TextOverflow.Ellipsis) })
            }
        }
        // -- channels ★
        LazyColumn(Modifier.weight(1f).fillMaxHeight().focusRestorer(), state = listState, contentPadding = PaddingValues(horizontal = 12.dp)) {
            if (items.itemCount == 0) item { Secondary(stringResource(R.string.live_empty), Modifier.padding(16.dp)) }
            items(items.itemCount, key = items.itemKey { it.channel.rowId }) { i ->
                val r = items[i] ?: return@items
                val key = source?.contentKey(ContentKind.LIVE, r.channel.id)
                val toggleFav = { key?.let { vm.toggleFavorite(it, r.channel.name, ContentKind.LIVE, r.channel.logoUrl) }; Unit }
                ListItem(
                    selected = false,
                    onClick = {
                        vm.lastOpenedIndex = i
                        vm.play(r.channel) { ok -> nav.play(vm, ok) }
                    },
                    onLongClick = toggleFav,
                    modifier = Modifier
                        .then(if (i == restoreIndex) Modifier.focusRequester(channelsFocus) else Modifier)
                        .onFocusChanged { if (it.isFocused) focused = r }
                        .onPreviewKeyEvent { e ->
                            if (e.type == KeyEventType.KeyDown && e.key.nativeKeyCode == AndroidKeyEvent.KEYCODE_MENU) { toggleFav(); true } else false
                        },
                    leadingContent = {
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Text(r.channel.number?.toString() ?: "", modifier = Modifier.width(36.dp), color = Tokens.TextSecondary)
                            RemoteImage(r.channel.logoUrl, null, Modifier.size(64.dp, 36.dp).clip(RoundedCornerShape(6.dp)), fit = true)
                        }
                    },
                    headlineContent = { Text(r.channel.name, maxLines = 1, overflow = TextOverflow.Ellipsis) },
                    supportingContent = { Text(r.nowTitle ?: stringResource(R.string.epg_no_info), maxLines = 1, overflow = TextOverflow.Ellipsis) },
                    trailingContent = { if (key != null && key in favs) Text("♥", color = Tokens.Live) },
                )
            }
        }
        // -- preview
        Column(Modifier.width(330.dp).fillMaxHeight().padding(horizontal = 20.dp)) {
            val f = focused
            if (f != null) {
                val progs by produceState(initialValue = emptyList<EpgProgram>(), f.channel.rowId) { value = vm.programmes(f.channel, 0, 6) }
                val nn = EpgSchedule.nowAndNext(progs, vm.nowMs())
                RemoteImage(f.channel.logoUrl, null, Modifier.fillMaxWidth().aspectRatio(16f / 9f).clip(RoundedCornerShape(Tokens.CardRadius)), fit = true)
                Spacer(Modifier.height(12.dp))
                Text(f.channel.name, style = MaterialTheme.typography.titleLarge)
                nn.now?.let {
                    Text(stringResource(R.string.epg_now) + " · " + ctx.formatTime(it.startMs) + "–" + ctx.formatTime(it.endMs), color = Tokens.Live)
                    Text(it.title, style = MaterialTheme.typography.titleMedium)
                    it.description?.let { d -> Secondary(d, Modifier.padding(top = 4.dp)) }
                } ?: Secondary(stringResource(R.string.epg_no_info))
                nn.next?.let {
                    Spacer(Modifier.height(12.dp))
                    Text(stringResource(R.string.epg_next) + " · " + ctx.formatTime(it.startMs), color = Tokens.TextSecondary)
                    Text(it.title)
                }
            }
        }
    }
}

/** TV EPG grid: rows = channels, D-pad moves between programmes; past + catch-up → "Watch from start". */
@OptIn(ExperimentalComposeUiApi::class)
@Composable
fun TvGuide(factory: ViewModelFactory, nav: TvNav) {
    val vm: LiveViewModel = viewModel(factory = factory)
    val source by vm.source.collectAsState()
    val ctx = LocalContext.current
    val res = androidx.compose.ui.platform.LocalResources.current
    val now = remember { vm.nowMs() }
    val from = now - 2 * 3_600_000L
    val to = now + 6 * 3_600_000L
    val rows by produceState(initialValue = emptyList<Pair<ChannelEntity, List<EpgProgram>>>(), source) { if (source != null) value = vm.guide(from, to, 100) }
    val first = rememberDefaultFocus(rows.isNotEmpty())
    Column(Modifier.fillMaxSize().then(pagePadding)) {
        Title(stringResource(R.string.action_guide))
        LazyColumn(Modifier.fillMaxSize().focusRestorer()) {
            items(rows, key = { it.first.rowId }) { (c, progs) ->
                Row(Modifier.padding(vertical = 4.dp), verticalAlignment = Alignment.CenterVertically) {
                    Text(c.name, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.width(200.dp))
                    val shown = progs.ifEmpty { listOf(EpgProgram(c.sourceId, "", now, now + 3_600_000L, res.getString(R.string.epg_no_info))) }
                    val startIdx = shown.indexOfFirst { it.isLiveAt(now) }.coerceAtLeast(0)
                    LazyRow(Modifier.focusRestorer(), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        items(shown.drop(startIdx).take(8) + shown.take(startIdx).takeLast(3)) { p ->
                            val live = p.isLiveAt(now)
                            val past = p.endMs <= now
                            val catchup = past && EpgSchedule.isCatchupAvailable(p, io.iptvplayer.core.model.CatchupInfo(io.iptvplayer.core.model.CatchupType.fromWire(c.catchupType), c.catchupDays, c.catchupSource), now)
                            TvCard(
                                onClick = {
                                    val s = source ?: return@TvCard
                                    if (live) nav.play(vm, vm.playChannel(s, c)) else if (catchup) nav.play(vm, vm.playCatchup(s, c, p))
                                },
                                modifier = Modifier.width(260.dp).then(if (live && c == rows.first().first) Modifier.focusRequester(first) else Modifier),
                            ) {
                                Column(Modifier.padding(10.dp)) {
                                    Text(ctx.formatTime(p.startMs) + "–" + ctx.formatTime(p.endMs), color = if (live) Tokens.Live else Tokens.TextSecondary)
                                    Text(p.title, maxLines = 1, overflow = TextOverflow.Ellipsis)
                                    if (catchup) Text(stringResource(R.string.action_watch_from_start), color = Tokens.Primary)
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

// ------------------------------------------------------------------------------------- movies / series

@OptIn(ExperimentalComposeUiApi::class)
@Composable
fun TvGrid(factory: ViewModelFactory, nav: TvNav, kind: ContentKind) {
    val vm: VodViewModelBase = if (kind == ContentKind.MOVIE) viewModel<MoviesViewModel>(factory = factory) else viewModel<SeriesViewModel>(factory = factory)
    val cats by vm.categories.collectAsState()
    val cat by vm.category.collectAsState()
    val empty by vm.isEmpty.collectAsState()
    val movies = vm.movies.collectAsLazyPagingItems()
    val series = vm.series.collectAsLazyPagingItems()
    val count = if (kind == ContentKind.MOVIE) movies.itemCount else series.itemCount
    val first = rememberDefaultFocus(count > 0)
    Column(Modifier.fillMaxSize().padding(vertical = Tokens.TvVertical)) {
        Title(stringResource(if (kind == ContentKind.MOVIE) R.string.nav_movies else R.string.nav_series), Modifier.padding(horizontal = Tokens.TvHorizontal))
        LazyRow(Modifier.focusRestorer(), contentPadding = PaddingValues(horizontal = Tokens.TvHorizontal, vertical = 12.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            item { FilterChip(selected = cat == null, onClick = { vm.selectCategory(null) }) { Text(stringResource(R.string.all)) } }
            items(cats, key = { it.id }) { c -> FilterChip(selected = cat == c.id, onClick = { vm.selectCategory(c.id) }) { Text(c.name) } }
        }
        if (empty == true) Secondary(stringResource(if (kind == ContentKind.MOVIE) R.string.movies_empty else R.string.series_empty), Modifier.padding(Tokens.TvHorizontal))
        LazyVerticalGrid(
            columns = GridCells.Adaptive(160.dp),
            modifier = Modifier.focusRestorer(),
            contentPadding = PaddingValues(horizontal = Tokens.TvHorizontal, vertical = 12.dp),
            horizontalArrangement = Arrangement.spacedBy(24.dp),
            verticalArrangement = Arrangement.spacedBy(24.dp),
        ) {
            if (kind == ContentKind.MOVIE) {
                items(movies.itemCount, key = movies.itemKey { it.rowId }) { i ->
                    movies[i]?.let { m -> Box(if (i == 0) Modifier.focusRequester(first) else Modifier) { TvPoster(m.name, m.posterUrl, onClick = { nav.push(TvRoute.Detail(ContentKind.MOVIE, m.id)) }) } }
                }
            } else {
                items(series.itemCount, key = series.itemKey { it.rowId }) { i ->
                    series[i]?.let { s -> Box(if (i == 0) Modifier.focusRequester(first) else Modifier) { TvPoster(s.name, s.posterUrl, onClick = { nav.push(TvRoute.Detail(ContentKind.SERIES, s.id)) }) } }
                }
            }
        }
    }
}

@OptIn(ExperimentalComposeUiApi::class)
@Composable
fun TvDetail(factory: ViewModelFactory, nav: TvNav, kind: ContentKind, id: String) {
    val vm: DetailViewModel = viewModel(factory = factory)
    val st by vm.state.collectAsState()
    val favs by vm.favoriteKeys.collectAsState()
    LaunchedEffect(id) { vm.load(kind, id) }
    var season by remember { mutableIntStateOf(-1) }
    val play = rememberDefaultFocus(st.loading)
    val src = st.source
    val poster = st.movie?.posterUrl ?: st.series?.posterUrl
    Box(Modifier.fillMaxSize()) {
        RemoteImage(poster, null, Modifier.fillMaxSize())
        Box(Modifier.fillMaxSize().background(Tokens.Bg.copy(alpha = 0.88f)))
        Row(Modifier.fillMaxSize().then(pagePadding)) {
            RemoteImage(poster, null, Modifier.width(240.dp).aspectRatio(2f / 3f).clip(RoundedCornerShape(Tokens.PosterRadius)))
            Spacer(Modifier.width(40.dp))
            Column(Modifier.weight(1f)) {
                Title(st.movie?.name ?: st.series?.name ?: "")
                Secondary(listOfNotNull((st.movie?.year ?: st.series?.year)?.toString(), (st.movie?.rating ?: st.series?.rating)?.let { "★ %.1f".format(it) }).joinToString(" · "))
                (st.movie?.plot ?: st.series?.plot)?.let { Secondary(it, Modifier.padding(top = 12.dp)) }
                Spacer(Modifier.height(20.dp))
                Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                    val m = st.movie
                    if (src != null && m != null) {
                        Button(onClick = { nav.play(vm, vm.playMovie(src, m)) }, modifier = Modifier.focusRequester(play)) {
                            Text(st.resumeMs?.let { stringResource(R.string.action_resume_at, formatDuration(it)) } ?: stringResource(R.string.action_play))
                        }
                        if (st.resumeMs != null) OutlinedButton(onClick = { nav.play(vm, vm.playMovie(src, m, true)) }) { Text(stringResource(R.string.action_play_from_start)) }
                    }
                    val ce = st.continueEpisode
                    if (src != null && ce != null) {
                        Button(onClick = { nav.play(vm, vm.playEpisode(src, st.series, ce)) }, modifier = Modifier.focusRequester(play)) {
                            Text(stringResource(R.string.continue_episode, "S%02dE%02d".format(ce.season, ce.number)))
                        }
                    }
                    val key = src?.let { s -> m?.let { s.contentKey(ContentKind.MOVIE, it.id) } ?: st.series?.let { s.contentKey(ContentKind.SERIES, it.id) } }
                    if (key != null) {
                        OutlinedButton(onClick = { vm.toggleFavorite(key, m?.name ?: st.series?.name.orEmpty(), kind, poster) }) {
                            Text(stringResource(if (key in favs) R.string.action_remove_favorite else R.string.action_add_favorite))
                        }
                    }
                }
                if (st.seasons.isNotEmpty()) {
                    val sel = if (season in st.seasons) season else st.continueEpisode?.season ?: st.seasons.first()
                    LazyRow(Modifier.padding(top = 20.dp).focusRestorer(), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        items(st.seasons) { s -> FilterChip(selected = s == sel, onClick = { season = s }) { Text(stringResource(R.string.season_n, s.toString())) } }
                    }
                    LazyColumn(Modifier.focusRestorer().padding(top = 8.dp)) {
                        items(st.episodes.filter { it.season == sel }, key = { it.id }) { e ->
                            val p = vm.episodeKey(e)?.let { st.progress[it] }
                            val done = p?.positionMs != null && p.durationMs != null && WatchHistory.isCompleted(p.positionMs!!, p.durationMs!!)
                            ListItem(
                                selected = false,
                                onClick = { src?.let { nav.play(vm, vm.playEpisode(it, st.series, e)) } },
                                headlineContent = { Text("${e.number}. ${e.title}", maxLines = 1, overflow = TextOverflow.Ellipsis) },
                                supportingContent = { e.durationSec?.let { Text(stringResource(R.string.minutes_short, (it / 60).toString())) } },
                                trailingContent = { if (done) Text("✓ " + stringResource(R.string.watched), color = Tokens.Success) },
                            )
                        }
                    }
                }
            }
        }
    }
}

// ------------------------------------------------------------------------------------- favorites / search

@Composable
fun TvFavorites(factory: ViewModelFactory, nav: TvNav) {
    val vm: FavoritesViewModel = viewModel(factory = factory)
    val favs by vm.favorites.collectAsState()
    val scope = rememberCoroutineScope()
    val first = rememberDefaultFocus(favs.isNotEmpty())
    Column(Modifier.fillMaxSize().padding(vertical = Tokens.TvVertical)) {
        Title(stringResource(R.string.nav_favorites), Modifier.padding(horizontal = Tokens.TvHorizontal))
        if (favs.isEmpty()) Secondary(stringResource(R.string.favorites_empty), Modifier.padding(Tokens.TvHorizontal))
        LazyColumn {
            listOf(
                R.string.favorites_channels to setOf(ContentKind.LIVE.wire),
                R.string.favorites_movies to setOf(ContentKind.MOVIE.wire),
                R.string.favorites_series to setOf(ContentKind.SERIES.wire, ContentKind.EPISODE.wire),
            ).forEach { (title, kinds) ->
                val list = favs.filter { it.contentKind in kinds }
                if (list.isNotEmpty()) item(key = title) {
                    TvShelf(stringResource(title)) {
                        items(list, key = { it.key }) { e ->
                            val open = {
                                scope.launch {
                                    when (val t = vm.open(e)) {
                                        OpenTarget.Player -> nav.push(TvRoute.Player)
                                        OpenTarget.Paywall -> nav.push(TvRoute.Paywall)
                                        is OpenTarget.MovieDetail -> nav.push(TvRoute.Detail(ContentKind.MOVIE, t.id))
                                        is OpenTarget.SeriesDetail -> nav.push(TvRoute.Detail(ContentKind.SERIES, t.id))
                                        OpenTarget.Unavailable -> Unit
                                    }
                                }
                                Unit
                            }
                            Box(
                                (if (e == favs.firstOrNull()) Modifier.focusRequester(first) else Modifier).onPreviewKeyEvent { ev ->
                                    if (ev.type == KeyEventType.KeyDown && ev.key.nativeKeyCode == AndroidKeyEvent.KEYCODE_MENU) { vm.remove(e); true } else false
                                },
                            ) {
                                if (e.contentKind == ContentKind.LIVE.wire) TvLogoCard(e.title, e.posterUrl, null, onClick = open, onLongClick = { vm.remove(e) })
                                else TvPoster(e.title, e.posterUrl, onClick = open, onLongClick = { vm.remove(e) })
                            }
                        }
                    }
                }
            }
        }
    }
}

@Composable
fun TvSearch(factory: ViewModelFactory, nav: TvNav) {
    val vm: SearchViewModel = viewModel(factory = factory)
    val q by vm.query.collectAsState()
    val r by vm.results.collectAsState()
    val field = rememberDefaultFocus()
    LazyColumn(Modifier.fillMaxSize().padding(vertical = Tokens.TvVertical)) {
        item {
            OutlinedTextField(q, { vm.query.value = it }, placeholder = { androidx.compose.material3.Text(stringResource(R.string.search_hint)) }, singleLine = true,
                modifier = Modifier.padding(horizontal = Tokens.TvHorizontal).fillMaxWidth().focusRequester(field))
        }
        if (q.isNotBlank() && r.query == q && r.isEmpty) item { Secondary(stringResource(R.string.search_no_results, q), Modifier.padding(Tokens.TvHorizontal)) }
        if (r.channels.isNotEmpty()) item {
            TvShelf(stringResource(R.string.nav_live)) { items(r.channels, key = { it.rowId }) { c -> TvLogoCard(c.name, c.logoUrl, null, onClick = { nav.play(vm, vm.play(c)) }) } }
        }
        if (r.movies.isNotEmpty()) item {
            TvShelf(stringResource(R.string.nav_movies)) { items(r.movies, key = { it.rowId }) { m -> TvPoster(m.name, m.posterUrl, onClick = { nav.push(TvRoute.Detail(ContentKind.MOVIE, m.id)) }) } }
        }
        if (r.series.isNotEmpty()) item {
            TvShelf(stringResource(R.string.nav_series)) { items(r.series, key = { it.rowId }) { s -> TvPoster(s.name, s.posterUrl, onClick = { nav.push(TvRoute.Detail(ContentKind.SERIES, s.id)) }) } }
        }
    }
}

// ------------------------------------------------------------------------------------- settings

/** TV settings: list items; choices cycle on OK (D-pad friendly). */
@Composable
fun TvSettings(factory: ViewModelFactory, main: MainViewModel, nav: TvNav) {
    val vm: SettingsViewModel = viewModel(factory = factory)
    val s by vm.settings.collectAsState()
    val sources by vm.sources.collectAsState()
    val account by main.account.collectAsState()
    val lic by main.license.collectAsState()
    val ctx = LocalContext.current
    val res = androidx.compose.ui.platform.LocalResources.current
    val first = rememberDefaultFocus()
    fun <T> next(list: List<T>, cur: T): T = list[(list.indexOf(cur) + 1) % list.size]
    val langs = listOf("", "tr", "en", "de", "ar")
    val system = stringResource(R.string.system_default)
    LazyColumn(Modifier.fillMaxSize().then(pagePadding), verticalArrangement = Arrangement.spacedBy(4.dp)) {
        item { Title(stringResource(R.string.nav_settings)) }
        item { Header(stringResource(R.string.settings_sources)) }
        items(sources, key = { it.id }) { src ->
            ListItem(
                selected = false,
                onClick = { nav.push(TvRoute.Source(src.id)) },
                modifier = if (src == sources.first()) Modifier.focusRequester(first) else Modifier,
                headlineContent = { Text(src.name) },
                supportingContent = { Text((if (src.type == SourceType.XTREAM) "Xtream · " else "M3U · ") + src.displayHost) },
            )
        }
        item { ListItem(selected = false, onClick = { nav.push(TvRoute.Pair) }, headlineContent = { Text("+ " + stringResource(R.string.add_source_qr)) }) }
        item { ListItem(selected = false, onClick = { nav.push(TvRoute.Add("m3u")) }, headlineContent = { Text("+ " + stringResource(R.string.add_source_m3u)) }) }
        item { ListItem(selected = false, onClick = { nav.push(TvRoute.Add("xtream")) }, headlineContent = { Text("+ " + stringResource(R.string.add_source_xtream)) }) }
        item { Header(stringResource(R.string.settings_playback)) }
        item { Choice(stringResource(R.string.pref_audio_lang), s.audioLanguage.ifEmpty { system }) { vm.update { it.copy(audioLanguage = next(langs, it.audioLanguage)) } } }
        item { Choice(stringResource(R.string.pref_subtitle_lang), s.subtitleLanguage.ifEmpty { res.getString(R.string.off) }) { vm.update { it.copy(subtitleLanguage = next(langs, it.subtitleLanguage)) } } }
        item { Choice(stringResource(R.string.pref_default_aspect), io.iptvplayer.app.ui.common.aspectLabel(s.aspect)) { vm.update { it.copy(aspect = next(AspectMode.entries, it.aspect)) } } }
        item { Choice(stringResource(R.string.pref_live_format), s.liveFormat.name) { vm.update { it.copy(liveFormat = next(io.iptvplayer.core.xtream.LiveFormatPreference.entries, it.liveFormat)) } } }
        item { Choice(stringResource(R.string.pref_buffer), stringResource(if (s.buffer == BufferMode.LARGE) R.string.buffer_large else R.string.buffer_normal)) { vm.update { it.copy(buffer = next(BufferMode.entries, it.buffer)) } } }
        item { Choice(stringResource(R.string.pref_tv_preview), stringResource(if (s.tvPreview) R.string.automatic else R.string.off)) { vm.update { it.copy(tvPreview = !it.tvPreview) } } }
        item { Header(stringResource(R.string.settings_appearance)) }
        item {
            Choice(stringResource(R.string.pref_app_language), when (s.appLanguage) { "tr" -> "Türkçe"; "en" -> "English"; else -> system }) {
                val v = next(listOf("", "tr", "en"), s.appLanguage)
                vm.update { it.copy(appLanguage = v) }
                io.iptvplayer.app.ui.common.AppLocale.apply(ctx, v)
            }
        }
        item { Choice(stringResource(R.string.pref_24h), stringResource(if (s.use24h) R.string.source_status_ok else R.string.off)) { vm.update { it.copy(use24h = !it.use24h) } } }
        item { Header(stringResource(R.string.settings_account)) }
        item {
            ListItem(
                selected = false, onClick = { nav.push(TvRoute.Account) },
                headlineContent = { Text(account.account?.let { stringResource(R.string.account_signed_in_as, it.email) } ?: stringResource(R.string.account_sign_in_tv)) },
                supportingContent = { Text(stringResource(R.string.account_why)) },
            )
        }
        item { Header(stringResource(R.string.settings_purchase)) }
        item {
            ListItem(
                selected = false, onClick = { nav.push(TvRoute.Paywall) },
                headlineContent = {
                    Text(
                        when (lic.decision.state) {
                            AccessState.PURCHASED -> stringResource(R.string.purchase_owned)
                            AccessState.TRIAL_ACTIVE -> stringResource(R.string.trial_remaining, remainingText(lic.trialRemainingMs))
                            AccessState.TRIAL_EXPIRED -> stringResource(R.string.trial_expired)
                            AccessState.TRIAL_NOT_STARTED -> stringResource(R.string.trial_not_started)
                        },
                    )
                },
            )
        }
        item { ListItem(selected = false, onClick = { main.restore() }, headlineContent = { Text(stringResource(R.string.purchase_restore)) }) }
        item { Header(stringResource(R.string.settings_advanced)) }
        item { ListItem(selected = false, onClick = { nav.push(TvRoute.FormatTest) }, headlineContent = { Text(stringResource(R.string.diagnostics_format_test)) }) }
        item { ListItem(selected = false, onClick = { vm.clearEpg() }, headlineContent = { Text(stringResource(R.string.diagnostics_clear_epg)) }) }
        item { ListItem(selected = false, onClick = {}, headlineContent = { Text(stringResource(R.string.about_version, "${vm.versionName} (${vm.versionCode})")) }) }
    }
}

@Composable
private fun Header(t: String) = Text(t, color = Tokens.Primary, style = MaterialTheme.typography.titleMedium, modifier = Modifier.padding(top = 20.dp, bottom = 4.dp))

@Composable
private fun Choice(title: String, value: String, onClick: () -> Unit) =
    ListItem(selected = false, onClick = onClick, headlineContent = { Text(title) }, trailingContent = { Text(value, color = Tokens.TextSecondary) })

@Composable
fun TvSourceDetail(factory: ViewModelFactory, nav: TvNav, id: String) {
    val vm: SettingsViewModel = viewModel(factory = factory)
    val sources by vm.sources.collectAsState()
    val refreshing by vm.refreshing.collectAsState()
    val src = sources.firstOrNull { it.id == id } ?: return
    val ctx = LocalContext.current
    val res = androidx.compose.ui.platform.LocalResources.current
    var confirm by remember { mutableStateOf(false) }
    val first = rememberDefaultFocus()
    LazyColumn(Modifier.fillMaxSize().then(pagePadding)) {
        item { Title(src.name) }
        item {
            Secondary(
                listOfNotNull(
                    src.displayHost,
                    src.lastRefreshAtMs?.let { stringResource(R.string.source_last_refresh, ctx.formatDate(it)) },
                    src.lastRefreshResult?.let { stringResource(R.string.source_summary, "%,d".format(it.liveCount), "%,d".format(it.movieCount), "%,d".format(it.seriesCount)) },
                    src.xtreamAccount?.expiresAtMs?.let { stringResource(R.string.source_expires, ctx.formatDate(it)) },
                ).joinToString(" · "),
            )
        }
        item {
            ListItem(selected = false, onClick = { vm.refresh(id) }, modifier = Modifier.focusRequester(first),
                headlineContent = { Text(stringResource(R.string.action_refresh)) },
                trailingContent = { if (id in refreshing) Text(stringResource(R.string.loading)) })
        }
        item { ListItem(selected = false, onClick = { nav.push(TvRoute.Add(if (src.type == SourceType.XTREAM) "xtream" else "m3u", id)) }, headlineContent = { Text(stringResource(R.string.action_edit)) }) }
        item {
            Choice(stringResource(R.string.source_epg_shift), stringResource(R.string.minutes_short, src.epgShiftMinutes.toString())) {
                vm.updateSource(id) { it.copy(epgShiftMinutes = if (it.epgShiftMinutes >= 720) -720 else it.epgShiftMinutes + 15) }
            }
        }
        item {
            Choice(stringResource(R.string.source_auto_refresh), if (src.autoRefreshHours == 0) stringResource(R.string.off) else stringResource(R.string.every_n_hours, src.autoRefreshHours.toString())) {
                val opts = listOf(0, 6, 12, 24)
                vm.updateSource(id) { it.copy(autoRefreshHours = opts[(opts.indexOf(it.autoRefreshHours) + 1) % opts.size]) }
            }
        }
        item {
            ListItem(selected = false, onClick = { if (confirm) { vm.delete(id); nav.pop() } else confirm = true },
                headlineContent = { Text(if (confirm) stringResource(R.string.source_delete_confirm, src.name) else stringResource(R.string.action_delete), color = Tokens.Error) })
        }
    }
}

// ------------------------------------------------------------------------------------- paywall

@Composable
fun TvPaywall(main: MainViewModel, nav: TvNav) {
    val lic by main.license.collectAsState()
    val bill by main.billing.collectAsState()
    val activity = findActivity()
    val buy = rememberDefaultFocus()
    var message by remember { mutableStateOf<String?>(null) }
    PurchaseEventsMessage(main) { message = it }
    Row(Modifier.fillMaxSize().then(pagePadding), verticalAlignment = Alignment.CenterVertically) {
        Column(Modifier.weight(1f).clip(RoundedCornerShape(Tokens.CardRadius)).background(Tokens.PremiumGradient).padding(40.dp)) {
            Text(stringResource(R.string.paywall_title), style = MaterialTheme.typography.headlineLarge)
            Text(stringResource(R.string.paywall_subtitle))
            Spacer(Modifier.height(20.dp))
            listOf(R.string.paywall_benefit_1, R.string.paywall_benefit_2, R.string.paywall_benefit_3).forEach { Text("✓  " + stringResource(it)) }
        }
        Spacer(Modifier.width(48.dp))
        Column(Modifier.width(420.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
            Text(
                when (lic.decision.state) {
                    AccessState.PURCHASED -> stringResource(R.string.purchase_owned)
                    AccessState.TRIAL_ACTIVE -> stringResource(R.string.trial_remaining, remainingText(lic.trialRemainingMs))
                    AccessState.TRIAL_EXPIRED -> stringResource(R.string.trial_expired)
                    AccessState.TRIAL_NOT_STARTED -> stringResource(R.string.trial_not_started)
                },
                style = MaterialTheme.typography.titleLarge,
            )
            if (lic.decision.pendingPurchase) Text(stringResource(R.string.purchase_pending), color = Tokens.Warning)
            if (lic.decision.state != AccessState.PURCHASED) {
                Button(onClick = { activity?.let { main.buy(it) } }, modifier = Modifier.fillMaxWidth().focusRequester(buy)) { Text(stringResource(R.string.purchase_buy, bill.formattedPrice ?: "—")) }
                if (lic.decision.state == AccessState.TRIAL_NOT_STARTED) OutlinedButton(onClick = { main.startTrial() }, modifier = Modifier.fillMaxWidth()) { Text(stringResource(R.string.trial_start)) }
            }
            OutlinedButton(onClick = { main.restore() }, modifier = Modifier.fillMaxWidth().then(if (lic.decision.state == AccessState.PURCHASED) Modifier.focusRequester(buy) else Modifier)) { Text(stringResource(R.string.purchase_restore)) }
            OutlinedButton(onClick = { nav.push(TvRoute.Account) }, modifier = Modifier.fillMaxWidth()) { Text(stringResource(R.string.account_sign_in_tv)) }
            Secondary(stringResource(R.string.paywall_other_platform))
            message?.let { Text(it, color = Tokens.Warning) }
        }
    }
}

