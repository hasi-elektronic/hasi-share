package io.iptvplayer.shared.player

import android.content.Context
import android.os.SystemClock
import androidx.annotation.MainThread
import androidx.annotation.OptIn
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.MimeTypes
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.common.TrackSelectionOverride
import androidx.media3.common.Tracks
import androidx.media3.common.VideoSize
import androidx.media3.common.util.UnstableApi
import androidx.media3.datasource.HttpDataSource
import androidx.media3.datasource.okhttp.OkHttpDataSource
import androidx.media3.exoplayer.DefaultLoadControl
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.source.DefaultMediaSourceFactory
import io.iptvplayer.core.error.ConnectivityProbe
import io.iptvplayer.core.error.PlaybackError
import io.iptvplayer.core.media.Container
import io.iptvplayer.core.media.PlatformSupport
import io.iptvplayer.core.media.PlayerEngine
import io.iptvplayer.core.media.StreamFormatDetector
import io.iptvplayer.core.net.HttpDefaults
import io.iptvplayer.core.retry.ReconnectDecision
import io.iptvplayer.core.retry.ReconnectPolicy
import io.iptvplayer.core.sync.WatchHistory
import io.iptvplayer.shared.log.SafeLog
import io.iptvplayer.shared.repo.LibraryRepository
import io.iptvplayer.shared.settings.AppSettings
import io.iptvplayer.shared.settings.BufferMode
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import okhttp3.OkHttpClient
import java.util.Locale

/**
 * Media3 player wrapper (ARCHITECTURE §3.2). Responsibilities:
 * * pre-check: DRM flag → [PlaybackError.Drm]; container support (CONTRACT §6) before preparing;
 * * one ExoPlayer instance reused for channel switches;
 * * reconnect with [ReconnectPolicy] (1-2-4-8-15 s, 5 attempts, reset after 30 s stable);
 *   "behind live window" jumps silently to the live edge;
 * * audio/subtitle selection, preferred languages from settings, aspect mode;
 * * progress saved every 10 s for VOD and on pause/stop;
 * * [onStop] releases the player (lifecycle ON_STOP), [onStart] restores it.
 *
 * All methods must be called on the main thread.
 */
