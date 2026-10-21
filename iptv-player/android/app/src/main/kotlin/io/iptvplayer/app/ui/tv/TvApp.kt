package io.iptvplayer.app.ui.tv

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Favorite
import androidx.compose.material.icons.filled.Home
import androidx.compose.material.icons.filled.LiveTv
import androidx.compose.material.icons.filled.Movie
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material.icons.filled.VideoLibrary
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.focus.FocusDirection
import androidx.compose.ui.input.key.Key
import androidx.compose.ui.input.key.KeyEventType
import androidx.compose.ui.input.key.key
import androidx.compose.ui.input.key.onPreviewKeyEvent
import androidx.compose.ui.input.key.type
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.tv.material3.DrawerValue
import androidx.tv.material3.Icon
import androidx.tv.material3.NavigationDrawer
import androidx.tv.material3.NavigationDrawerItem
import androidx.tv.material3.Text
import androidx.tv.material3.rememberDrawerState
import io.iptvplayer.app.ui.common.PlayerScreen
import io.iptvplayer.app.ui.common.findActivity
import io.iptvplayer.app.ui.mobile.AccountScreen
import io.iptvplayer.app.ui.mobile.AddSourceScreen
import io.iptvplayer.app.ui.mobile.FormatTestScreen
import io.iptvplayer.app.ui.theme.Tokens
import io.iptvplayer.core.model.ContentKind
import io.iptvplayer.shared.R
import io.iptvplayer.shared.di.AppGraph
import io.iptvplayer.shared.vm.MainViewModel
import io.iptvplayer.shared.vm.ViewModelFactory

/** Sections of the left navigation menu (SCREENS §2 TV). */
enum class TvSection(val label: Int, val icon: ImageVector) {
    SEARCH(R.string.nav_search, Icons.Filled.Search),
    HOME(R.string.nav_home, Icons.Filled.Home),
    LIVE(R.string.nav_live, Icons.Filled.LiveTv),
    MOVIES(R.string.nav_movies, Icons.Filled.Movie),
    SERIES(R.string.nav_series, Icons.Filled.VideoLibrary),
    FAVORITES(R.string.nav_favorites, Icons.Filled.Favorite),
    SETTINGS(R.string.nav_settings, Icons.Filled.Settings),
}

/** Full-screen destinations stacked over the sections (detail, player, paywall, flows). */
sealed interface TvRoute {
    data object Player : TvRoute
    data object Paywall : TvRoute
    data class Detail(val kind: ContentKind, val id: String) : TvRoute
    data class Add(val type: String, val editId: String? = null) : TvRoute
    data object Pair : TvRoute
    data object Account : TvRoute
    data object FormatTest : TvRoute
    data object Guide : TvRoute
    data class Source(val id: String) : TvRoute
}

/** Navigation state shared by the TV screens. */
class TvNav {
    val stack = mutableStateListOf<TvRoute>()
    fun push(r: TvRoute) {
        stack.add(r)
    }

    fun pop(): Boolean = if (stack.isEmpty()) false else { stack.removeAt(stack.lastIndex); true }
    fun replace(r: TvRoute) {
        pop()
        push(r)
    }
}

/**
 * TV root: collapsible left menu (expands on focus) + content. Back-key rules (SCREENS §2):
 * detail/player → previous screen; content → focus moves to the menu; menu → Home, then exit.
 */
