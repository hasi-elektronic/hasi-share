package io.iptvplayer.core.error

import io.iptvplayer.core.media.PlayerEngine

/** Actions offered on an error card (docs/SCREENS.md §4). */
public enum class ErrorAction { RETRY, EDIT, DELETE_SOURCE, REFRESH, BACK, CHANNEL_LIST }

/**
 * Platform-neutral description of an error message: keys of `spec/strings.json`
 * (Android: `R.string.<key>`), positional string arguments and the actions to show.
 *
 * @property hintKey optional extra line (e.g. `perr_format_apple_ts`).
 * @property rawBody free text body (only for [PlaybackError.Unknown]).
 */
public data class ErrorPresentation(
    val titleKey: String,
    val bodyKey: String?,
    val titleArgs: List<String> = emptyList(),
    val bodyArgs: List<String> = emptyList(),
    val hintKey: String? = null,
    val rawBody: String? = null,
    val actions: List<ErrorAction>,
)

/** Maps errors to [ErrorPresentation] (docs/SCREENS.md §4 table). */
public object ErrorPresentations {
    /**
     * Presentation of a source error; null for [SourceError.Cancelled] (show nothing).
     * [formatDate] formats an epoch-ms date for "expired on {0}".
     */
    public fun forSource(error: SourceError, formatDate: (Long) -> String): ErrorPresentation? = when (error) {
        is SourceError.Network -> when (error.reason) {
            NetworkReason.OFFLINE -> ErrorPresentation("err_offline_title", "err_offline_body", actions = listOf(ErrorAction.RETRY))
            NetworkReason.TIMEOUT -> unreachable("err_timeout_body")
            NetworkReason.DNS -> unreachable("err_dns_body")
            NetworkReason.REFUSED -> unreachable("err_refused_body")
            NetworkReason.TLS -> unreachable("err_tls_body")
            NetworkReason.OTHER -> unreachable("err_network_body")
        }
        SourceError.InvalidCredentials -> ErrorPresentation("err_credentials_title", "err_credentials_body", actions = listOf(ErrorAction.EDIT))
        is SourceError.AccountExpired -> {
            val date = error.expiresAtMs
            ErrorPresentation(
                titleKey = "err_expired_title",
                bodyKey = if (date != null) "err_expired_body" else "err_expired_body_nodate",
                bodyArgs = if (date != null) listOf(formatDate(date)) else emptyList(),
                actions = listOf(ErrorAction.EDIT, ErrorAction.DELETE_SOURCE),
            )
        }
        SourceError.AccountDisabled -> ErrorPresentation("err_disabled_title", "err_disabled_body", actions = listOf(ErrorAction.EDIT))
        SourceError.NotFound -> ErrorPresentation("err_notfound_title", "err_notfound_body", actions = listOf(ErrorAction.EDIT))
        is SourceError.ServerError -> ErrorPresentation(
            titleKey = "err_server_title",
            bodyKey = "err_server_body",
            titleArgs = listOf(error.httpStatus.toString()),
            actions = listOf(ErrorAction.RETRY),
        )
        SourceError.InvalidFormat -> ErrorPresentation("err_format_title", "err_format_body", actions = listOf(ErrorAction.EDIT))
        SourceError.InvalidResponse -> ErrorPresentation("err_response_title", "err_response_body", actions = listOf(ErrorAction.EDIT))
        SourceError.Empty -> ErrorPresentation("err_empty_title", "err_empty_body", actions = listOf(ErrorAction.REFRESH))
        SourceError.Cancelled -> null
    }

    private fun unreachable(body: String) =
        ErrorPresentation("err_unreachable_title", body, actions = listOf(ErrorAction.RETRY, ErrorAction.EDIT))

    /** Presentation of a playback error on [engine]. */
    public fun forPlayback(error: PlaybackError, engine: PlayerEngine): ErrorPresentation = when (error) {
        is PlaybackError.Network -> if (error.reason == NetworkReason.OFFLINE) {
            ErrorPresentation("err_offline_title", "err_offline_body", actions = listOf(ErrorAction.RETRY, ErrorAction.BACK))
        } else {
            ErrorPresentation("perr_network_title", "perr_network_body", actions = listOf(ErrorAction.RETRY, ErrorAction.CHANNEL_LIST, ErrorAction.BACK))
        }
        is PlaybackError.AccessDenied -> ErrorPresentation("perr_denied_title", "perr_denied_body", actions = listOf(ErrorAction.RETRY))
        is PlaybackError.StreamOffline -> ErrorPresentation("perr_offline_title", "perr_offline_body", actions = listOf(ErrorAction.RETRY, ErrorAction.CHANNEL_LIST))
        is PlaybackError.ServerError -> ErrorPresentation(
            titleKey = "err_server_title",
            bodyKey = "err_server_body",
            titleArgs = listOf(error.httpStatus.toString()),
            actions = listOf(ErrorAction.RETRY),
        )
        is PlaybackError.UnsupportedFormat -> ErrorPresentation(
            titleKey = "perr_format_title",
            bodyKey = "perr_format_body",
            bodyArgs = listOf(error.container),
            hintKey = if (engine == PlayerEngine.AVPLAYER && error.container == "mpegts") "perr_format_apple_ts" else null,
            actions = listOf(ErrorAction.BACK),
        )
        is PlaybackError.UnsupportedCodec -> ErrorPresentation("perr_codec_title", "perr_codec_body", actions = listOf(ErrorAction.BACK))
        PlaybackError.Drm -> ErrorPresentation("perr_drm_title", "perr_drm_body", actions = listOf(ErrorAction.BACK))
        is PlaybackError.Unknown -> ErrorPresentation(
            titleKey = "perr_unknown_title",
            bodyKey = null,
            rawBody = error.message,
            actions = listOf(ErrorAction.RETRY, ErrorAction.BACK),
        )
    }
}
