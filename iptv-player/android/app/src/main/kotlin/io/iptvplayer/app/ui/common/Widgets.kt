package io.iptvplayer.app.ui.common

import android.graphics.Bitmap
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Button
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.painter.ColorPainter
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import coil3.compose.AsyncImage
import com.google.zxing.BarcodeFormat
import com.google.zxing.EncodeHintType
import com.google.zxing.qrcode.QRCodeWriter
import io.iptvplayer.app.ui.theme.Tokens
import io.iptvplayer.core.error.ErrorAction

/** Poster / logo image (2:3 posters, logos `fit` on `surface`). */
@Composable
fun RemoteImage(url: String?, contentDescription: String?, modifier: Modifier = Modifier, fit: Boolean = false) {
    AsyncImage(
        model = url,
        contentDescription = contentDescription,
        modifier = modifier.background(Tokens.Surface),
        contentScale = if (fit) ContentScale.Fit else ContentScale.Crop,
        placeholder = ColorPainter(Tokens.Surface),
        error = ColorPainter(Tokens.SurfaceElevated),
    )
}

/** QR code bitmap (ZXing core – ARCHITECTURE §2). */
fun qrBitmap(text: String, size: Int = 512): ImageBitmap {
    val m = QRCodeWriter().encode(text, BarcodeFormat.QR_CODE, size, size, mapOf(EncodeHintType.MARGIN to 1))
    val pixels = IntArray(size * size) { i -> if (m[i % size, i / size]) 0xFF000000.toInt() else 0xFFFFFFFF.toInt() }
    return Bitmap.createBitmap(pixels, size, size, Bitmap.Config.ARGB_8888).asImageBitmap()
}

@Composable
fun QrCode(text: String, size: Dp, modifier: Modifier = Modifier) {
    val bmp = remember(text) { qrBitmap(text) }
    Image(bmp, contentDescription = text, modifier = modifier.size(size).clip(RoundedCornerShape(8.dp)))
}

/** Error card with separate actions (SCREENS §4). The first action gets the initial focus (TV ★). */
@Composable
fun ErrorCard(
    text: ErrorText,
    onAction: (ErrorAction) -> Unit,
    modifier: Modifier = Modifier,
    focusFirst: Boolean = false,
) {
    val fr = remember { FocusRequester() }
    Column(
        modifier.widthIn(max = 520.dp).clip(RoundedCornerShape(Tokens.CardRadius)).background(Tokens.SurfaceElevated).padding(24.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Text(text.title, color = Tokens.TextPrimary, fontSize = 20.sp, fontWeight = FontWeight.SemiBold, textAlign = TextAlign.Center)
        text.body?.let {
            Spacer(Modifier.height(8.dp))
            Text(it, color = Tokens.TextSecondary, textAlign = TextAlign.Center)
        }
        text.hint?.let {
            Spacer(Modifier.height(8.dp))
            Text(it, color = Tokens.Warning, textAlign = TextAlign.Center)
        }
        Spacer(Modifier.height(16.dp))
        Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            text.actions.forEachIndexed { i, a ->
                if (i == 0) {
                    Button(onClick = { onAction(a) }, modifier = Modifier.focusRequester(fr)) { Text(actionLabel(a)) }
                } else {
                    OutlinedButton(onClick = { onAction(a) }) { Text(actionLabel(a)) }
                }
            }
        }
    }
    if (focusFirst && text.actions.isNotEmpty()) {
        androidx.compose.runtime.LaunchedEffect(Unit) { runCatching { fr.requestFocus() } }
    }
}

@Composable
fun CenterBox(content: @Composable () -> Unit) {
    Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) { content() }
}

/** Observes ON_START / ON_STOP of the hosting lifecycle (player release, SCREENS §3.7). */
@Composable
fun LifecycleStartStop(onStart: () -> Unit, onStop: () -> Unit) {
    val owner = LocalLifecycleOwner.current
    val start = rememberUpdatedState(onStart)
    val stop = rememberUpdatedState(onStop)
    DisposableEffect(owner) {
        val obs = LifecycleEventObserver { _, e ->
            when (e) {
                Lifecycle.Event.ON_START -> start.value()
                Lifecycle.Event.ON_STOP -> stop.value()
                else -> Unit
            }
        }
        owner.lifecycle.addObserver(obs)
        onDispose { owner.lifecycle.removeObserver(obs) }
    }
}

/** Keeps the screen on while composed (player). */
@Composable
fun KeepScreenOn() {
    val view = androidx.compose.ui.platform.LocalView.current
    DisposableEffect(view) {
        view.keepScreenOn = true
        onDispose { view.keepScreenOn = false }
    }
}

@Composable
fun findActivity(): android.app.Activity? {
    var c = LocalContext.current
    while (c is android.content.ContextWrapper) {
        if (c is android.app.Activity) return c
        c = c.baseContext
    }
    return null
}
