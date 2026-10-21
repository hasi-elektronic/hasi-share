package io.iptvplayer.core.m3u

import io.iptvplayer.core.error.SourceError
import io.iptvplayer.core.error.SourceException
import io.iptvplayer.core.net.HttpDefaults
import io.iptvplayer.core.net.SourceHttp
import io.iptvplayer.core.util.Gzip

/**
 * Downloads and parses an M3U playlist in a streaming fashion (CONTRACT §3, §2):
 * whole-call timeout 120 s, retries per [SourceHttp.retryPolicy] before the body is consumed,
 * gzip auto-detected, 404 → [SourceError.NotFound], other non-2xx → [SourceError.ServerError].
 */
public class M3uClient(private val http: SourceHttp) {
    /**
     * Fetches [url] and emits parsed entries in batches to [onBatch] (e.g. write to Room).
     * @param userAgent per-source User-Agent override (`SourceSecrets.M3u.userAgent`).
     * @throws SourceException on failure (incl. [SourceError.InvalidFormat] / [SourceError.Empty]).
     */
    public suspend fun fetch(
        url: String,
        userAgent: String? = null,
        batchSize: Int = M3uParser.DEFAULT_BATCH_SIZE,
        callTimeoutMs: Long = HttpDefaults.PLAYLIST_CALL_TIMEOUT_MS,
        onBatch: suspend (List<M3uEntry>) -> Unit,
    ): M3uParseResult = http.get(
        url = url,
        callTimeoutMs = callTimeoutMs,
        headers = userAgent?.let { mapOf("User-Agent" to it) } ?: emptyMap(),
        statusMapper = SourceError::fromListHttpStatus,
        tag = "M3u",
    ) { response ->
        val body = response.body ?: throw SourceException(SourceError.InvalidFormat)
        M3uParser.parse(Gzip.maybeGunzip(body.source()), batchSize, onBatch)
    }
}
