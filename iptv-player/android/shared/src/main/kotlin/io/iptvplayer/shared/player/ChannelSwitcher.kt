package io.iptvplayer.shared.player

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch

/**
 * Channel zapping (SCREENS §3.7): every request shows the info card immediately ([pending]);
 * requests within [debounceMs] (400 ms) are coalesced – only the last channel is opened.
 */
class ChannelSwitcher<T : Any>(
    private val scope: CoroutineScope,
    private val debounceMs: Long = DEFAULT_DEBOUNCE_MS,
    private val onCommit: (T) -> Unit,
) {
    private val _pending = MutableStateFlow<T?>(null)

    /** Channel shown in the info card while the switch is pending (null = none). */
    val pending: StateFlow<T?> = _pending
    private var job: Job? = null

    fun request(item: T) {
        _pending.value = item
        job?.cancel()
        job = scope.launch {
            delay(debounceMs)
            _pending.value = null
            onCommit(item)
        }
    }

    fun cancel() {
        job?.cancel()
        _pending.value = null
    }

    companion object {
        const val DEFAULT_DEBOUNCE_MS = 400L
    }
}
