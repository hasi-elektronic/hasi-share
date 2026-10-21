package io.iptvplayer.shared.player

import io.iptvplayer.core.error.PlaybackError
import io.iptvplayer.core.model.ContentKind

/** Aspect ratio modes (SCREENS §3.7), remembered globally (ARCHITECTURE V16). */
enum class AspectMode { FIT, FILL, STRETCH, R16_9, R4_3 }

/**
 * Something the player can open. [url] may contain Xtream credentials: it lives only in memory
 * and is never logged or persisted ([toString] hides it).
 */
data class PlayableItem(
    val contentKey: String,
    val kind: ContentKind,
    val sourceId: String,
    val itemId: String,
    val title: String,
    val imageUrl: String? = null,
    val number: Int? = null,
    val url: String,
    val userAgent: String? = null,
    val referrer: String? = null,
    val drm: Boolean = false,
    val epgKey: String? = null,
    val categoryId: String? = null,
    val seriesKey: String? = null,
    val durationMs: Long? = null,
    val isCatchup: Boolean = false,
) {
    val isLive: Boolean get() = kind == ContentKind.LIVE && !isCatchup

    override fun toString(): String = "PlayableItem(kind=$kind, item=$itemId, title=$title, url=***)"
}

/** One selectable audio / subtitle track. [label] null → UI shows "Track n" ([index] + 1). */
data class TrackOption(
    val id: String,
    val label: String?,
    val language: String?,
    val index: Int,
    val selected: Boolean,
)

/** Player phase shown by the overlay. */
sealed interface PlayerPhase {
    data object Idle : PlayerPhase
    data object Loading : PlayerPhase
    data object Playing : PlayerPhase
    data object Paused : PlayerPhase
    data object Buffering : PlayerPhase
    data class Reconnecting(val attempt: Int, val maxAttempts: Int) : PlayerPhase
    data class Failed(val error: PlaybackError) : PlayerPhase
    data object Ended : PlayerPhase
}

data class PlayerState(
    val item: PlayableItem? = null,
    val phase: PlayerPhase = PlayerPhase.Idle,
    val positionMs: Long = 0,
    val durationMs: Long = 0,
    val audioTracks: List<TrackOption> = emptyList(),
    val textTracks: List<TrackOption> = emptyList(),
    val subtitlesOff: Boolean = true,
    val aspect: AspectMode = AspectMode.FIT,
    val resumedFromMs: Long? = null,
    val videoAspect: Float = 16f / 9f,
)
