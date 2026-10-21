package io.iptvplayer.app.ui.common

import android.view.KeyEvent as AndroidKeyEvent
import androidx.activity.compose.BackHandler
import androidx.annotation.OptIn
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.focusable
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.gestures.detectVerticalDragGestures
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.filled.List
import androidx.compose.material.icons.filled.AspectRatio
import androidx.compose.material.icons.filled.Audiotrack
import androidx.compose.material.icons.filled.Favorite
import androidx.compose.material.icons.filled.FavoriteBorder
import androidx.compose.material.icons.filled.History
import androidx.compose.material.icons.filled.Pause
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.Subtitles
import androidx.compose.material3.AssistChip
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.Slider
import androidx.compose.material3.SliderDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.key.KeyEventType
import androidx.compose.ui.input.key.nativeKeyCode
import androidx.compose.ui.input.key.key
import androidx.compose.ui.input.key.onPreviewKeyEvent
import androidx.compose.ui.input.key.type
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.media3.common.util.UnstableApi
import androidx.media3.ui.AspectRatioFrameLayout
import androidx.media3.ui.PlayerView
import io.iptvplayer.app.ui.theme.Tokens
import io.iptvplayer.core.error.ErrorAction
import io.iptvplayer.core.xmltv.EpgSchedule
import io.iptvplayer.shared.R
import io.iptvplayer.shared.player.AspectMode
import io.iptvplayer.shared.player.PlayerPhase
import io.iptvplayer.shared.vm.PlayerViewModel
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

private enum class Panel { NONE, AUDIO, SUBTITLES, ASPECT }

/**
 * Full-screen player with overlay (SCREENS §3.7) – shared by phone and TV. Phone: tap toggles
 * the overlay, vertical swipe switches channels. TV: D-pad ▲▼ / CH± switch channels, ◀▶ seek
 * ±10 s (VOD), OK shows the overlay / pauses, digits jump to a channel number, MENU = favorite.
 * Back closes an open panel first, then leaves the player.
 */
