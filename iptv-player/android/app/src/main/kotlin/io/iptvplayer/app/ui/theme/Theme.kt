package io.iptvplayer.app.ui.theme

import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Typography
import androidx.compose.material3.darkColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.tv.material3.darkColorScheme as tvDarkColorScheme
import androidx.tv.material3.MaterialTheme as TvMaterialTheme
import androidx.tv.material3.Typography as TvTypography

/** Visual tokens of SCREENS §1 (dark only). */
object Tokens {
    val Bg = Color(0xFF0B0D12)
    val Surface = Color(0xFF151922)
    val SurfaceElevated = Color(0xFF1E2430)
    val Primary = Color(0xFF5B8CFF)
    val PrimaryVariant = Color(0xFF7C5CFF)
    val TextPrimary = Color(0xFFF2F4F8)
    val TextSecondary = Color(0xFFA3ACBD)
    val Live = Color(0xFFFF4D5E)
    val Success = Color(0xFF2BD47D)
    val Warning = Color(0xFFFFB547)
    val Error = Color(0xFFFF5C5C)

    val CardRadius = 12.dp
    val PosterRadius = 10.dp
    val ButtonRadius = 24.dp

    /** TV overscan-safe margins. */
    val TvHorizontal = 48.dp
    val TvVertical = 27.dp

    val PremiumGradient = Brush.linearGradient(listOf(Primary, PrimaryVariant))
}

private val mobileColors = darkColorScheme(
    primary = Tokens.Primary,
    onPrimary = Color.White,
    secondary = Tokens.PrimaryVariant,
    background = Tokens.Bg,
    onBackground = Tokens.TextPrimary,
    surface = Tokens.Bg,
    onSurface = Tokens.TextPrimary,
    surfaceVariant = Tokens.Surface,
    onSurfaceVariant = Tokens.TextSecondary,
    surfaceContainer = Tokens.Surface,
    surfaceContainerHigh = Tokens.SurfaceElevated,
    surfaceContainerHighest = Tokens.SurfaceElevated,
    surfaceContainerLow = Tokens.Surface,
    error = Tokens.Error,
    outline = Tokens.TextSecondary,
)

@Composable
fun MobileTheme(content: @Composable () -> Unit) {
    val t = Typography()
    MaterialTheme(
        colorScheme = mobileColors,
        typography = t.copy(bodyLarge = t.bodyLarge.copy(fontSize = 16.sp), bodyMedium = t.bodyMedium.copy(fontSize = 15.sp)),
        content = content,
    )
}

/** TV: tv-material theme (body ≥ 18 sp, titles ≥ 28 sp) + Material 3 for shared form widgets. */
@Composable
fun TvTheme(content: @Composable () -> Unit) {
    val tvColors = tvDarkColorScheme(
        primary = Tokens.Primary,
        onPrimary = Color.White,
        secondary = Tokens.PrimaryVariant,
        background = Tokens.Bg,
        onBackground = Tokens.TextPrimary,
        surface = Tokens.Surface,
        onSurface = Tokens.TextPrimary,
        surfaceVariant = Tokens.SurfaceElevated,
        onSurfaceVariant = Tokens.TextSecondary,
        border = Tokens.Primary,
        error = Tokens.Error,
    )
    val base = TvTypography()
    val tvType = base.copy(
        bodyLarge = TextStyle(fontSize = 20.sp),
        bodyMedium = TextStyle(fontSize = 18.sp),
        bodySmall = TextStyle(fontSize = 16.sp),
        titleLarge = TextStyle(fontSize = 24.sp, fontWeight = FontWeight.SemiBold),
        titleMedium = TextStyle(fontSize = 20.sp, fontWeight = FontWeight.SemiBold),
        headlineMedium = TextStyle(fontSize = 28.sp, fontWeight = FontWeight.SemiBold),
        headlineLarge = TextStyle(fontSize = 34.sp, fontWeight = FontWeight.Bold),
    )
    val m3 = Typography()
    MaterialTheme(
        colorScheme = mobileColors,
        typography = m3.copy(bodyLarge = m3.bodyLarge.copy(fontSize = 20.sp), bodyMedium = m3.bodyMedium.copy(fontSize = 18.sp), labelLarge = m3.labelLarge.copy(fontSize = 18.sp)),
    ) {
        TvMaterialTheme(colorScheme = tvColors, typography = tvType) {
            // tv-material Text uses LocalContentColor; outside a tv Surface it would be black.
            androidx.compose.runtime.CompositionLocalProvider(
                androidx.tv.material3.LocalContentColor provides Tokens.TextPrimary,
                androidx.compose.material3.LocalContentColor provides Tokens.TextPrimary,
                content = content,
            )
        }
    }
}