@OptIn(UnstableApi::class)
class PlayerController(
    private val context: Context,
    private val okHttp: OkHttpClient,
    private val library: LibraryRepository,
    private val scope: CoroutineScope,
    private val connectivity: ConnectivityProbe,
    private val settingsProvider: () -> AppSettings,
    private val onAspectChanged: (AspectMode) -> Unit = {},
) {
    private val _state = MutableStateFlow(PlayerState(aspect = settingsProvider().aspect))
    val state: StateFlow<PlayerState> = _state

    /** The underlying player (for PlayerView); null while released. */
    private val _player = MutableStateFlow<ExoPlayer?>(null)
    val player: StateFlow<ExoPlayer?> = _player

    private val reconnect = ReconnectPolicy()
    private var reconnectJob: Job? = null
    private var tickerJob: Job? = null
    private var container: Container = Container.UNKNOWN
    private var stoppedPositionMs: Long? = null
    private var lastSavedAt = 0L

    private val listener = object : Player.Listener {
        override fun onPlaybackStateChanged(playbackState: Int) = syncPhase()
        override fun onIsPlayingChanged(isPlaying: Boolean) {
            syncPhase()
            if (!isPlaying) saveProgress()
        }
        override fun onTracksChanged(tracks: Tracks) = updateTracks(tracks)
        override fun onVideoSizeChanged(videoSize: VideoSize) {
            if (videoSize.width > 0 && videoSize.height > 0) {
                _state.update { it.copy(videoAspect = videoSize.width * videoSize.pixelWidthHeightRatio / videoSize.height) }
            }
        }
        override fun onPlayerError(error: PlaybackException) = handleError(error)
    }

    // --------------------------------------------------------------------------- public API

    /** Opens [item]; [startPositionMs] resumes VOD (null = from saved progress / live edge). */
    @MainThread
    fun play(item: PlayableItem, startPositionMs: Long? = null, resumeFromProgress: Boolean = true) {
        saveProgress()
        reconnect.reset()
        reconnectJob?.cancel()
        _state.update { it.copy(item = item, phase = PlayerPhase.Loading, positionMs = 0, durationMs = 0, audioTracks = emptyList(), textTracks = emptyList(), resumedFromMs = null) }
        // Pre-checks (CONTRACT §6, V12).
        if (item.drm) return fail(PlaybackError.Drm)
        container = StreamFormatDetector.detect(item.url)
        PlatformSupport.check(container, PlayerEngine.MEDIA3)?.let { return fail(it) }
        if (startPositionMs == null && resumeFromProgress && !item.isLive) {
            scope.launch {
                val p = library.progress(item.contentKey)
                val pos = p?.positionMs?.takeIf { p.durationMs != null && !WatchHistory.isCompleted(it, p.durationMs) && it > 5_000 }
                if (_state.value.item?.contentKey == item.contentKey) {
                    if (pos != null) _state.update { it.copy(resumedFromMs = pos) }
                    prepare(item, pos)
                }
            }
        } else {
            prepare(item, startPositionMs)
        }
    }

    @MainThread
    fun retry() {
        val item = _state.value.item ?: return
        play(item, startPositionMs = if (item.isLive) null else _state.value.positionMs.takeIf { it > 0 }, resumeFromProgress = false)
    }

    @MainThread
    fun togglePlayPause() {
        val p = _player.value ?: return
        if (p.isPlaying) p.pause() else p.play()
    }

    @MainThread
    fun seekBy(deltaMs: Long) {
        val p = _player.value ?: return
        if (_state.value.item?.isLive == true) return
        p.seekTo((p.currentPosition + deltaMs).coerceIn(0, maxOf(0, p.duration)))
    }

    @MainThread
    fun seekTo(positionMs: Long) {
        _player.value?.seekTo(positionMs)
        _state.update { it.copy(resumedFromMs = null) }
    }

    @MainThread
    fun setAspect(mode: AspectMode) {
        _state.update { it.copy(aspect = mode) }
        onAspectChanged(mode)
    }

    @MainThread
    fun selectAudio(id: String) = selectTrack(C.TRACK_TYPE_AUDIO, id)

    /** [id] null = subtitles off. */
    @MainThread
    fun selectSubtitle(id: String?) {
        val p = _player.value ?: return
        if (id == null) {
            p.trackSelectionParameters = p.trackSelectionParameters.buildUpon().setTrackTypeDisabled(C.TRACK_TYPE_TEXT, true).build()
        } else {
            p.trackSelectionParameters = p.trackSelectionParameters.buildUpon().setTrackTypeDisabled(C.TRACK_TYPE_TEXT, false).build()
            selectTrack(C.TRACK_TYPE_TEXT, id)
        }
    }

    /** Lifecycle ON_STOP: save the position and release decoders / network (SCREENS §3.7). */
    @MainThread
    fun onStop() {
        val p = _player.value ?: return
        stoppedPositionMs = if (_state.value.item?.isLive == true) null else p.currentPosition
        saveProgress()
        releasePlayer()
    }

    /** Lifecycle ON_START: re-open the last item where it stopped. */
    @MainThread
    fun onStart() {
        if (_player.value != null) return
        val item = _state.value.item ?: return
        if (_state.value.phase is PlayerPhase.Failed) return
        prepare(item, stoppedPositionMs)
    }

    /** Leaves the player screen. */
    @MainThread
    fun stop() {
        saveProgress()
        releasePlayer()
        _state.value = PlayerState(aspect = _state.value.aspect)
    }

    // --------------------------------------------------------------------------- internals

    private fun ensurePlayer(): ExoPlayer {
        _player.value?.let { return it }
        val s = settingsProvider()
        val load = if (s.buffer == BufferMode.LARGE) {
            DefaultLoadControl.Builder().setBufferDurationsMs(30_000, 120_000, 2_500, 5_000).build()
        } else {
            // Low start buffer for fast live zapping (ARCHITECTURE §7).
            DefaultLoadControl.Builder().setBufferDurationsMs(15_000, 50_000, 1_000, 2_000).build()
        }
        val p = ExoPlayer.Builder(context).setLoadControl(load).build()
        p.trackSelectionParameters = p.trackSelectionParameters.buildUpon()
            .apply { if (s.audioLanguage.isNotEmpty()) setPreferredAudioLanguage(s.audioLanguage) }
            .apply {
                if (s.subtitleLanguage.isNotEmpty()) setPreferredTextLanguage(s.subtitleLanguage)
                else setTrackTypeDisabled(C.TRACK_TYPE_TEXT, true)
            }
            .build()
        p.addListener(listener)
        _player.value = p
        startTicker()
        return p
    }

    private fun prepare(item: PlayableItem, positionMs: Long?) {
        val p = ensurePlayer()
        val factory = OkHttpDataSource.Factory(okHttp)
            .setUserAgent(item.userAgent ?: HttpDefaults.USER_AGENT)
            .apply { item.referrer?.let { setDefaultRequestProperties(mapOf("Referer" to it)) } }
        val mime = when (container) {
            Container.HLS -> MimeTypes.APPLICATION_M3U8
            Container.DASH -> MimeTypes.APPLICATION_MPD
            Container.RTSP -> MimeTypes.APPLICATION_RTSP
            Container.MPEGTS -> MimeTypes.VIDEO_MP2T
            else -> null
        }
        val mediaItem = MediaItem.Builder().setUri(item.url).apply { mime?.let { setMimeType(it) } }.build()
        val source = DefaultMediaSourceFactory(factory).createMediaSource(mediaItem)
        p.setMediaSource(source, positionMs ?: C.TIME_UNSET)
        p.prepare()
        p.playWhenReady = true
        SafeLog.d(TAG, "prepare ${item.kind.wire} ${container.wire} pos=$positionMs")
    }

    private fun fail(error: PlaybackError) {
        reconnectJob?.cancel()
        _player.value?.stop()
        _state.update { it.copy(phase = PlayerPhase.Failed(error)) }
        SafeLog.w(TAG, "playback failed: ${error.code}")
    }

    private fun handleError(e: PlaybackException) {
        val http = generateSequence<Throwable>(e) { it.cause }.filterIsInstance<HttpDataSource.InvalidResponseCodeException>().firstOrNull()?.responseCode
        val mapped = PlaybackErrorMapper.map(e.errorCode, http, connectivity.isOffline(), container, e.message)
        SafeLog.w(TAG, "player error ${e.errorCodeName} -> ${mapped.error.code}")
        val p = _player.value ?: return
        if (mapped.behindLiveWindow) {
            p.seekToDefaultPosition()
            p.prepare()
            return
        }
        if (!mapped.recoverable) return fail(mapped.error)
        when (val d = reconnect.onError(SystemClock.elapsedRealtime())) {
            is ReconnectDecision.GiveUp -> fail(mapped.error)
            is ReconnectDecision.Retry -> {
                _state.update { it.copy(phase = PlayerPhase.Reconnecting(d.attempt, d.maxAttempts)) }
                reconnectJob?.cancel()
                reconnectJob = scope.launch {
                    delay(d.delayMs)
                    val pl = _player.value ?: return@launch
                    if (_state.value.item?.isLive == true) pl.seekToDefaultPosition()
                    pl.prepare()
                    pl.playWhenReady = true
                }
            }
        }
    }

    private fun syncPhase() {
        val p = _player.value ?: return
        val cur = _state.value.phase
        if (cur is PlayerPhase.Failed) return
        val phase = when (p.playbackState) {
            Player.STATE_BUFFERING -> if (cur is PlayerPhase.Reconnecting) cur else PlayerPhase.Buffering
            Player.STATE_READY -> if (p.playWhenReady) PlayerPhase.Playing else PlayerPhase.Paused
            Player.STATE_ENDED -> PlayerPhase.Ended
            else -> if (cur is PlayerPhase.Reconnecting) cur else PlayerPhase.Loading
        }
        if (phase == PlayerPhase.Playing) reconnect.onPlaying(SystemClock.elapsedRealtime())
        if (phase == PlayerPhase.Ended) saveProgress()
        _state.update { it.copy(phase = phase) }
    }

    private fun updateTracks(tracks: Tracks) {
        fun options(type: Int): List<TrackOption> {
            val out = ArrayList<TrackOption>()
            tracks.groups.forEachIndexed { gi, g ->
                if (g.type != type) return@forEachIndexed
                for (ti in 0 until g.length) {
                    if (!g.isTrackSupported(ti)) continue
                    val f = g.getTrackFormat(ti)
                    val lang = f.language?.takeUnless { it == C.LANGUAGE_UNDETERMINED || it.isBlank() }
                    val label = f.label ?: lang?.let { Locale.forLanguageTag(it).getDisplayLanguage(Locale.getDefault()).takeIf { n -> n.isNotBlank() } }
                    out += TrackOption("$gi:$ti", label?.replaceFirstChar { it.titlecase(Locale.getDefault()) }, lang, out.size, g.isTrackSelected(ti))
                }
            }
            return out
        }
        val text = options(C.TRACK_TYPE_TEXT)
        _state.update { it.copy(audioTracks = options(C.TRACK_TYPE_AUDIO), textTracks = text, subtitlesOff = text.none { t -> t.selected }) }
    }

    private fun selectTrack(type: Int, id: String) {
        val p = _player.value ?: return
        val (gi, ti) = id.split(':').map { it.toInt() }
        val group = p.currentTracks.groups.getOrNull(gi) ?: return
        if (group.type != type) return
        p.trackSelectionParameters = p.trackSelectionParameters.buildUpon()
            .setOverrideForType(TrackSelectionOverride(group.mediaTrackGroup, ti))
            .build()
    }

    private fun startTicker() {
        tickerJob?.cancel()
        tickerJob = scope.launch {
            while (isActive) {
                val p = _player.value ?: break
                _state.update { it.copy(positionMs = p.currentPosition.coerceAtLeast(0), durationMs = p.duration.takeIf { d -> d > 0 } ?: 0) }
                reconnect.onTick(SystemClock.elapsedRealtime())
                if (p.isPlaying && SystemClock.elapsedRealtime() - lastSavedAt >= PROGRESS_INTERVAL_MS) saveProgress()
                delay(500)
            }
        }
    }

    /** Saves VOD progress (and records live channels as "recently watched"). */
    private fun saveProgress() {
        val item = _state.value.item ?: return
        val p = _player.value ?: return
        val pos = p.currentPosition
        val dur = p.duration.takeIf { it > 0 } ?: item.durationMs ?: 0
        if (!item.isLive && (dur <= 0 || pos <= 0)) return
        if (item.isCatchup) return
        lastSavedAt = SystemClock.elapsedRealtime()
        scope.launch {
            library.saveProgress(item.contentKey, item.title, item.kind, if (item.isLive) 0 else pos, if (item.isLive) 0 else dur, item.imageUrl, item.seriesKey)
        }
    }

    private fun releasePlayer() {
        tickerJob?.cancel()
        reconnectJob?.cancel()
        _player.value?.let {
            it.removeListener(listener)
            it.release()
        }
        _player.value = null
    }

    companion object {
        private const val TAG = "Player"
        const val PROGRESS_INTERVAL_MS = 10_000L
    }
}