@OptIn(UnstableApi::class)
@Composable
fun PlayerScreen(vm: PlayerViewModel, tv: Boolean, onExit: () -> Unit, onLocked: () -> Unit, onChannelList: () -> Unit) {
    val state by vm.state.collectAsState()
    val info by vm.info.collectAsState()
    val pending by vm.pendingSwitch.collectAsState()
    val fav by vm.isFavorite.collectAsState()
    val player by vm.controller.player.collectAsState()
    val ctx = LocalContext.current
    val scope = rememberCoroutineScope()

    var overlay by remember { mutableStateOf(true) }
    var panel by remember { mutableStateOf(Panel.NONE) }
    var interaction by remember { mutableIntStateOf(0) }
    var digits by remember { mutableStateOf("") }
    var digitJob by remember { mutableStateOf<Job?>(null) }
    val rootFocus = remember { FocusRequester() }

    LaunchedEffect(Unit) {
        if (vm.locked) {
            onLocked()
            return@LaunchedEffect
        }
        if (!vm.start()) onExit()
    }
    // Overlay disappears after 3 s without interaction (not while a panel/error is shown).
    LaunchedEffect(overlay, interaction, panel, state.phase) {
        if (overlay && panel == Panel.NONE && state.phase is PlayerPhase.Playing) {
            delay(3_000)
            overlay = false
        }
    }
    LaunchedEffect(overlay) { if (!overlay && tv) runCatching { rootFocus.requestFocus() } }
    LaunchedEffect(Unit) { runCatching { rootFocus.requestFocus() } }
    LifecycleStartStop(onStart = { vm.controller.onStart() }, onStop = { vm.controller.onStop() })
    KeepScreenOn()
    HideSystemBars()

    BackHandler {
        when {
            panel != Panel.NONE -> panel = Panel.NONE
            else -> {
                vm.controller.stop()
                onExit()
            }
        }
    }

    fun poke() {
        overlay = true
        interaction++
    }

    val item = state.item
    Box(
        Modifier
            .fillMaxSize()
            .background(Color.Black)
            .focusRequester(rootFocus)
            .focusable()
            .onPreviewKeyEvent { e ->
                if (!tv || e.type != KeyEventType.KeyDown) return@onPreviewKeyEvent false
                val code = e.key.nativeKeyCode
                val live = item?.isLive == true
                when {
                    code in AndroidKeyEvent.KEYCODE_0..AndroidKeyEvent.KEYCODE_9 && live -> {
                        digits = (digits + (code - AndroidKeyEvent.KEYCODE_0)).takeLast(4)
                        digitJob?.cancel()
                        digitJob = scope.launch {
                            delay(1_500)
                            digits.toIntOrNull()?.let { vm.jumpToNumber(it) }
                            digits = ""
                        }
                        true
                    }
                    code == AndroidKeyEvent.KEYCODE_CHANNEL_UP -> { vm.zap(-1); true }
                    code == AndroidKeyEvent.KEYCODE_CHANNEL_DOWN -> { vm.zap(+1); true }
                    code == AndroidKeyEvent.KEYCODE_MENU -> { vm.toggleFavorite(); poke(); true }
                    code == AndroidKeyEvent.KEYCODE_MEDIA_PLAY_PAUSE -> { vm.controller.togglePlayPause(); poke(); true }
                    overlay || panel != Panel.NONE -> { interaction++; false }
                    code == AndroidKeyEvent.KEYCODE_DPAD_UP && live -> { vm.zap(-1); true }
                    code == AndroidKeyEvent.KEYCODE_DPAD_DOWN && live -> { vm.zap(+1); true }
                    code == AndroidKeyEvent.KEYCODE_DPAD_LEFT && !live -> { vm.controller.seekBy(-10_000); poke(); true }
                    code == AndroidKeyEvent.KEYCODE_DPAD_RIGHT && !live -> { vm.controller.seekBy(10_000); poke(); true }
                    code == AndroidKeyEvent.KEYCODE_DPAD_CENTER || code == AndroidKeyEvent.KEYCODE_ENTER -> {
                        if (!live && state.phase is PlayerPhase.Playing) vm.controller.togglePlayPause()
                        poke()
                        true
                    }
                    else -> false
                }
            }
            .pointerInput(tv) {
                if (!tv) detectTapGestures(onTap = { if (overlay) overlay = false else poke() })
            }
            .pointerInput(tv, item?.isLive) {
                if (!tv && item?.isLive == true) {
                    var total = 0f
                    detectVerticalDragGestures(
                        onDragStart = { total = 0f },
                        onDragEnd = {
                            if (total < -120) vm.zap(+1) else if (total > 120) vm.zap(-1)
                        },
                    ) { _, d -> total += d }
                }
            },
    ) {
        // ---------------------------------------------------------------- video surface
        val ratio = when (state.aspect) {
            AspectMode.R16_9 -> 16f / 9f
            AspectMode.R4_3 -> 4f / 3f
            else -> null
        }
        Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
            AndroidView(
                factory = { c -> PlayerView(c).apply { useController = false; setKeepContentOnPlayerReset(true) } },
                update = { v ->
                    v.player = player
                    v.resizeMode = when (state.aspect) {
                        AspectMode.FIT -> AspectRatioFrameLayout.RESIZE_MODE_FIT
                        AspectMode.FILL -> AspectRatioFrameLayout.RESIZE_MODE_ZOOM
                        AspectMode.STRETCH, AspectMode.R16_9, AspectMode.R4_3 -> AspectRatioFrameLayout.RESIZE_MODE_FILL
                    }
                },
                modifier = if (ratio != null) Modifier.fillMaxSize().aspectRatio(ratio) else Modifier.fillMaxSize(),
            )
        }

        // ---------------------------------------------------------------- center states
        when (val ph = state.phase) {
            PlayerPhase.Loading, PlayerPhase.Buffering -> if (pending == null) {
                Box(Modifier.align(Alignment.Center)) { CircularProgressIndicator(color = Tokens.Primary) }
            }
            is PlayerPhase.Reconnecting -> Column(Modifier.align(Alignment.Center), horizontalAlignment = Alignment.CenterHorizontally) {
                CircularProgressIndicator(color = Tokens.Warning)
                Spacer(Modifier.height(12.dp))
                Text(stringResource(R.string.player_reconnecting, ph.attempt.toString(), ph.maxAttempts.toString()), color = Tokens.TextPrimary)
            }
            is PlayerPhase.Failed -> Box(Modifier.align(Alignment.Center)) {
                ErrorCard(ctx.playbackErrorText(ph.error), focusFirst = true, onAction = { a ->
                    when (a) {
                        ErrorAction.RETRY -> vm.controller.retry()
                        ErrorAction.CHANNEL_LIST -> { vm.controller.stop(); onChannelList() }
                        else -> { vm.controller.stop(); onExit() }
                    }
                })
            }
            else -> Unit
        }

        // ---------------------------------------------------------------- zap info card (< 100 ms)
        val card = pending ?: if (digits.isNotEmpty()) null else info?.item?.takeIf { overlay && it.isLive }
        if (pending != null || digits.isNotEmpty()) {
            Row(
                Modifier.align(Alignment.TopCenter).padding(top = 32.dp).clip(RoundedCornerShape(Tokens.CardRadius))
                    .background(Tokens.SurfaceElevated.copy(alpha = 0.95f)).padding(20.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                if (digits.isNotEmpty()) {
                    Text(digits, color = Tokens.TextPrimary, fontSize = 40.sp, fontWeight = FontWeight.Bold)
                } else if (card != null) {
                    card.number?.let { Text("$it", color = Tokens.Primary, fontSize = 34.sp, fontWeight = FontWeight.Bold) }
                    Spacer(Modifier.width(16.dp))
                    RemoteImage(card.imageUrl, null, Modifier.size(96.dp, 54.dp).clip(RoundedCornerShape(8.dp)), fit = true)
                    Spacer(Modifier.width(16.dp))
                    Column {
                        Text(card.title, color = Tokens.TextPrimary, fontSize = 22.sp, fontWeight = FontWeight.SemiBold)
                        info?.nowNext?.now?.takeIf { info?.item?.contentKey == card.contentKey }?.let { Text(it.title, color = Tokens.TextSecondary) }
                    }
                    Spacer(Modifier.width(16.dp))
                    CircularProgressIndicator(Modifier.size(24.dp), strokeWidth = 2.dp)
                }
            }
        }

        // ---------------------------------------------------------------- overlay
        if (overlay && item != null && state.phase !is PlayerPhase.Failed) {
            Column(Modifier.fillMaxSize().background(Color.Black.copy(alpha = 0.35f))) {
                Row(Modifier.fillMaxWidth().padding(if (tv) 32.dp else 12.dp), verticalAlignment = Alignment.CenterVertically) {
                    if (!tv) {
                        IconButton(onClick = { vm.controller.stop(); onExit() }) {
                            Icon(Icons.AutoMirrored.Filled.ArrowBack, stringResource(R.string.action_back), tint = Tokens.TextPrimary)
                        }
                    }
                    item.number?.let { Text("$it  ", color = Tokens.Primary, fontSize = 22.sp, fontWeight = FontWeight.Bold) }
                    Text(item.title, color = Tokens.TextPrimary, fontSize = 20.sp, fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f))
                    if (item.isLive) LiveBadge()
                }
                Spacer(Modifier.weight(1f))
                if (state.resumedFromMs != null) {
                    var visible by remember(state.resumedFromMs) { mutableStateOf(true) }
                    LaunchedEffect(state.resumedFromMs) {
                        delay(5_000)
                        visible = false
                    }
                    if (visible) {
                        AssistChip(
                            onClick = { vm.controller.seekTo(0); visible = false },
                            label = { Text(stringResource(R.string.action_play_from_start)) },
                            modifier = Modifier.padding(horizontal = 24.dp),
                        )
                    }
                }
                Column(Modifier.fillMaxWidth().padding(horizontal = if (tv) 48.dp else 16.dp, vertical = if (tv) 27.dp else 12.dp)) {
                    if (item.isLive) {
                        val nn = info?.nowNext
                        nn?.now?.let { p ->
                            Text(p.title, color = Tokens.TextPrimary, fontWeight = FontWeight.SemiBold)
                            LinearProgressIndicator(
                                progress = { EpgSchedule.progress(p, System.currentTimeMillis()).toFloat() },
                                modifier = Modifier.fillMaxWidth().padding(vertical = 6.dp),
                                color = Tokens.Live,
                                trackColor = Tokens.Surface,
                            )
                        }
                        nn?.next?.let { Text(stringResource(R.string.epg_next) + ": " + ctx.formatTime(it.startMs) + " " + it.title, color = Tokens.TextSecondary) }
                    } else if (state.durationMs > 0) {
                        Slider(
                            value = state.positionMs.toFloat().coerceIn(0f, state.durationMs.toFloat()),
                            onValueChange = { vm.controller.seekTo(it.toLong()); poke() },
                            valueRange = 0f..state.durationMs.toFloat(),
                            colors = SliderDefaults.colors(thumbColor = Tokens.Primary, activeTrackColor = Tokens.Primary),
                        )
                        Text("${formatDuration(state.positionMs)} / ${formatDuration(state.durationMs)}", color = Tokens.TextSecondary)
                    }
                    Row(horizontalArrangement = Arrangement.spacedBy(4.dp), verticalAlignment = Alignment.CenterVertically) {
                        if (!item.isLive) {
                            IconButton(onClick = { vm.controller.togglePlayPause(); poke() }) {
                                val playing = state.phase is PlayerPhase.Playing
                                Icon(if (playing) Icons.Filled.Pause else Icons.Filled.PlayArrow, stringResource(R.string.action_play), tint = Tokens.TextPrimary)
                            }
                        }
                        IconButton(onClick = { panel = Panel.AUDIO; poke() }) { Icon(Icons.Filled.Audiotrack, stringResource(R.string.player_audio), tint = Tokens.TextPrimary) }
                        IconButton(onClick = { panel = Panel.SUBTITLES; poke() }) { Icon(Icons.Filled.Subtitles, stringResource(R.string.player_subtitles), tint = Tokens.TextPrimary) }
                        IconButton(onClick = { panel = Panel.ASPECT; poke() }) { Icon(Icons.Filled.AspectRatio, stringResource(R.string.player_aspect), tint = Tokens.TextPrimary) }
                        if (item.isLive) {
                            IconButton(onClick = { vm.controller.stop(); onChannelList() }) { Icon(Icons.AutoMirrored.Filled.List, stringResource(R.string.action_channel_list), tint = Tokens.TextPrimary) }
                            IconButton(onClick = { vm.previousChannel(); poke() }) { Icon(Icons.Filled.History, stringResource(R.string.player_previous_channel), tint = Tokens.TextPrimary) }
                        }
                        IconButton(onClick = { vm.toggleFavorite(); poke() }) {
                            Icon(
                                if (fav) Icons.Filled.Favorite else Icons.Filled.FavoriteBorder,
                                stringResource(if (fav) R.string.action_remove_favorite else R.string.action_add_favorite),
                                tint = if (fav) Tokens.Live else Tokens.TextPrimary,
                            )
                        }
                    }
                }
            }
        }

        // ---------------------------------------------------------------- selection panels
        if (panel != Panel.NONE) {
            val options: List<Pair<String, Boolean>>
            val onPick: (Int) -> Unit
            when (panel) {
                Panel.AUDIO -> {
                    options = state.audioTracks.map { trackLabel(it.label, it.index) to it.selected }
                    onPick = { i -> vm.controller.selectAudio(state.audioTracks[i].id) }
                }
                Panel.SUBTITLES -> {
                    options = listOf(stringResource(R.string.off) to state.subtitlesOff) + state.textTracks.map { trackLabel(it.label, it.index) to it.selected }
                    onPick = { i -> vm.controller.selectSubtitle(if (i == 0) null else state.textTracks[i - 1].id) }
                }
                else -> {
                    val modes = AspectMode.entries
                    options = modes.map { aspectLabel(it) to (it == state.aspect) }
                    onPick = { i -> vm.controller.setAspect(modes[i]) }
                }
            }
            SelectionPanel(
                title = stringResource(
                    when (panel) {
                        Panel.AUDIO -> R.string.player_audio
                        Panel.SUBTITLES -> R.string.player_subtitles
                        else -> R.string.player_aspect
                    },
                ),
                options = options,
                onPick = { onPick(it); panel = Panel.NONE },
                onClose = { panel = Panel.NONE },
                modifier = Modifier.align(Alignment.CenterEnd),
            )
        }
    }
}