@OptIn(androidx.compose.ui.ExperimentalComposeUiApi::class)
@Composable
fun TvApp(graph: AppGraph) {
    val factory = remember { ViewModelFactory(graph) }
    val main: MainViewModel = viewModel(factory = factory)
    val sources by main.sources.collectAsState()
    val nav = remember { TvNav() }
    var section by rememberSaveable { mutableStateOf(TvSection.HOME) }
    var menuHasFocus by remember { mutableStateOf(false) }
    val menuFocus = remember { FocusRequester() }
    val contentFocus = remember { FocusRequester() }
    val selectedFocus = remember { FocusRequester() }
    val focusManager = androidx.compose.ui.platform.LocalFocusManager.current
    val activity = findActivity()

    Box(Modifier.fillMaxSize().background(Tokens.Bg)) {
        val list = sources ?: return@Box
        val top = nav.stack.lastOrNull()
        when {
            top != null -> {
                BackHandler(enabled = top != TvRoute.Player) { nav.pop() }
                TvRouteContent(top, factory, main, nav)
            }
            list.isEmpty() -> TvWelcome(main, nav)
            else -> {
                BackHandler {
                    when {
                        !menuHasFocus -> runCatching { selectedFocus.requestFocus() }
                        section != TvSection.HOME -> section = TvSection.HOME
                        else -> activity?.finish()
                    }
                }
                val drawer = rememberDrawerState(DrawerValue.Closed)
                NavigationDrawer(
                    drawerState = drawer,
                    drawerContent = { _ ->
                        // Entering the menu focuses the selected section (then the last focused item).
                        Column(
                            Modifier.fillMaxHeight().padding(vertical = Tokens.TvVertical, horizontal = 12.dp)
                                .onFocusChanged { menuHasFocus = it.hasFocus }
                                .focusRequester(menuFocus),
                        ) {
                            Spacer(Modifier.height(24.dp))
                            TvSection.entries.forEach { s ->
                                NavigationDrawerItem(
                                    modifier = if (section == s) Modifier.focusRequester(selectedFocus) else Modifier,
                                    selected = section == s,
                                    onClick = {
                                        section = s
                                        runCatching { contentFocus.requestFocus() }
                                    },
                                    leadingContent = { Icon(s.icon, contentDescription = null) },
                                ) { Text(stringResource(s.label)) }
                            }
                        }
                    },
                ) {
                    Box(
                        Modifier.fillMaxSize().padding(start = 8.dp).focusRequester(contentFocus)
                            .onPreviewKeyEvent { e ->
                                // ◀ out of the content enters the menu on the selected section.
                                if (e.type != KeyEventType.KeyDown || e.key != Key.DirectionLeft) return@onPreviewKeyEvent false
                                val moved = focusManager.moveFocus(FocusDirection.Left)
                                if (moved && menuHasFocus) runCatching { selectedFocus.requestFocus() }
                                moved
                            },
                    ) {
                        when (section) {
                            TvSection.SEARCH -> TvSearch(factory, nav)
                            TvSection.HOME -> TvHome(factory, main, nav)
                            TvSection.LIVE -> TvLive(factory, nav)
                            TvSection.MOVIES -> TvGrid(factory, nav, ContentKind.MOVIE)
                            TvSection.SERIES -> TvGrid(factory, nav, ContentKind.SERIES)
                            TvSection.FAVORITES -> TvFavorites(factory, nav)
                            TvSection.SETTINGS -> TvSettings(factory, main, nav)
                        }
                    }
                }
                LaunchedEffect(Unit) { runCatching { contentFocus.requestFocus() } }
            }
        }
    }
}

@Composable
private fun TvRouteContent(r: TvRoute, factory: ViewModelFactory, main: MainViewModel, nav: TvNav) {
    when (r) {
        TvRoute.Player -> PlayerScreen(
            vm = viewModel(factory = factory),
            tv = true,
            onExit = { nav.pop() },
            onLocked = { nav.replace(TvRoute.Paywall) },
            onChannelList = { nav.pop() },
        )
        TvRoute.Paywall -> TvPaywall(main, nav)
        is TvRoute.Detail -> TvDetail(factory, nav, r.kind, r.id)
        is TvRoute.Add -> Box(Modifier.padding(horizontal = Tokens.TvHorizontal, vertical = Tokens.TvVertical)) {
            AddSourceScreen(factory, r.type, r.editId, onBack = { nav.pop() }, onDone = { nav.stack.clear() })
        }
        TvRoute.Pair -> TvPairing(factory, nav)
        TvRoute.Account -> Box(Modifier.padding(horizontal = Tokens.TvHorizontal, vertical = Tokens.TvVertical)) {
            AccountScreen(factory, onBack = { nav.pop() }, tvDeviceLogin = true)
        }
        TvRoute.FormatTest -> Box(Modifier.padding(horizontal = Tokens.TvHorizontal, vertical = Tokens.TvVertical)) {
            FormatTestScreen(factory, onBack = { nav.pop() })
        }
        TvRoute.Guide -> TvGuide(factory, nav)
        is TvRoute.Source -> TvSourceDetail(factory, nav, r.id)
    }
}
