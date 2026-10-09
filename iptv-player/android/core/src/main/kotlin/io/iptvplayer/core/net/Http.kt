package io.iptvplayer.core.net

import io.iptvplayer.core.error.ConnectivityProbe
import io.iptvplayer.core.error.NetworkErrorClassifier
import io.iptvplayer.core.error.SourceError
import io.iptvplayer.core.error.SourceException
import io.iptvplayer.core.retry.SourceRetryPolicy
import io.iptvplayer.core.util.CoreLogger
import io.iptvplayer.core.util.LogLevel
import io.iptvplayer.core.util.Redactor
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import okhttp3.Call
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import java.io.IOException
import java.util.concurrent.TimeUnit
import kotlin.coroutines.cancellation.CancellationException

/** Network defaults of CONTRACT §2. */
public object HttpDefaults {
    /** Connect timeout for every request. */
    public const val CONNECT_TIMEOUT_MS: Long = 10_000L

    /** Read (socket idle) timeout for every request. */
    public const val READ_TIMEOUT_MS: Long = 30_000L

    /** Whole-call timeout for playlist / EPG downloads. */
    public const val PLAYLIST_CALL_TIMEOUT_MS: Long = 120_000L

    /** Whole-call timeout for Xtream JSON calls. */
    public const val XTREAM_CALL_TIMEOUT_MS: Long = 20_000L

    /** Whole-call timeout for backend calls. */
    public const val BACKEND_CALL_TIMEOUT_MS: Long = 20_000L

    /** Default User-Agent for source requests (overridable per source / client). */
    public const val USER_AGENT: String = "IPTVPlayer/1.0 (Linux; Android)"

    /**
     * Creates an [OkHttpClient] with the contract timeouts (connect 10 s, read 30 s, write 30 s).
     * Share one instance app-wide; per-call timeouts are applied via `Call.timeout()`.
     */
    public fun newClient(builder: OkHttpClient.Builder = OkHttpClient.Builder()): OkHttpClient =
        builder
            .connectTimeout(CONNECT_TIMEOUT_MS, TimeUnit.MILLISECONDS)
            .readTimeout(READ_TIMEOUT_MS, TimeUnit.MILLISECONDS)
            .writeTimeout(READ_TIMEOUT_MS, TimeUnit.MILLISECONDS)
            .followRedirects(true)
            .followSslRedirects(true)
            .build()
}

/**
 * Executes [request] on [dispatcher] and passes the open [Response] to [block] (the response is
 * closed afterwards). Fully cancellable: cancelling the coroutine cancels the OkHttp call, which
 * aborts a blocked connect/read; the coroutine then completes with [CancellationException].
 *
 * @param callTimeoutMs whole-call timeout (DNS, connect, request, response **and body**).
 */
public suspend fun <T> OkHttpClient.executeCancellable(
    request: Request,
    callTimeoutMs: Long? = null,
    dispatcher: CoroutineDispatcher = Dispatchers.IO,
    block: suspend (Response) -> T,
): T {
    val call: Call = newCall(request)
    if (callTimeoutMs != null && callTimeoutMs > 0) call.timeout().timeout(callTimeoutMs, TimeUnit.MILLISECONDS)
    return coroutineScope {
        // Child that cancels the call as soon as this scope is cancelled.
        val canceller = launch(start = CoroutineStart.UNDISPATCHED) {
            try {
                awaitCancellation()
            } finally {
                call.cancel()
            }
        }
        try {
            withContext(dispatcher) {
                call.execute().use { block(it) }
            }
        } catch (e: IOException) {
            if (!isActive) throw CancellationException("HTTP call cancelled").apply { initCause(e) }
            throw e
        } finally {
            canceller.cancel()
        }
    }
}

/** Internal marker: failure that may be retried (happened before the body was consumed). */
internal class RetryableFailure(val error: SourceError, cause: Throwable?) : Exception(error.code, cause)