@Composable
fun aspectLabel(m: AspectMode): String = stringResource(
    when (m) {
        AspectMode.FIT -> R.string.aspect_fit
        AspectMode.FILL -> R.string.aspect_fill
        AspectMode.STRETCH -> R.string.aspect_stretch
        AspectMode.R16_9 -> R.string.aspect_16_9
        AspectMode.R4_3 -> R.string.aspect_4_3
    },
)

@Composable
fun LiveBadge(modifier: Modifier = Modifier) {
    Text(
        stringResource(R.string.live_badge),
        color = Color.White,
        fontSize = 12.sp,
        fontWeight = FontWeight.Bold,
        modifier = modifier.clip(RoundedCornerShape(4.dp)).background(Tokens.Live).padding(horizontal = 6.dp, vertical = 2.dp),
    )
}

@Composable
private fun SelectionPanel(title: String, options: List<Pair<String, Boolean>>, onPick: (Int) -> Unit, onClose: () -> Unit, modifier: Modifier) {
    val first = remember { FocusRequester() }
    Column(
        modifier.padding(24.dp).widthIn(min = 260.dp, max = 360.dp).clip(RoundedCornerShape(Tokens.CardRadius))
            .background(Tokens.SurfaceElevated).padding(16.dp),
    ) {
        Text(title, color = Tokens.TextPrimary, fontWeight = FontWeight.SemiBold, fontSize = 18.sp)
        Spacer(Modifier.height(8.dp))
        LazyColumn {
            itemsIndexed(options) { i, (label, selected) ->
                TextButton(
                    onClick = { onPick(i) },
                    modifier = Modifier.fillMaxWidth().then(if (i == 0) Modifier.focusRequester(first) else Modifier),
                ) {
                    Text((if (selected) "✓  " else "    ") + label, color = if (selected) Tokens.Primary else Tokens.TextPrimary, modifier = Modifier.fillMaxWidth())
                }
            }
        }
        TextButton(onClick = onClose) { Text(stringResource(R.string.action_close)) }
    }
    LaunchedEffect(Unit) { runCatching { first.requestFocus() } }
}

/** Hides status/navigation bars while the player is shown. */
@Composable
fun HideSystemBars() {
    val activity = findActivity() ?: return
    androidx.compose.runtime.DisposableEffect(activity) {
        val c = androidx.core.view.WindowCompat.getInsetsController(activity.window, activity.window.decorView)
        c.systemBarsBehavior = androidx.core.view.WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
        c.hide(androidx.core.view.WindowInsetsCompat.Type.systemBars())
        onDispose { c.show(androidx.core.view.WindowInsetsCompat.Type.systemBars()) }
    }
}

@Suppress("unused")
private val noRipple = MutableInteractionSource()

@Suppress("unused")
private fun Modifier.noop() = this.clickable(enabled = false) {}
