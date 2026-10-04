package io.iptvplayer.core.backend

import io.iptvplayer.core.CoreJson
import io.iptvplayer.core.crypto.EcPublicJwk
import io.iptvplayer.core.error.ConnectivityProbe
import io.iptvplayer.core.error.NetworkErrorClassifier
import io.iptvplayer.core.net.HttpDefaults
import io.iptvplayer.core.net.executeCancellable
import io.iptvplayer.core.pairing.PairCode
import io.iptvplayer.core.pairing.PairEnvelope
import io.iptvplayer.core.sync.SyncItem
import io.iptvplayer.core.util.CoreLogger
import io.iptvplayer.core.util.LogLevel
import io.iptvplayer.core.util.PercentEncoding
import io.iptvplayer.core.util.Redactor
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Dispatchers
import kotlinx.serialization.DeserializationStrategy
import kotlinx.serialization.SerializationException
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import java.io.IOException
import kotlin.coroutines.cancellation.CancellationException

/**
 * Typed client of the minimal backend (spec/BACKEND_API.md). JSON in/out, whole-call timeout
 * 20 s (CONTRACT §2), fully cancellable. Failures surface as [BackendException]:
 *
 * | Condition | [BackendError] |
 * |---|---|
 * | I/O failure | `Network(reason)` (offline / dns / timeout / refused / tls / other) |
 * | 401 | `Unauthorized` |
 * | 429 | `RateLimited(retry-after)` |
 * | other 4xx with `{error}` body | `Api(status, error, message)` |
 * | 5xx, or non-2xx without JSON error body | `ServerError(status)` |
 * | 2xx with unexpected/non-JSON body | `InvalidResponse` |
 *
 * No automatic retries: the callers (LicenseManager, SyncManager) own the retry schedule.
 * Session tokens are sent as `Authorization: Bearer …` and never logged.
 */