/**
 * Shared GET pipeline of the source clients (M3U, XMLTV, Xtream): timeouts, retry policy,
 * error mapping (CONTRACT §2) and redacted logging. Failures surface as [SourceException].
 */
public class SourceHttp(
    public val client: OkHttpClient,
    public val connectivity: ConnectivityProbe = ConnectivityProbe.ALWAYS_ONLINE,
    public val retryPolicy: SourceRetryPolicy = SourceRetryPolicy.DEFAULT,
    public val logger: CoreLogger = CoreLogger.NONE,
    public val redactor: Redactor = Redactor.default,
    public val dispatcher: CoroutineDispatcher = Dispatchers.IO,
    /** Sleep function used between retries (tests inject a no-op). */
    public val sleeper: suspend (Long) -> Unit = { delay(it) },
    public val userAgent: String = HttpDefaults.USER_AGENT,
) {
    /**
     * GETs [url]; non-2xx statuses are mapped with [statusMapper] and thrown; on 2xx [handle]
     * consumes the response. Network errors and retryable statuses that happen **before** the body
     * is handed to [handle] are retried per [retryPolicy]; failures while consuming are not.
     *
     * @throws SourceException on every failure except coroutine cancellation.
     */
    public suspend fun <T> get(
        url: String,
        callTimeoutMs: Long,
        headers: Map<String, String> = emptyMap(),
        statusMapper: (Int) -> SourceError = SourceError::fromListHttpStatus,
        tag: String = "SourceHttp",
        handle: suspend (Response) -> T,
    ): T {
        val request = try {
            Request.Builder().url(url).get().apply {
                header("User-Agent", headers["User-Agent"] ?: userAgent)
                headers.forEach { (k, v) -> if (!k.equals("User-Agent", ignoreCase = true)) header(k, v) }
            }.build()
        } catch (e: IllegalArgumentException) {
            // Malformed URL (e.g. unsupported scheme): treat as "not found" for the user.
            throw SourceException(SourceError.NotFound, e)
        }
        var retries = 0
        while (true) {
            try {
                return attempt(request, callTimeoutMs, statusMapper, tag, handle)
            } catch (f: RetryableFailure) {
                val wait = retryPolicy.delayBeforeRetry(f.error, retries)
                    ?: throw SourceException(f.error, f.cause)
                log(LogLevel.INFO, tag, "retry ${retries + 1}/${retryPolicy.maxRetries} after ${f.error.code} in $wait ms: ${request.url}")
                sleeper(wait)
                retries++
            }
        }
    }

    private suspend fun <T> attempt(
        request: Request,
        callTimeoutMs: Long,
        statusMapper: (Int) -> SourceError,
        tag: String,
        handle: suspend (Response) -> T,
    ): T {
        var consuming = false
        val started = System.nanoTime()
        try {
            return client.executeCancellable(request, callTimeoutMs, dispatcher) { response ->
                val ms = (System.nanoTime() - started) / 1_000_000
                log(LogLevel.DEBUG, tag, "GET ${request.url} -> ${response.code} ($ms ms)")
                if (!response.isSuccessful) {
                    val err = statusMapper(response.code)
                    if (err.isRetryable) throw RetryableFailure(err, null)
                    throw SourceException(err)
                }
                consuming = true
                handle(response)
            }
        } catch (e: CancellationException) {
            throw e
        } catch (e: SourceException) {
            throw e
        } catch (e: RetryableFailure) {
            throw e
        } catch (e: IOException) {
            val err = NetworkErrorClassifier.toSourceError(e, connectivity.isOffline())
            log(LogLevel.WARN, tag, "GET ${request.url} failed: ${err.code}", e)
            if (!consuming && err.isRetryable) throw RetryableFailure(err, e)
            throw SourceException(err, e)
        }
    }

    private fun log(level: LogLevel, tag: String, message: String, t: Throwable? = null) {
        // Never log an unredacted URL (CONTRACT §10).
        logger.log(level, tag, redactor.redact(message), t)
    }
}
