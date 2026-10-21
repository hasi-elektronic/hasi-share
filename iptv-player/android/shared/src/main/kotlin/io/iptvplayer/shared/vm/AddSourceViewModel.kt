package io.iptvplayer.shared.vm

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import io.iptvplayer.core.error.SourceError
import io.iptvplayer.core.model.Source
import io.iptvplayer.core.model.SourceSecrets
import io.iptvplayer.core.model.SourceStatus
import io.iptvplayer.core.pairing.PairPayload
import io.iptvplayer.core.util.UrlNormalizer
import io.iptvplayer.shared.di.AppGraph
import io.iptvplayer.shared.repo.RefreshOutcome
import io.iptvplayer.shared.repo.RefreshProgress
import io.iptvplayer.shared.work.RefreshWorker
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch

sealed interface AddSourceState {
    data object Idle : AddSourceState
    data class Running(val progress: RefreshProgress) : AddSourceState
    data class Success(val source: Source, val status: SourceStatus) : AddSourceState
    data class Failure(val error: SourceError) : AddSourceState
}

/** Form validation (SCREENS §3.1: "Save" only enabled while the form is valid). */
object SourceFormValidation {
    fun isHttpUrl(s: String): Boolean = UrlNormalizer.isHttpUrl(s.trim())
    fun optionalUrl(s: String): Boolean = s.isBlank() || isHttpUrl(s)
    fun m3uValid(url: String, epg: String) = isHttpUrl(url) && optionalUrl(epg)
    fun xtreamValid(server: String, user: String, pass: String): Boolean {
        val t = server.trim()
        if (t.isEmpty() || user.isBlank() || pass.isEmpty()) return false
        return isHttpUrl(if ("://" in t) t else "http://$t")
    }
}

/** Add / edit a source (M3U, Xtream, or a payload received via TV pairing). */
class AddSourceViewModel(private val graph: AppGraph) : ViewModel() {
    private val _state = MutableStateFlow<AddSourceState>(AddSourceState.Idle)
    val state: StateFlow<AddSourceState> = _state
    private var job: Job? = null

    /** Editing: existing values (secrets decrypted only for the form). */
    fun existingSecrets(sourceId: String): SourceSecrets? = graph.sources.secrets(sourceId)

    fun addM3u(name: String, url: String, epgUrl: String, userAgent: String, editSourceId: String? = null) =
        submit(name, SourceSecrets.M3u(url.trim(), epgUrl.trim().ifEmpty { null }, userAgent.trim().ifEmpty { null }), editSourceId)

    fun addXtream(name: String, server: String, username: String, password: String, editSourceId: String? = null) =
        submit(name, SourceSecrets.Xtream(server.trim(), username.trim(), password), editSourceId)

    fun addPayload(p: PairPayload) = submit(p.name, p.secrets, null)

    private fun submit(name: String, secrets: SourceSecrets, editSourceId: String?) {
        job?.cancel()
        job = viewModelScope.launch {
            _state.value = AddSourceState.Running(RefreshProgress.Connecting)
            val onProgress: (RefreshProgress) -> Unit = { _state.value = AddSourceState.Running(it) }
            val outcome = if (editSourceId != null) {
                graph.sources.updateSecrets(editSourceId, name, secrets, onProgress)
            } else {
                graph.sources.add(name, secrets, onProgress)
            }
            _state.value = when (outcome) {
                is RefreshOutcome.Success -> {
                    graph.settings.update { it.copy(selectedSourceId = outcome.source.id) }
                    RefreshWorker.importEpgNow(graph.context, outcome.source.id)
                    AddSourceState.Success(outcome.source, outcome.status)
                }
                is RefreshOutcome.Failure -> if (outcome.error == SourceError.Cancelled) AddSourceState.Idle else AddSourceState.Failure(outcome.error)
            }
        }
    }

    fun cancel() {
        job?.cancel()
        _state.value = AddSourceState.Idle
    }

    fun reset() {
        _state.value = AddSourceState.Idle
    }
}
