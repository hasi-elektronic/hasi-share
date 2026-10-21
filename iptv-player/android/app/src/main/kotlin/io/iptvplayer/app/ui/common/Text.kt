package io.iptvplayer.app.ui.common

import android.annotation.SuppressLint
import android.content.Context
import android.text.format.DateFormat
import androidx.compose.runtime.Composable
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import io.iptvplayer.core.error.ErrorAction
import io.iptvplayer.core.error.ErrorPresentation
import io.iptvplayer.core.error.ErrorPresentations
import io.iptvplayer.core.error.PlaybackError
import io.iptvplayer.core.error.SourceError
import io.iptvplayer.core.license.AccessState
import io.iptvplayer.core.media.PlayerEngine
import io.iptvplayer.shared.R
import io.iptvplayer.shared.license.LicenseState
import io.iptvplayer.shared.repo.RefreshProgress
import java.text.DateFormat as JDateFormat
import java.util.Date
import java.util.Locale
import java.util.concurrent.TimeUnit

/** Resolves a `spec/strings.json` key (used by core's [ErrorPresentation]) to the Android string. */
@SuppressLint("DiscouragedApi")
fun Context.stringByKey(key: String, vararg args: Any): String {
    val id = resources.getIdentifier(key, "string", packageName)
    return if (id == 0) key else getString(id, *args)
}

data class ErrorText(val title: String, val body: String?, val hint: String?, val actions: List<ErrorAction>)

fun Context.errorText(p: ErrorPresentation): ErrorText = ErrorText(
    title = stringByKey(p.titleKey, *p.titleArgs.toTypedArray()),
    body = p.bodyKey?.let { stringByKey(it, *p.bodyArgs.toTypedArray()) } ?: p.rawBody,
    hint = p.hintKey?.let { stringByKey(it) },
    actions = p.actions,
)

fun Context.sourceErrorText(e: SourceError): ErrorText? =
    ErrorPresentations.forSource(e) { formatDate(it) }?.let { errorText(it) }

fun Context.playbackErrorText(e: PlaybackError): ErrorText = errorText(ErrorPresentations.forPlayback(e, PlayerEngine.MEDIA3))

fun Context.formatDate(ms: Long): String = JDateFormat.getDateInstance(JDateFormat.MEDIUM, Locale.getDefault()).format(Date(ms))

fun Context.formatDateTime(ms: Long): String =
    JDateFormat.getDateTimeInstance(JDateFormat.MEDIUM, JDateFormat.SHORT, Locale.getDefault()).format(Date(ms))

/** HH:mm in 24 h (TR default) or the system format (SCREENS §3.3). */
fun Context.formatTime(ms: Long, use24h: Boolean = true): String =
    if (use24h) java.text.SimpleDateFormat("HH:mm", Locale.getDefault()).format(Date(ms)) else DateFormat.getTimeFormat(this).format(Date(ms))

fun formatDuration(ms: Long): String {
    val s = TimeUnit.MILLISECONDS.toSeconds(ms.coerceAtLeast(0))
    val h = s / 3600
    val m = (s % 3600) / 60
    val sec = s % 60
    return if (h > 0) "%d:%02d:%02d".format(h, m, sec) else "%02d:%02d".format(m, sec)
}

@Composable
fun actionLabel(a: ErrorAction): String = stringResource(
    when (a) {
        ErrorAction.RETRY -> R.string.action_retry
        ErrorAction.EDIT -> R.string.action_edit
        ErrorAction.DELETE_SOURCE -> R.string.action_delete
        ErrorAction.REFRESH -> R.string.action_refresh
        ErrorAction.BACK -> R.string.action_back
        ErrorAction.CHANNEL_LIST -> R.string.action_channel_list
    },
)

@Composable
fun progressLabel(p: RefreshProgress): String = when (p) {
    RefreshProgress.Connecting -> stringResource(R.string.progress_connecting)
    RefreshProgress.VerifyingAccount -> stringResource(R.string.progress_auth)
    is RefreshProgress.Channels -> stringResource(R.string.progress_channels, "%,d".format(p.count))
    is RefreshProgress.Movies -> stringResource(R.string.progress_movies, "%,d".format(p.count))
    is RefreshProgress.Series -> stringResource(R.string.progress_series, "%,d".format(p.count))
    RefreshProgress.Epg -> stringResource(R.string.progress_epg)
}

/** Trial chip text ("Trial: 5 days left" / "Trial ended" / null when purchased / not started). */
@Composable
fun trialChip(l: LicenseState): String? = when (l.decision.state) {
    AccessState.TRIAL_ACTIVE -> {
        val days = TimeUnit.MILLISECONDS.toDays(l.trialRemainingMs).toInt()
        if (days >= 1) pluralStringResource(R.plurals.trial_chip_days, days, days)
        else stringResource(R.string.trial_chip_hours, TimeUnit.MILLISECONDS.toHours(l.trialRemainingMs).coerceAtLeast(1).toString())
    }
    AccessState.TRIAL_EXPIRED -> stringResource(R.string.trial_chip_expired)
    else -> null
}

/** "3 days 4 h" style remaining time for the paywall status card. */
fun remainingText(ms: Long): String {
    val d = TimeUnit.MILLISECONDS.toDays(ms)
    val h = TimeUnit.MILLISECONDS.toHours(ms) % 24
    val m = TimeUnit.MILLISECONDS.toMinutes(ms) % 60
    return when {
        d > 0 -> "${d}d ${h}h"
        h > 0 -> "${h}h ${m}m"
        else -> "${m}m"
    }
}

/** Track label: language name or "Track n". */
@Composable
fun trackLabel(label: String?, index: Int): String = label ?: stringResource(R.string.unknown_track, (index + 1).toString())

@Composable
fun ctx(): Context = LocalContext.current
