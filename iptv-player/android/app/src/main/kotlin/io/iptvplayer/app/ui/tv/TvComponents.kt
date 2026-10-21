package io.iptvplayer.app.ui.tv

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.ui.ExperimentalComposeUiApi
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.focusRestorer
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.tv.material3.Border
import androidx.tv.material3.Card
import androidx.tv.material3.CardDefaults
import androidx.tv.material3.MaterialTheme
import androidx.tv.material3.Text
import io.iptvplayer.app.ui.common.RemoteImage
import io.iptvplayer.app.ui.theme.Tokens

/** Focus style of SCREENS §1: 1.08× scale + 3 dp primary ring. */
@Composable
fun TvCard(onClick: () -> Unit, modifier: Modifier = Modifier, onLongClick: (() -> Unit)? = null, content: @Composable () -> Unit) {
    Card(
        onClick = onClick,
        onLongClick = onLongClick,
        modifier = modifier,
        shape = CardDefaults.shape(RoundedCornerShape(Tokens.CardRadius)),
        scale = CardDefaults.scale(focusedScale = 1.08f),
        border = CardDefaults.border(focusedBorder = Border(BorderStroke(3.dp, Tokens.Primary), shape = RoundedCornerShape(Tokens.CardRadius))),
        colors = CardDefaults.colors(containerColor = Tokens.Surface, focusedContainerColor = Tokens.SurfaceElevated),
    ) { content() }
}

@Composable
fun TvPoster(title: String, poster: String?, width: Dp = 150.dp, onClick: () -> Unit, onLongClick: (() -> Unit)? = null) {
    Column(Modifier.width(width)) {
        TvCard(onClick, Modifier.fillMaxWidth().aspectRatio(2f / 3f), onLongClick) {
            RemoteImage(poster, title, Modifier.fillMaxWidth().aspectRatio(2f / 3f))
        }
        Text(title, maxLines = 1, overflow = TextOverflow.Ellipsis, style = MaterialTheme.typography.bodySmall, modifier = Modifier.padding(top = 6.dp))
    }
}

@Composable
fun TvLogoCard(title: String, logo: String?, subtitle: String?, onClick: () -> Unit, onLongClick: (() -> Unit)? = null) {
    Column(Modifier.width(220.dp)) {
        TvCard(onClick, Modifier.fillMaxWidth().aspectRatio(16f / 9f), onLongClick) {
            RemoteImage(logo, title, Modifier.fillMaxWidth().aspectRatio(16f / 9f).padding(12.dp), fit = true)
        }
        Text(title, maxLines = 1, overflow = TextOverflow.Ellipsis, style = MaterialTheme.typography.bodyMedium, modifier = Modifier.padding(top = 6.dp))
        subtitle?.let { Text(it, maxLines = 1, overflow = TextOverflow.Ellipsis, style = MaterialTheme.typography.bodySmall, color = Tokens.TextSecondary) }
    }
}

/** Shelf with title; vertical moves between rows return to the last focused item (focus restorer). */
@OptIn(ExperimentalComposeUiApi::class)
@Composable
fun TvShelf(title: String, content: LazyListScope.() -> Unit) {
    Column(Modifier.padding(top = 20.dp)) {
        Text(title, style = MaterialTheme.typography.titleLarge, modifier = Modifier.padding(start = Tokens.TvHorizontal, bottom = 10.dp))
        LazyRow(
            modifier = Modifier.focusRestorer(),
            contentPadding = PaddingValues(horizontal = Tokens.TvHorizontal, vertical = 8.dp),
            horizontalArrangement = Arrangement.spacedBy(20.dp),
            content = content,
        )
    }
}
