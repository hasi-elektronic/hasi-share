package io.iptvplayer.core.error

import java.io.IOException
import java.io.InterruptedIOException
import java.net.ConnectException
import java.net.SocketTimeoutException
import java.net.UnknownHostException
import java.security.cert.CertificateException
import javax.net.ssl.SSLException
import kotlin.coroutines.cancellation.CancellationException

/** Reason of a network failure (CONTRACT §2). */
public enum class NetworkReason(public val wire: String) {
    TIMEOUT("timeout"),
    DNS("dns"),
    REFUSED("refused"),
    TLS("tls"),
    OFFLINE("offline"),
    OTHER("other"),
    ;

    public companion object {
        /** Parses [wire]; unknown → [OTHER]. */
        public fun fromWire(value: String): NetworkReason = entries.firstOrNull { it.wire == value } ?: OTHER
    }
}

/**
 * Errors of source operations (add / refresh / EPG) – CONTRACT §2. Identical on all platforms.
 * Every error has a stable, persistable [code] (see [fromCode]).
 */
public sealed interface SourceError {
    /** Stable code, e.g. `network:timeout`, `server_error:502`, `account_expired:1700000000000`. */
    public val code: String

    /** True for errors where an automatic retry makes sense (Network, 5xx). Never 4xx. */
    public val isRetryable: Boolean
        get() = when (this) {
            is Network -> reason != NetworkReason.OFFLINE
            is ServerError -> httpStatus in 500..599
            else -> false
        }

    /** Network failure. */
    public data class Network(val reason: NetworkReason) : SourceError {
        override val code: String get() = "network:${reason.wire}"
    }

    /** Xtream auth=0, HTTP 401/403 on player_api, empty `user_info`. */
    public data object InvalidCredentials : SourceError {
        override val code: String get() = "invalid_credentials"
    }

    /** Status `Expired` or `exp_date` < now. [expiresAtMs] when known. */
    public data class AccountExpired(val expiresAtMs: Long?) : SourceError {
        override val code: String get() = "account_expired" + (expiresAtMs?.let { ":$it" } ?: "")
    }

    /** Status `Banned` / `Disabled`. */
    public data object AccountDisabled : SourceError {
        override val code: String get() = "account_disabled"
    }

    /** HTTP 404 on a list / EPG URL. */
    public data object NotFound : SourceError {
        override val code: String get() = "not_found"
    }

    /** 5xx and other non-2xx statuses. */
    public data class ServerError(val httpStatus: Int) : SourceError {
        override val code: String get() = "server_error:$httpStatus"
    }

    /** Not an M3U / not XMLTV. */
    public data object InvalidFormat : SourceError {
        override val code: String get() = "invalid_format"
    }

    /** Xtream: body is not the expected JSON (e.g. HTML). */
    public data object InvalidResponse : SourceError {
        override val code: String get() = "invalid_response"
    }

    /** Parsed fine, zero playable items. */
    public data object Empty : SourceError {
        override val code: String get() = "empty"
    }

    /** The operation was cancelled. */
    public data object Cancelled : SourceError {
        override val code: String get() = "cancelled"
    }

    public companion object {
        /** Decodes a [code]; null when unknown. */
        public fun fromCode(code: String): SourceError? {
            val head = code.substringBefore(':')
            val arg = code.substringAfter(':', "")
            return when (head) {
                "network" -> Network(NetworkReason.fromWire(arg))
                "invalid_credentials" -> InvalidCredentials
                "account_expired" -> AccountExpired(arg.toLongOrNull())
                "account_disabled" -> AccountDisabled
                "not_found" -> NotFound
                "server_error" -> arg.toIntOrNull()?.let { ServerError(it) }
                "invalid_format" -> InvalidFormat
                "invalid_response" -> InvalidResponse
                "empty" -> Empty
                "cancelled" -> Cancelled
                else -> null
            }
        }

        /** Maps a non-2xx HTTP status of a list/EPG download (M3U, XMLTV). */
        public fun fromHttpStatus(status: Int): SourceError = when (status) {
            401, 403 -> InvalidCredentials
            404, 410 -> NotFound
            else -> ServerError(status)
        }
    }
}

/** Exception carrying a [SourceError]; thrown by the source clients and parsers. */
public class SourceException(public val error: SourceError, cause: Throwable? = null) :
    Exception(error.code, cause)

/** Playback errors (CONTRACT §2). */
public sealed interface PlaybackError {
    /** Stable code for logging/analytics. */
    public val code: String

