package io.iptvplayer.shared.vm

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import io.iptvplayer.core.model.ContentKind
import io.iptvplayer.core.model.EpgProgram
import io.iptvplayer.core.xmltv.EpgSchedule
import io.iptvplayer.core.xmltv.NowNext
import io.iptvplayer.shared.di.AppGraph
import io.iptvplayer.shared.player.ChannelSwitcher
import io.iptvplayer.shared.player.PlayableItem
import io.iptvplayer.shared.player.PlayerController
import io.iptvplayer.shared.player.PlayerState
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch

/** Info card shown immediately on a channel switch (SCREENS §3.7). */
data class ChannelInfo(val item: PlayableItem, val nowNext: NowNext? = null)

/**
 * Player screen: owns one [PlayerController] (one ExoPlayer reused across channel switches),
 * live zapping with the 400 ms [ChannelSwitcher], previous channel, number entry (TV),
 * favorites, license lock check.
 */
class PlayerViewModel(private val graph: AppGraph) : ViewModel() {
    val controller: PlayerController = graph.newPlayerController(viewModelScope)
    val state: StateFlow<PlayerState> = controller.state

    private var queue: List<String> = emptyList()
    private var previous: PlayableItem? = null
    private val _info = MutableStateFlow<ChannelInfo?>(null)
    val info: StateFlow<ChannelInfo?> = _info
    private val switcher = ChannelSwitcher<PlayableItem>(viewModelScope) { open(it) }
    val pendingSwitch = switcher.pending

    val isFavorite: StateFlow<Boolean> = combine(graph.library.favoriteKeys, controller.state) { keys, st ->
        st.item?.contentKey?.let { it in keys } ?: false
    }.stateIn(viewModelScope, SharingStarted.Eagerly, false)

    /** Locked → the UI shows the paywall instead (CONTRACT §7.4). */
    val locked: Boolean get() = !graph.license.state.value.canPlay

    /** Consumes the pending request from the list screen. Returns false when nothing to play. */
    fun start(): Boolean {
        val r = graph.playback.value ?: return state.value.item != null
        graph.playback.value = null
        queue = r.channelQueue
        controller.play(r.item, r.startPositionMs, r.resumeFromProgress)
        loadInfo(r.item)
        return true
    }

    private fun open(item: PlayableItem) {
        val cur = state.value.item
        if (cur != null && cur.contentKey != item.contentKey) previous = cur
        controller.play(item)
        loadInfo(item)
    }

    private fun loadInfo(item: PlayableItem) {
        _info.value = ChannelInfo(item)
        if (!item.isLive) return
        viewModelScope.launch {
            val key = item.epgKey ?: return@launch
            val now = graph.license.nowMs()
            val progs: List<EpgProgram> = graph.catalog.programmes(item.sourceId, key, now - 6 * 3_600_000L, now + 12 * 3_600_000L)
            if (_info.value?.item?.contentKey == item.contentKey) _info.value = ChannelInfo(item, EpgSchedule.nowAndNext(progs, now))
        }
    }

    /** ▲/▼, CH+/CH−, swipe: [delta] = +1 / −1 within the list the player was opened from. */
    fun zap(delta: Int) {
        val cur = pendingSwitch.value ?: state.value.item ?: return
        if (!cur.isLive || queue.isEmpty()) return
        val idx = queue.indexOf(cur.itemId)
        val next = queue[((if (idx < 0) 0 else idx + delta) % queue.size + queue.size) % queue.size]
        switchTo(cur.sourceId, next)
    }

    /** TV digit entry: jumps to the channel with [number] (1.5 s entry window handled by the UI). */
    fun jumpToNumber(number: Int) {
        val cur = state.value.item ?: return
        viewModelScope.launch {
            val c = graph.catalog.channelList(cur.sourceId, null).firstOrNull { it.number == number } ?: return@launch
            switchTo(cur.sourceId, c.id)
        }
    }

    fun previousChannel() {
        previous?.let { switcher.request(it) }
    }

    private fun switchTo(sourceId: String, channelId: String) = viewModelScope.launch {
        val src = graph.sources.get(sourceId) ?: return@launch
        val c = graph.catalog.channel(sourceId, channelId) ?: return@launch
        val item = runCatching { graph.catalog.playableChannel(src, c, graph.settingsState.value.liveFormat) }.getOrNull() ?: return@launch
        _info.value = ChannelInfo(item)
        switcher.request(item)
    }

    fun toggleFavorite() {
        val item = state.value.item ?: return
        viewModelScope.launch {
            val kind = if (item.kind == ContentKind.EPISODE) ContentKind.EPISODE else item.kind
            graph.library.toggleFavorite(item.contentKey, item.title, kind, item.imageUrl)
        }
    }

    override fun onCleared() {
        controller.stop()
    }
}
