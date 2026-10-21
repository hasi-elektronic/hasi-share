package io.iptvplayer.shared.player

import io.iptvplayer.core.error.NetworkReason
import io.iptvplayer.core.error.PlaybackError
import io.iptvplayer.core.media.Container

/**
 * Maps Media3 `PlaybackException.errorCode`s to the cross-platform [PlaybackError] taxonomy
 * (CONTRACT §2, SCREENS §4). Pure – the codes are passed as ints so it is JVM-testable.
 *
 * The constants mirror `androidx.media3.common.PlaybackException.ERROR_CODE_*` (stable API values).
 */
object PlaybackErrorMapper {
    const val ERROR_CODE_UNSPECIFIED = 1000
    const val ERROR_CODE_REMOTE_ERROR = 1001
    const val ERROR_CODE_BEHIND_LIVE_WINDOW = 1002
    const val ERROR_CODE_TIMEOUT = 1003
    const val ERROR_CODE_IO_UNSPECIFIED = 2000
    const val ERROR_CODE_IO_NETWORK_CONNECTION_FAILED = 2001
    const val ERROR_CODE_IO_NETWORK_CONNECTION_TIMEOUT = 2002
    const val ERROR_CODE_IO_INVALID_HTTP_CONTENT_TYPE = 2003
    const val ERROR_CODE_IO_BAD_HTTP_STATUS = 2004
    const val ERROR_CODE_IO_FILE_NOT_FOUND = 2005
    const val ERROR_CODE_IO_NO_PERMISSION = 2006
    const val ERROR_CODE_IO_CLEARTEXT_NOT_PERMITTED = 2007
    const val ERROR_CODE_IO_READ_POSITION_OUT_OF_RANGE = 2008
    const val ERROR_CODE_PARSING_CONTAINER_MALFORMED = 3001
    const val ERROR_CODE_PARSING_MANIFEST_MALFORMED = 3002
    const val ERROR_CODE_PARSING_CONTAINER_UNSUPPORTED = 3003
    const val ERROR_CODE_PARSING_MANIFEST_UNSUPPORTED = 3004
    const val ERROR_CODE_DECODER_INIT_FAILED = 4001
    const val ERROR_CODE_DECODER_QUERY_FAILED = 4002
    const val ERROR_CODE_DECODING_FAILED = 4003
    const val ERROR_CODE_DECODING_FORMAT_EXCEEDS_CAPABILITIES = 4004
    const val ERROR_CODE_DECODING_FORMAT_UNSUPPORTED = 4005
    const val ERROR_CODE_AUDIO_TRACK_INIT_FAILED = 5001
    const val ERROR_CODE_AUDIO_TRACK_WRITE_FAILED = 5002
    const val ERROR_CODE_DRM_UNSPECIFIED = 6000
    const val ERROR_CODE_DRM_LAST = 6008

    /**
     * @property recoverable worth an automatic reconnect (ReconnectPolicy 1-2-4-8-15 s).
     * @property behindLiveWindow "behind live window": jump silently to the live edge (SCREENS §3.7).
     */
    data class Mapped(val error: PlaybackError, val recoverable: Boolean, val behindLiveWindow: Boolean = false)

    /**
     * @param httpStatus status of an `InvalidResponseCodeException` (if any).
     * @param offline device has no network → `Network(offline)`.
     * @param container detected container (for "format not supported").
     */
    fun map(errorCode: Int, httpStatus: Int? = null, offline: Boolean = false, container: Container = Container.UNKNOWN, message: String? = null): Mapped {
        if (errorCode == ERROR_CODE_BEHIND_LIVE_WINDOW) return Mapped(PlaybackError.Network(NetworkReason.OTHER), recoverable = true, behindLiveWindow = true)
        if (errorCode in ERROR_CODE_DRM_UNSPECIFIED..ERROR_CODE_DRM_LAST) return Mapped(PlaybackError.Drm, recoverable = false)
        return when (errorCode) {
            ERROR_CODE_IO_BAD_HTTP_STATUS -> {
                val status = httpStatus ?: 500
                val e = PlaybackError.fromHttpStatus(status)
                Mapped(e, recoverable = status >= 500)
            }
            ERROR_CODE_IO_FILE_NOT_FOUND -> Mapped(PlaybackError.StreamOffline(404), recoverable = false)
            ERROR_CODE_IO_NO_PERMISSION -> Mapped(PlaybackError.AccessDenied(403), recoverable = false)
            ERROR_CODE_IO_NETWORK_CONNECTION_FAILED, ERROR_CODE_IO_UNSPECIFIED, ERROR_CODE_TIMEOUT, ERROR_CODE_REMOTE_ERROR ->
                Mapped(PlaybackError.Network(if (offline) NetworkReason.OFFLINE else NetworkReason.OTHER), recoverable = true)
            ERROR_CODE_IO_NETWORK_CONNECTION_TIMEOUT ->
                Mapped(PlaybackError.Network(if (offline) NetworkReason.OFFLINE else NetworkReason.TIMEOUT), recoverable = true)
            ERROR_CODE_IO_CLEARTEXT_NOT_PERMITTED -> Mapped(PlaybackError.Network(NetworkReason.TLS), recoverable = false)
            ERROR_CODE_IO_READ_POSITION_OUT_OF_RANGE -> Mapped(PlaybackError.Network(NetworkReason.OTHER), recoverable = true)
            ERROR_CODE_IO_INVALID_HTTP_CONTENT_TYPE,
            ERROR_CODE_PARSING_CONTAINER_UNSUPPORTED,
            ERROR_CODE_PARSING_MANIFEST_UNSUPPORTED,
            ERROR_CODE_PARSING_CONTAINER_MALFORMED,
            ERROR_CODE_PARSING_MANIFEST_MALFORMED,
            -> Mapped(PlaybackError.UnsupportedFormat(container.wire), recoverable = false)
            ERROR_CODE_DECODER_INIT_FAILED,
            ERROR_CODE_DECODER_QUERY_FAILED,
            ERROR_CODE_DECODING_FAILED,
            ERROR_CODE_DECODING_FORMAT_EXCEEDS_CAPABILITIES,
            ERROR_CODE_DECODING_FORMAT_UNSUPPORTED,
            ERROR_CODE_AUDIO_TRACK_INIT_FAILED,
            ERROR_CODE_AUDIO_TRACK_WRITE_FAILED,
            -> Mapped(PlaybackError.UnsupportedCodec(), recoverable = false)
            else -> Mapped(PlaybackError.Unknown(message), recoverable = false)
        }
    }
}
