package io.iptvplayer.shared.vm

import android.app.Activity
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import io.iptvplayer.core.model.Source
import io.iptvplayer.shared.account.AccountState
import io.iptvplayer.shared.billing.BillingSnapshot
import io.iptvplayer.shared.billing.PurchaseEvent
import io.iptvplayer.shared.di.AppGraph
import io.iptvplayer.shared.license.LicenseState
import io.iptvplayer.shared.license.TrialStartResult
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch

/** App-wide state shared by every screen: sources, selected source, license, purchase, account. */
class MainViewModel(private val graph: AppGraph) : ViewModel() {
    /** null = not loaded yet. */
    val sources: StateFlow<List<Source>?> = graph.sources.sources.stateIn(viewModelScope, SharingStarted.Eagerly, null)

    val selectedSource: StateFlow<Source?> = combine(graph.sources.sources, graph.settings.settings) { list, s ->
        list.firstOrNull { it.id == s.selectedSourceId } ?: list.firstOrNull()
    }.stateIn(viewModelScope, SharingStarted.Eagerly, null)

    val license: StateFlow<LicenseState> = graph.license.state
    val billing: StateFlow<BillingSnapshot> = graph.billing.state
    val account: StateFlow<AccountState> = graph.accounts.state
    val purchaseEvents: SharedFlow<PurchaseEvent> = graph.billing.events

    private val _trialResult = MutableSharedFlow<TrialStartResult>(extraBufferCapacity = 2)
    val trialResult: SharedFlow<TrialStartResult> = _trialResult
    private val _busy = MutableStateFlow(false)
    val busy: StateFlow<Boolean> = _busy

    val isTv: Boolean get() = graph.isTv
    val appName: String get() = graph.config.appName

    fun selectSource(id: String) = viewModelScope.launch { graph.settings.update { it.copy(selectedSourceId = id) } }

    fun startTrial() = viewModelScope.launch {
        _busy.value = true
        _trialResult.emit(graph.license.startTrial())
        _busy.value = false
    }

    fun buy(activity: Activity) = graph.billing.launchPurchase(activity)

    fun restore() = viewModelScope.launch {
        _busy.value = true
        graph.billing.refreshPurchases(userInitiated = true)
        graph.license.sync()
        _busy.value = false
    }
}