    /** Connection to the stream lost / not reachable. */
    public data class Network(val reason: NetworkReason = NetworkReason.OTHER) : PlaybackError {
        override val code: String get() = "network:${reason.wire}"
    }

    /** HTTP 401/403 (connection limit, expired account). */
    public data class AccessDenied(val httpStatus: Int) : PlaybackError {
        override val code: String get() = "access_denied:$httpStatus"
    }

    /** HTTP 404/410: channel not broadcasting. */
    public data class StreamOffline(val httpStatus: Int) : PlaybackError {
        override val code: String get() = "stream_offline:$httpStatus"
    }

    /** Other HTTP errors. */
    public data class ServerError(val httpStatus: Int) : PlaybackError {
        override val code: String get() = "server_error:$httpStatus"
    }

    /** Container not playable on this engine ([container] = wire name, e.g. `mpegts`). */
    public data class UnsupportedFormat(val container: String) : PlaybackError {
        override val code: String get() = "unsupported_format:$container"
    }

    /** Decoder missing for [codec] (if known). */
    public data class UnsupportedCodec(val codec: String? = null) : PlaybackError {
        override val code: String get() = "unsupported_codec" + (codec?.let { ":$it" } ?: "")
    }

    /** DRM-protected stream (not supported). */
    public data object Drm : PlaybackError {
        override val code: String get() = "drm"
    }

    /** Anything else. */
    public data class Unknown(val message: String? = null) : PlaybackError {
        override val code: String get() = "unknown"
    }

    public companion object {
        /** Maps an HTTP status of a stream request (CONTRACT §2). */
        public fun fromHttpStatus(status: Int): PlaybackError = when (status) {
            401, 403 -> AccessDenied(status)
            404, 410 -> StreamOffline(status)
            else -> ServerError(status)
        }
    }
}

/** Exception carrying a [PlaybackError]. */
public class PlaybackException(public val error: PlaybackError, cause: Throwable? = null) :
    Exception(error.code, cause)

/**
 * Connectivity state provider. Android passes `ConnectivityManager` state so that network errors
 * while offline are reported as [NetworkReason.OFFLINE].
 */
public fun interface ConnectivityProbe {
    /** True when the device currently has no usable network. */
    public fun isOffline(): Boolean

    public companion object {
        /** Assumes connectivity (tests / JVM). */
        public val ALWAYS_ONLINE: ConnectivityProbe = ConnectivityProbe { false }
    }
}

/**
 * Pure mapping of I/O exceptions to [NetworkReason] / [SourceError] (CONTRACT §2):
 * UnknownHostException → dns, SocketTimeoutException / InterruptedIOException → timeout,
 * ConnectException → refused, SSLException → tls; everything is `offline` when the caller says
 * the device is offline.
 */
public object NetworkErrorClassifier {
    /** Classifies [t] (walking its cause chain). [offline] = current connectivity state. */
    public fun reason(t: Throwable, offline: Boolean = false): NetworkReason {
        if (offline) return NetworkReason.OFFLINE
        var cur: Throwable? = t
        var depth = 0
        while (cur != null && depth < 10) {
            when (cur) {
                is UnknownHostException -> return NetworkReason.DNS
                is SSLException, is CertificateException -> return NetworkReason.TLS
                is ConnectException -> return NetworkReason.REFUSED
                is SocketTimeoutException -> return NetworkReason.TIMEOUT
                is InterruptedIOException -> if (!isOkHttpCancel(cur)) return NetworkReason.TIMEOUT
            }
            if (cur.cause === cur) break
            cur = cur.cause
            depth++
        }
        return NetworkReason.OTHER
    }

    /**
     * Maps any failure of a source request to a [SourceError]: [SourceException] → its error,
     * cancellation → [SourceError.Cancelled], other throwables → [SourceError.Network].
     */
    public fun toSourceError(t: Throwable, offline: Boolean = false): SourceError = when {
        t is SourceException -> t.error
        isCancellation(t) -> SourceError.Cancelled
        else -> SourceError.Network(reason(t, offline))
    }

    /** Maps a playback I/O failure to [PlaybackError.Network]. */
    public fun toPlaybackError(t: Throwable, offline: Boolean = false): PlaybackError =
        if (t is PlaybackException) t.error else PlaybackError.Network(reason(t, offline))

    /** True for coroutine cancellation and OkHttp `Call.cancel()` ("Canceled"). */
    public fun isCancellation(t: Throwable): Boolean =
        t is CancellationException || isOkHttpCancel(t)

    private fun isOkHttpCancel(t: Throwable): Boolean =
        t is IOException && t.message == "Canceled" && t.javaClass == IOException::class.java
}