public class BackendClient(
    baseUrl: String,
    private val client: OkHttpClient,
    private val connectivity: ConnectivityProbe = ConnectivityProbe.ALWAYS_ONLINE,
    private val logger: CoreLogger = CoreLogger.NONE,
    private val redactor: Redactor = Redactor.default,
    private val dispatcher: CoroutineDispatcher = Dispatchers.IO,
    private val callTimeoutMs: Long = HttpDefaults.BACKEND_CALL_TIMEOUT_MS,
    private val userAgent: String = HttpDefaults.USER_AGENT,
) {
    /** Base URL without trailing slash. */
    public val baseUrl: String = baseUrl.trim().trimEnd('/')

    // ---------------------------------------------------------------- public

    /** `GET /v1/config`. */
    public suspend fun config(): BackendConfig = request("GET", "/v1/config").decode(BackendConfig.serializer())

    /**
     * `POST /v1/license/sync` (session optional). 422/503 responses that still contain a token
     * are returned with [LicenseSyncResult.partialError].
     */
    public suspend fun licenseSync(body: LicenseSyncRequest, sessionToken: String? = null): LicenseSyncResult {
        val r = request("POST", "/v1/license/sync", CoreJson.encodeToJsonElement(LicenseSyncRequest.serializer(), body), sessionToken)
        if (r.isSuccess) return LicenseSyncResult(r.decode(LicenseSyncResponse.serializer()))
        if ((r.status == 422 || r.status == 503) && r.json is JsonObject && r.json.containsKey("token")) {
            val partial = try {
                CoreJson.decodeFromJsonElement(LicenseSyncResponse.serializer(), r.json)
            } catch (_: SerializationException) {
                null
            } catch (_: IllegalArgumentException) {
                null
            }
            if (partial != null) return LicenseSyncResult(partial, r.toError())
        }
        throw BackendException(r.toError())
    }

    // ---------------------------------------------------------------- accounts

    /** `POST /v1/auth/email/start`. */
    public suspend fun emailStart(email: String, locale: String): EmailStartResponse =
        post("/v1/auth/email/start", EmailStartRequest(email, locale), EmailStartRequest.serializer())
            .decode(EmailStartResponse.serializer())

    /** `POST /v1/auth/email/verify` → session. */
    public suspend fun emailVerify(email: String, code: String, deviceName: String): SessionResponse =
        post("/v1/auth/email/verify", EmailVerifyRequest(email, code, deviceName), EmailVerifyRequest.serializer())
            .decode(SessionResponse.serializer())

    /** `POST /v1/auth/logout`. */
    public suspend fun logout(sessionToken: String) {
        request("POST", "/v1/auth/logout", JsonObject(emptyMap()), sessionToken).decode(OkResponse.serializer())
    }

    /** `GET /v1/account`. */
    public suspend fun account(sessionToken: String): AccountResponse =
        request("GET", "/v1/account", session = sessionToken).decode(AccountResponse.serializer())

    /** `DELETE /v1/account` (Apple 5.1.1(v)). */
    public suspend fun deleteAccount(sessionToken: String) {
        request("DELETE", "/v1/account", session = sessionToken).decode(OkResponse.serializer())
    }

    /** `POST /v1/auth/device/start` (TV login). */
    public suspend fun deviceStart(platform: String, deviceName: String): DeviceStartResponse =
        post("/v1/auth/device/start", DeviceStartRequest(platform, deviceName), DeviceStartRequest.serializer())
            .decode(DeviceStartResponse.serializer())

    /** One `POST /v1/auth/device/poll`. */
    public suspend fun devicePoll(deviceCode: String): DevicePollResult {
        val r = request("POST", "/v1/auth/device/poll", buildJsonObject { put("deviceCode", deviceCode) })
        return when {
            r.isSuccess -> DevicePollResult.Approved(r.decode(SessionResponse.serializer()))
            r.status == 428 -> DevicePollResult.Pending
            r.status == 429 && r.apiCode == "slow_down" ->
                DevicePollResult.SlowDown(((r.json as? JsonObject)?.get("interval")?.jsonPrimitive?.intOrNull) ?: 10)
            r.status == 410 -> DevicePollResult.Expired
            else -> throw BackendException(r.toError())
        }
    }

    /** `POST /v1/auth/device/approve` (phone approves the TV's user code). */
    public suspend fun deviceApprove(sessionToken: String, userCode: String) {
        request("POST", "/v1/auth/device/approve", buildJsonObject { put("userCode", userCode) }, sessionToken)
            .decode(OkResponse.serializer())
    }

    // ---------------------------------------------------------------- sync

    /** `GET /v1/sync?since=&limit=` – malformed items are skipped, not fatal. */
    public suspend fun syncPull(sessionToken: String, since: Long, limit: Int = 500): SyncPage {
        val r = request("GET", "/v1/sync?since=$since&limit=$limit", session = sessionToken)
        val o = r.successJson() as? JsonObject ?: throw BackendException(BackendError.InvalidResponse)
        val rawItems = o["items"] as? JsonArray ?: throw BackendException(BackendError.InvalidResponse)
        var skipped = 0
        val items = rawItems.mapNotNull { e ->
            val item = try {
                CoreJson.decodeFromJsonElement(SyncItem.serializer(), e).takeIf { it.isWellFormed }
            } catch (_: SerializationException) {
                null
            } catch (_: IllegalArgumentException) {
                null
            }
            if (item == null) skipped++
            item
        }
        val cursor = o["cursor"]?.jsonPrimitive?.contentOrNull?.toLongOrNull() ?: throw BackendException(BackendError.InvalidResponse)
        val hasMore = o["hasMore"]?.jsonPrimitive?.contentOrNull == "true"
        return SyncPage(items, cursor, hasMore, skipped)
    }

    /** `POST /v1/sync` (≤ 500 items per call). */
    public suspend fun syncPush(sessionToken: String, items: List<SyncItem>): SyncPushResponse {
        require(items.size <= 500) { "at most 500 items per request" }
        val body = buildJsonObject { put("items", JsonArray(items.map { it.toWireJson() })) }
        return request("POST", "/v1/sync", body, sessionToken).decode(SyncPushResponse.serializer())
    }

    // ---------------------------------------------------------------- pairing

    /** TV: `POST /v1/pair/sessions {publicKey}`. */
    public suspend fun pairCreate(publicKey: EcPublicJwk): PairSessionResponse =
        request("POST", "/v1/pair/sessions", buildJsonObject { put("publicKey", CoreJson.encodeToJsonElement(EcPublicJwk.serializer(), publicKey)) })
            .decode(PairSessionResponse.serializer())

    /** Phone (in-app sender): `GET /v1/pair/sessions/{code}/key`. */
    public suspend fun pairKey(code: String): PairKeyResponse =
        request("GET", "/v1/pair/sessions/${PercentEncoding.encode(PairCode.normalize(code))}/key").decode(PairKeyResponse.serializer())

    /** Phone (in-app sender): `POST /v1/pair/sessions/{code}/payload`. */
    public suspend fun pairSend(code: String, envelope: PairEnvelope) {
        post("/v1/pair/sessions/${PercentEncoding.encode(PairCode.normalize(code))}/payload", envelope, PairEnvelope.serializer())
            .decode(OkResponse.serializer())
    }

    /** TV: one poll `GET /v1/pair/sessions/{code}?secret=`. */
    public suspend fun pairPoll(code: String, secret: String): PairPollResult {
        val r = request("GET", "/v1/pair/sessions/${PercentEncoding.encode(PairCode.normalize(code))}?secret=${PercentEncoding.encode(secret)}")
        return when (r.status) {
            200 -> PairPollResult.Ready(r.decode(PairEnvelope.serializer()))
            202 -> PairPollResult.Pending
            404 -> PairPollResult.NotFound
            410 -> PairPollResult.Expired
            else -> throw BackendException(r.toError())
        }
    }

    override fun toString(): String = "BackendClient($baseUrl)"

    // ---------------------------------------------------------------- plumbing

    /** A completed HTTP exchange (body parsed as JSON when possible). */
    private class Exchange(val status: Int, val json: JsonElement?, val retryAfterSec: Long?) {
        val isSuccess: Boolean get() = status in 200..299

        val apiCode: String?
            get() = (json as? JsonObject)?.get("error")?.let { runCatching { it.jsonPrimitive.contentOrNull }.getOrNull() }

        fun toError(): BackendError {
            val body = json as? JsonObject
            val code = apiCode
            val message = body?.get("message")?.let { runCatching { it.jsonPrimitive.contentOrNull }.getOrNull() }
            return when {
                status == 401 -> BackendError.Unauthorized(code)
                status == 429 -> BackendError.RateLimited(retryAfterSec, code)
                status in 400..499 && code != null -> BackendError.Api(status, code, message)
                status in 200..299 -> BackendError.InvalidResponse
                else -> BackendError.ServerError(status, code)
            }
        }

        fun successJson(): JsonElement? {
            if (!isSuccess) throw BackendException(toError())
            return json
        }

        fun <T> decode(strategy: DeserializationStrategy<T>): T {
            val j = successJson() ?: throw BackendException(BackendError.InvalidResponse)
            return try {
                CoreJson.decodeFromJsonElement(strategy, j)
            } catch (e: SerializationException) {
                throw BackendException(BackendError.InvalidResponse, e)
            } catch (e: IllegalArgumentException) {
                throw BackendException(BackendError.InvalidResponse, e)
            }
        }
    }

    private suspend fun <T> post(path: String, body: T, serializer: kotlinx.serialization.SerializationStrategy<T>): Exchange =
        request("POST", path, CoreJson.encodeToJsonElement(serializer, body))

    private suspend fun request(method: String, pathAndQuery: String, body: JsonElement? = null, session: String? = null): Exchange {
        val url = baseUrl + pathAndQuery
        val req = try {
            Request.Builder().url(url).apply {
                header("User-Agent", userAgent)
                header("Accept", "application/json")
                if (session != null) header("Authorization", "Bearer $session")
                val rb = body?.toString()?.toRequestBody(JSON_MEDIA)
                method(method, rb ?: if (method == "POST" || method == "PUT") ByteArray(0).toRequestBody(JSON_MEDIA) else null)
            }.build()
        } catch (e: IllegalArgumentException) {
            throw BackendException(BackendError.InvalidResponse, e) // malformed base URL (config error)
        }
        val started = System.nanoTime()
        return try {
            client.executeCancellable(req, callTimeoutMs, dispatcher) { response ->
                val text = response.body?.string().orEmpty()
                log(LogLevel.DEBUG, "$method ${req.url.encodedPath} -> ${response.code} (${(System.nanoTime() - started) / 1_000_000} ms)")
                val json = if (text.isBlank()) null else runCatching { JSON_STRICT.parseToJsonElement(text) }.getOrNull()
                Exchange(response.code, json, response.header("Retry-After")?.trim()?.toLongOrNull())
            }
        } catch (e: CancellationException) {
            throw e
        } catch (e: IOException) {
            val err = if (NetworkErrorClassifier.isCancellation(e)) {
                BackendError.Cancelled
            } else {
                BackendError.Network(NetworkErrorClassifier.reason(e, connectivity.isOffline()))
            }
            log(LogLevel.WARN, "$method ${req.url.encodedPath} failed: ${err.code}")
            throw BackendException(err, e)
        }
    }

    private fun log(level: LogLevel, message: String) {
        logger.log(level, "Backend", redactor.redact(message), null)
    }

    private companion object {
        val JSON_MEDIA = "application/json; charset=utf-8".toMediaType()

        /** Strict parser: HTML must not be read as a lenient JSON string. */
        val JSON_STRICT = kotlinx.serialization.json.Json { ignoreUnknownKeys = true }
    }
}
