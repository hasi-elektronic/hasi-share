package io.iptvplayer.shared.vm

import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import io.iptvplayer.core.model.ContentKind
import io.iptvplayer.shared.di.AppGraph

/** Creates the shared ViewModels from the [AppGraph] (manual DI). */
class ViewModelFactory(private val graph: AppGraph) : ViewModelProvider.Factory {
    @Suppress("UNCHECKED_CAST")
    override fun <T : ViewModel> create(modelClass: Class<T>): T = when (modelClass) {
        MainViewModel::class.java -> MainViewModel(graph)
        AddSourceViewModel::class.java -> AddSourceViewModel(graph)
        HomeViewModel::class.java -> HomeViewModel(graph)
        LiveViewModel::class.java -> LiveViewModel(graph)
        MoviesViewModel::class.java -> MoviesViewModel(graph)
        SeriesViewModel::class.java -> SeriesViewModel(graph)
        DetailViewModel::class.java -> DetailViewModel(graph)
        FavoritesViewModel::class.java -> FavoritesViewModel(graph)
        SearchViewModel::class.java -> SearchViewModel(graph)
        PlayerViewModel::class.java -> PlayerViewModel(graph)
        SettingsViewModel::class.java -> SettingsViewModel(graph)
        AccountViewModel::class.java -> AccountViewModel(graph)
        PairingViewModel::class.java -> PairingViewModel(graph)
        FormatTestViewModel::class.java -> FormatTestViewModel(graph)
        else -> error("unknown ViewModel $modelClass")
    } as T
}

/** Movies grid. */
class MoviesViewModel(graph: AppGraph) : VodViewModelBase(graph, ContentKind.MOVIE)

/** Series grid. */
class SeriesViewModel(graph: AppGraph) : VodViewModelBase(graph, ContentKind.SERIES)
