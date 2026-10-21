package io.iptvplayer.app.ui.mobile

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Favorite
import androidx.compose.material.icons.filled.Home
import androidx.compose.material.icons.filled.LiveTv
import androidx.compose.material.icons.filled.Movie
import androidx.compose.material.icons.filled.VideoLibrary
import androidx.compose.material3.Icon
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.NavigationBarItemDefaults
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.res.stringResource
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.navigation.NavHostController
import androidx.navigation.NavType
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.currentBackStackEntryAsState
import androidx.navigation.compose.rememberNavController
import androidx.navigation.navArgument
import io.iptvplayer.app.ui.common.PlayerScreen
import io.iptvplayer.app.ui.theme.Tokens
import io.iptvplayer.core.model.ContentKind
import io.iptvplayer.shared.R
import io.iptvplayer.shared.di.AppGraph
import io.iptvplayer.shared.vm.MainViewModel
import io.iptvplayer.shared.vm.ViewModelFactory

/** Routes of the phone UI. */
object Routes {
    const val SPLASH = "splash"
    const val WELCOME = "welcome"
    const val ADD = "add/{type}?edit={edit}"
    fun add(type: String, edit: String? = null) = "add/$type" + (edit?.let { "?edit=$it" } ?: "")
    const val HOME = "home"
    const val LIVE = "live"
    const val MOVIES = "movies"
    const val SERIES = "series"
    const val FAVORITES = "favorites"
    const val SEARCH = "search"
    const val SETTINGS = "settings"
    const val SOURCE = "source/{id}"
    fun source(id: String) = "source/$id"
    const val ACCOUNT = "account"
    const val PAYWALL = "paywall"
    const val PLAYER = "player"
    const val MOVIE = "movie/{id}"
    fun movie(id: String) = "movie/$id"
    const val SHOW = "show/{id}"
    fun show(id: String) = "show/$id"
    const val GUIDE = "guide"
    const val FORMAT_TEST = "formattest"
    const val PAIR_SEND = "pairsend"

    val tabs = listOf(HOME, LIVE, MOVIES, SERIES, FAVORITES)
}

private data class Tab(val route: String, val label: Int, val icon: ImageVector)

private val tabs = listOf(
    Tab(Routes.HOME, R.string.nav_home, Icons.Filled.Home),
    Tab(Routes.LIVE, R.string.nav_live, Icons.Filled.LiveTv),
    Tab(Routes.MOVIES, R.string.nav_movies, Icons.Filled.Movie),
    Tab(Routes.SERIES, R.string.nav_series, Icons.Filled.VideoLibrary),
    Tab(Routes.FAVORITES, R.string.nav_favorites, Icons.Filled.Favorite),
)

