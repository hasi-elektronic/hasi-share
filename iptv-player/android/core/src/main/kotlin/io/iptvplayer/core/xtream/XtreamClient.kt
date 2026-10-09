package io.iptvplayer.core.xtream

import io.iptvplayer.core.error.SourceError
import io.iptvplayer.core.error.SourceException
import io.iptvplayer.core.model.Category
import io.iptvplayer.core.model.Channel
import io.iptvplayer.core.model.ContentKind
import io.iptvplayer.core.model.Movie
import io.iptvplayer.core.model.Series
import io.iptvplayer.core.model.SourceSecrets
import io.iptvplayer.core.model.SourceStatus
import io.iptvplayer.core.model.XtreamAccountInfo
import io.iptvplayer.core.net.HttpDefaults
import io.iptvplayer.core.net.SourceHttp
import io.iptvplayer.core.util.ContentKeys
import io.iptvplayer.core.util.Gzip
import io.iptvplayer.core.util.UrlNormalizer
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.serialization.SerializationException
import kotlinx.serialization.json.DecodeSequenceMode
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.decodeToSequence
import okhttp3.Response
import okio.BufferedSource

/** Everything a full Xtream refresh produces (CONTRACT §3.1 step 3). */
public data class XtreamCatalog(
    val account: XtreamAccountInfo,
    val liveCategories: List<Category>,
    val vodCategories: List<Category>,
    val seriesCategories: List<Category>,
    val channels: List<Channel>,
    val movies: List<Movie>,
    val series: List<Series>,
) {
    /** Summary for `Source.lastRefreshResult`. */
    val status: SourceStatus
        get() = SourceStatus(ok = true, liveCount = channels.size, movieCount = movies.size, seriesCount = series.size)
}

/**
 * Xtream Codes API client (CONTRACT §4) on top of [SourceHttp]: Xtream status mapping
 * (401/403 → InvalidCredentials, 404 → NotFound, other → ServerError), whole-call timeout 20 s,
 * retries per [SourceHttp.retryPolicy], non-JSON bodies → [SourceError.InvalidResponse].
 * Big lists are decoded as a stream (one item at a time) so memory stays bounded.
 *
 * Every method throws [SourceException] on failure and is cancellable.
 */
