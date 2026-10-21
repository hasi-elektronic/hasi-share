package io.iptvplayer.shared.vm

import android.content.res.AssetManager
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import io.iptvplayer.core.model.Source
import io.iptvplayer.shared.account.AccountState
import io.iptvplayer.shared.db.SourceEntity
import io.iptvplayer.shared.di.AppGraph
import io.iptvplayer.shared.pairing.PairingState
import io.iptvplayer.shared.player.FormatResult
import io.iptvplayer.shared.player.StreamSample
import io.iptvplayer.shared.repo.RefreshOutcome
import io.iptvplayer.shared.settings.AppSettings
import io.iptvplayer.shared.sync.SyncStatus
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/** Settings & source management (SCREENS §3.9). */
class SettingsViewModel(private val graph: AppGraph) : ViewModel() {
    val settings: StateFlow<AppSettings> = graph.settingsState
    val sources: StateFlow<List<Source>> = graph.sources.sources.stateIn(viewModelScope, SharingStarted.Eagerly, emptyList())
    private val _refreshing = MutableStateFlow<Set<String>>(emptySet())
    val refreshing: StateFlow<Set<String>> = _refreshing
    private val _lastResult = MutableStateFlow<RefreshOutcome?>(null)
    val lastResult: StateFlow<RefreshOutcome?> = _lastResult

    val versionName: String get() = graph.config.versionName
    val versionCode: Int get() = graph.config.versionCode

    fun update(transform: (AppSettings) -> AppSettings) = viewModelScope.launch { graph.settings.update(transform) }

    fun refresh(id: String) = viewModelScope.launch {
        _refreshing.update { it + id }
        _lastResult.value = graph.sources.refresh(id)
        graph.sources.importEpg(id)
        _refreshing.update { it - id }
    }

    fun delete(id: String) = viewModelScope.launch {
        graph.sources.delete(id)
        if (graph.settingsState.value.selectedSourceId == id) graph.settings.update { it.copy(selectedSourceId = null) }
    }

    fun updateSource(id: String, transform: (SourceEntity) -> SourceEntity) = viewModelScope.launch {
        graph.sources.update(id, transform)
    }

    fun clearEpg() = viewModelScope.launch { graph.db.catalog().clearEpg() }
}

/** Account screen (SCREENS §3.9 "Account"). */
class AccountViewModel(private val graph: AppGraph) : ViewModel() {
    val state: StateFlow<AccountState> = graph.accounts.state
    val sync: StateFlow<SyncStatus> = graph.sync.status
    val backendAvailable: Boolean get() = graph.backend != null
    val showDevCode: Boolean get() = graph.config.debug

    fun sendCode(email: String, locale: String) = viewModelScope.launch { graph.accounts.startEmail(email, locale) }
    fun verify(code: String) = viewModelScope.launch { graph.accounts.verifyCode(code) }
    fun resetEmail() = graph.accounts.resetEmailFlow()
    fun startDeviceLogin() = graph.accounts.startDeviceLogin()
    fun cancelDeviceLogin() = graph.accounts.cancelDeviceLogin()
    fun signOut() = viewModelScope.launch { graph.accounts.signOut() }
    fun delete() = viewModelScope.launch { graph.accounts.deleteAccount() }
    fun syncNow() = viewModelScope.launch { graph.sync.syncNow() }
}

/** TV QR pairing (SCREENS §3.1). */
class PairingViewModel(private val graph: AppGraph) : ViewModel() {
    val state: StateFlow<PairingState> = graph.pairing.state
    fun start() = graph.pairing.start()
    fun cancel() = graph.pairing.cancel()
    override fun onCleared() = graph.pairing.cancel()
}

data class FormatRow(val sample: StreamSample, val result: FormatResult)

/** Diagnostics → format test (`stream-samples.json`, STREAM_COMPATIBILITY §3.2). */
class FormatTestViewModel(private val graph: AppGraph) : ViewModel() {
    private val _rows = MutableStateFlow<List<FormatRow>>(emptyList())
    val rows: StateFlow<List<FormatRow>> = _rows
    private val _running = MutableStateFlow(false)
    val running: StateFlow<Boolean> = _running

    fun load(assets: AssetManager) = viewModelScope.launch {
        if (_rows.value.isNotEmpty()) return@launch
        val json = withContext(Dispatchers.IO) { assets.open("stream-samples.json").bufferedReader().use { it.readText() } }
        _rows.value = graph.formatProber.parse(json).map { FormatRow(it, FormatResult.Pending) }
    }

    /** Runs every sample sequentially; [lanHost] for the local samples (e.g. 10.0.2.2). */
    fun runAll(lanHost: String?) = viewModelScope.launch {
        if (_running.value) return@launch
        _running.value = true
        for (i in _rows.value.indices) {
            _rows.update { l -> l.toMutableList().also { it[i] = it[i].copy(result = FormatResult.Running) } }
            val r = graph.formatProber.probe(_rows.value[i].sample, lanHost)
            _rows.update { l -> l.toMutableList().also { it[i] = it[i].copy(result = r) } }
        }
        _running.value = false
    }
}