/** Phone navigation: bottom bar with 5 tabs; welcome flow when no source exists (SCREENS §2). */
@Composable
fun MobileApp(graph: AppGraph) {
    val factory = remember { ViewModelFactory(graph) }
    val main: MainViewModel = viewModel(factory = factory)
    val nav = rememberNavController()
    val sources by main.sources.collectAsState()
    val entry by nav.currentBackStackEntryAsState()
    val route = entry?.destination?.route

    LaunchedEffect(sources == null, sources?.isEmpty()) {
        val list = sources ?: return@LaunchedEffect
        val cur = nav.currentDestination?.route
        if (list.isEmpty() && cur != Routes.WELCOME && cur?.startsWith("add") != true) {
            nav.navigate(Routes.WELCOME) { popUpTo(0) { inclusive = true } }
        } else if (list.isNotEmpty() && (cur == Routes.SPLASH || cur == Routes.WELCOME)) {
            nav.navigate(Routes.HOME) { popUpTo(0) { inclusive = true } }
        }
    }

    Scaffold(
        containerColor = Tokens.Bg,
        bottomBar = {
            if (route in Routes.tabs) {
                NavigationBar(containerColor = Tokens.Surface) {
                    tabs.forEach { t ->
                        NavigationBarItem(
                            selected = route == t.route,
                            onClick = { nav.switchTab(t.route) },
                            icon = { Icon(t.icon, contentDescription = null) },
                            label = { Text(stringResource(t.label)) },
                            colors = NavigationBarItemDefaults.colors(
                                selectedIconColor = Tokens.Primary,
                                selectedTextColor = Tokens.Primary,
                                indicatorColor = Tokens.SurfaceElevated,
                                unselectedIconColor = Tokens.TextSecondary,
                                unselectedTextColor = Tokens.TextSecondary,
                            ),
                        )
                    }
                }
            }
        },
    ) { pad ->
        Box(Modifier.fillMaxSize().padding(if (route == Routes.PLAYER) androidx.compose.foundation.layout.PaddingValues() else pad)) {
            NavHost(nav, startDestination = Routes.SPLASH) {
                composable(Routes.SPLASH) { Box(Modifier.fillMaxSize()) }
                composable(Routes.WELCOME) { WelcomeScreen(main, onAdd = { nav.navigate(Routes.add(it)) }, onPaywall = { nav.navigate(Routes.PAYWALL) }) }
                composable(
                    Routes.ADD,
                    arguments = listOf(navArgument("type") { type = NavType.StringType }, navArgument("edit") { type = NavType.StringType; nullable = true }),
                ) { e ->
                    AddSourceScreen(
                        factory = factory,
                        type = e.arguments?.getString("type") ?: "m3u",
                        editId = e.arguments?.getString("edit"),
                        onBack = { nav.popBackStack() },
                        onDone = {
                            if (!nav.popBackStack(Routes.SETTINGS, inclusive = false)) nav.navigate(Routes.HOME) { popUpTo(0) { inclusive = true } }
                        },
                    )
                }
                composable(Routes.HOME) { HomeScreen(factory, main, nav) }
                composable(Routes.LIVE) { LiveScreen(factory, main, nav) }
                composable(Routes.MOVIES) { VodScreen(factory, main, nav, ContentKind.MOVIE) }
                composable(Routes.SERIES) { VodScreen(factory, main, nav, ContentKind.SERIES) }
                composable(Routes.FAVORITES) { FavoritesScreen(factory, main, nav) }
                composable(Routes.SEARCH) { SearchScreen(factory, nav) }
                composable(Routes.GUIDE) { GuideScreen(factory, nav) }
                composable(Routes.MOVIE, arguments = listOf(navArgument("id") { type = NavType.StringType })) { e ->
                    DetailScreen(factory, nav, ContentKind.MOVIE, e.arguments?.getString("id").orEmpty())
                }
                composable(Routes.SHOW, arguments = listOf(navArgument("id") { type = NavType.StringType })) { e ->
                    DetailScreen(factory, nav, ContentKind.SERIES, e.arguments?.getString("id").orEmpty())
                }
                composable(Routes.PLAYER) {
                    PlayerScreen(
                        vm = viewModel(factory = factory),
                        tv = false,
                        onExit = { nav.popBackStack() },
                        onLocked = { nav.navigate(Routes.PAYWALL) { popUpTo(Routes.PLAYER) { inclusive = true } } },
                        onChannelList = { nav.popBackStack() },
                    )
                }
                composable(Routes.PAYWALL) { PaywallScreen(main, onBack = { nav.popBackStack() }, onAccount = { nav.navigate(Routes.ACCOUNT) }) }
                composable(Routes.SETTINGS) { SettingsScreen(factory, main, nav) }
                composable(Routes.SOURCE, arguments = listOf(navArgument("id") { type = NavType.StringType })) { e ->
                    SourceDetailScreen(factory, nav, e.arguments?.getString("id").orEmpty())
                }
                composable(Routes.ACCOUNT) { AccountScreen(factory, onBack = { nav.popBackStack() }) }
                composable(Routes.FORMAT_TEST) { FormatTestScreen(factory, onBack = { nav.popBackStack() }) }
            }
        }
    }
}

fun NavHostController.switchTab(route: String) = navigate(route) {
    popUpTo(Routes.HOME) { saveState = true }
    launchSingleTop = true
    restoreState = true
}