public class XtreamClient(
    private val http: SourceHttp,
    public val sourceId: String,
    public val urls: XtreamUrlBuilder,
    private val userAgent: String? = null,
    private val callTimeoutMs: Long = HttpDefaults.XTREAM_CALL_TIMEOUT_MS,
    /** Clock used for the `exp_date < now` check (inject the trusted clock / a fixed time in tests). */
    private val nowMs: () -> Long = System::currentTimeMillis,
) {
    public constructor(
        http: SourceHttp,
        sourceId: String,
        secrets: SourceSecrets.Xtream,
        userAgent: String? = null,
        nowMs: () -> Long = System::currentTimeMillis,
    ) : this(http, sourceId, XtreamUrlBuilder(secrets), userAgent, HttpDefaults.XTREAM_CALL_TIMEOUT_MS, nowMs) {
        username = secrets.username
    }

    private var username: String? = null

    /** Source fingerprint (CONTRACT §1.1); null when built without [SourceSecrets.Xtream]. */
    public val fingerprint: String?
        get() = username?.let { ContentKeys.xtreamFingerprint(UrlNormalizer.host(urls.base) ?: urls.base, it) }

    private val headers: Map<String, String> = userAgent?.let { mapOf("User-Agent" to it) } ?: emptyMap()

    // ---------------------------------------------------------------- account

    /** `player_api.php` without action, classified per CONTRACT §4.4. */
    public suspend fun authenticate(): XtreamAccountInfo = get(urls.api()) { body ->
        XtreamAccountClassifier.classifyJson(XtreamJson.parseOrNull(body.readUtf8()), nowMs())
    }

    // ---------------------------------------------------------------- lists

    /** `get_live_categories`. */
    public suspend fun liveCategories(): List<Category> = categories("get_live_categories", ContentKind.LIVE)

    /** `get_vod_categories`. */
    public suspend fun vodCategories(): List<Category> = categories("get_vod_categories", ContentKind.MOVIE)

    /** `get_series_categories`. */
    public suspend fun seriesCategories(): List<Category> = categories("get_series_categories", ContentKind.SERIES)

    private suspend fun categories(action: String, kind: ContentKind): List<Category> =
        collect(action) { item, sort -> XtreamMapper.category(item, sourceId, kind, sort) }

    /** `get_live_streams` (all at once). */
    public suspend fun liveStreams(): List<Channel> =
        collect("get_live_streams") { item, sort -> XtreamMapper.channel(item, sourceId, sort) }

    /** `get_live_streams` streamed in batches of ≤ [batchSize]; returns the item count. */
    public suspend fun liveStreams(batchSize: Int, onBatch: suspend (List<Channel>) -> Unit): Int =
        stream("get_live_streams", batchSize, { item, sort -> XtreamMapper.channel(item, sourceId, sort) }, onBatch)

    /** `get_vod_streams` (all at once). */
    public suspend fun vodStreams(): List<Movie> =
        collect("get_vod_streams") { item, sort -> XtreamMapper.movie(item, sourceId, sort) }

    /** `get_vod_streams` streamed in batches; returns the item count. */
    public suspend fun vodStreams(batchSize: Int, onBatch: suspend (List<Movie>) -> Unit): Int =
        stream("get_vod_streams", batchSize, { item, sort -> XtreamMapper.movie(item, sourceId, sort) }, onBatch)

    /** `get_series` (all at once). */
    public suspend fun series(): List<Series> =
        collect("get_series") { item, sort -> XtreamMapper.seriesItem(item, sourceId, sort) }

    /** `get_series` streamed in batches; returns the item count. */
    public suspend fun series(batchSize: Int, onBatch: suspend (List<Series>) -> Unit): Int =
        stream("get_series", batchSize, { item, sort -> XtreamMapper.seriesItem(item, sourceId, sort) }, onBatch)

    // ---------------------------------------------------------------- details

    /** `get_series_info` (both episode shapes). */
    public suspend fun seriesInfo(seriesId: String): XtreamSeriesInfo =
        getJson(urls.api("get_series_info", "series_id" to seriesId)) { XtreamMapper.seriesInfo(it, sourceId, seriesId) }

    /** `get_vod_info`. */
    public suspend fun vodInfo(vodId: String): XtreamVodInfo =
        getJson(urls.api("get_vod_info", "vod_id" to vodId)) { XtreamMapper.vodInfo(it) }

    /** `get_short_epg` (base64 titles decoded). */
    public suspend fun shortEpg(streamId: String, limit: Int = 4, serverTimezone: String? = null): List<XtreamEpgEntry> =
        getJson(urls.api("get_short_epg", "stream_id" to streamId, "limit" to limit.toString())) {
            XtreamMapper.shortEpg(it, serverTimezone)
        }

    /** `get_simple_data_table` (full archive listing of a channel). */
    public suspend fun simpleDataTable(streamId: String, serverTimezone: String? = null): List<XtreamEpgEntry> =
        getJson(urls.api("get_simple_data_table", "stream_id" to streamId)) { XtreamMapper.shortEpg(it, serverTimezone) }

    /** Full XMLTV guide URL (fetch it with [io.iptvplayer.core.xmltv.EpgClient]). */
    public fun xmltvUrl(): String = urls.xmltv()

    // ---------------------------------------------------------------- refresh

    /**
     * Full refresh: account check, then categories and lists concurrently (structured: the first
     * failure cancels the rest). Throws [SourceError.Empty] when there is no live, VOD or series
     * item (CONTRACT §4.4).
     */
    public suspend fun fetchCatalog(): XtreamCatalog {
        val account = authenticate()
        val catalog = coroutineScope {
            val liveCats = async { liveCategories() }
            val vodCats = async { vodCategories() }
            val seriesCats = async { seriesCategories() }
            val channels = async { liveStreams() }
            val movies = async { vodStreams() }
            val series = async { series() }
            XtreamCatalog(
                account, liveCats.await(), vodCats.await(), seriesCats.await(),
                channels.await(), movies.await(), series.await(),
            )
        }
        if (catalog.channels.isEmpty() && catalog.movies.isEmpty() && catalog.series.isEmpty()) {
            throw SourceException(SourceError.Empty)
        }
        return catalog
    }

    // ---------------------------------------------------------------- plumbing

    private suspend fun <T> get(url: String, handle: suspend (BufferedSource) -> T): T = http.get(
        url = url,
        callTimeoutMs = callTimeoutMs,
        headers = headers + ("Accept" to "application/json"),
        statusMapper = SourceError::fromXtreamHttpStatus,
        tag = "Xtream",
    ) { response -> handle(bodySource(response)) }

    private suspend fun <T> getJson(url: String, map: (JsonElement) -> T): T = get(url) { body ->
        val json = XtreamJson.parseOrNull(body.readUtf8()) ?: throw SourceException(SourceError.InvalidResponse)
        if (json !is JsonObject && json !is JsonArray && json !is JsonNull) throw SourceException(SourceError.InvalidResponse)
        map(json)
    }

    private suspend fun <T : Any> collect(action: String, map: (JsonElement, Int) -> T?): List<T> {
        val out = ArrayList<T>()
        stream(action, Int.MAX_VALUE, map) { out.addAll(it) }
        return out
    }

    /**
     * Streams the items of list [action]: a top-level array is decoded element by element;
     * an object's values (ordered by numeric key) are used as items; `null`/empty body → no items.
     */
    private suspend fun <T : Any> stream(
        action: String,
        batchSize: Int,
        map: (JsonElement, Int) -> T?,
        onBatch: suspend (List<T>) -> Unit,
    ): Int {
        require(batchSize > 0)
        return get(urls.api(action)) { body ->
            var count = 0
            var batch = ArrayList<T>(minOf(batchSize, 1024))
            suspend fun emit(item: JsonElement) {
                if (item is JsonNull) return
                val mapped = try {
                    map(item, count)
                } catch (_: RuntimeException) {
                    null
                } ?: return
                batch.add(mapped)
                count++
                if (batch.size >= batchSize) {
                    currentCoroutineContext().ensureActive()
                    val full = batch
                    batch = ArrayList(minOf(batchSize, 1024))
                    onBatch(full)
                }
            }
            val first = skipWhitespace(body) ?: return@get 0 // empty body = empty list
            try {
                if (first == '['.code.toByte()) {
                    // Top-level array: decode one element at a time (bounded memory).
                    val elements = XtreamJson.parser.decodeToSequence(
                        body.inputStream(),
                        JsonElement.serializer(),
                        DecodeSequenceMode.ARRAY_WRAPPED,
                    )
                    for (element in elements) emit(element)
                } else {
                    when (val root = XtreamJson.parser.parseToJsonElement(body.readUtf8())) {
                        is JsonObject -> if (looksLikeItem(root)) emit(root) else XtreamJson.listItems(root).forEach { emit(it) }
                        is JsonNull -> Unit
                        else -> throw SourceException(SourceError.InvalidResponse)
                    }
                }
            } catch (e: SerializationException) {
                // Not JSON (HTML error page, truncated body …).
                throw SourceException(SourceError.InvalidResponse, e)
            }
            if (batch.isNotEmpty()) onBatch(batch)
            count
        }
    }

    /** Consumes leading whitespace / UTF-8 BOM; returns the next byte (not consumed) or null at EOF. */
    private fun skipWhitespace(source: BufferedSource): Byte? {
        while (source.request(1)) {
            val b = source.buffer[0]
            val skip = b == ' '.code.toByte() || b == '\n'.code.toByte() || b == '\r'.code.toByte() ||
                b == '\t'.code.toByte() || b == 0xEF.toByte() || b == 0xBB.toByte() || b == 0xBF.toByte()
            if (!skip) return b
            source.skip(1)
        }
        return null
    }

    /** A top-level object that is itself one item (rare panels) rather than a `{"0": {...}}` map. */
    private fun looksLikeItem(o: JsonObject): Boolean =
        o.containsKey("stream_id") || o.containsKey("series_id") || o.containsKey("category_id")

    private fun bodySource(response: Response): BufferedSource {
        val body = response.body ?: throw SourceException(SourceError.InvalidResponse)
        // OkHttp already handles `Content-Encoding: gzip`; some panels send gzip without the header.
        return Gzip.maybeGunzip(body.source())
    }

    override fun toString(): String = "XtreamClient(sourceId=$sourceId, base=${urls.base})"
}
