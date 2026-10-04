package io.iptvplayer.core.backend

import io.iptvplayer.core.crypto.EcPublicJwk
import io.iptvplayer.core.error.NetworkReason
import io.iptvplayer.core.license.LicenseInfo
import io.iptvplayer.core.pairing.PairEnvelope
import io.iptvplayer.core.sync.SyncItem
import kotlinx.serialization.Serializable

// DTOs of spec/BACKEND_API.md. Unknown fields are ignored (CoreJson), so the server can evolve.

// ------------------------------------------------------------------ errors

/**
 * Errors of backend calls (license, account, sync, pairing). Mirrors the source error model
 * (CONTRACT §2): same [NetworkReason]s, stable [code]s. Error bodies are
 * `{"error": "<code>", "message": "…"}` (BACKEND_API.md).
 */
public sealed interface BackendError {
    /** Stable code for logging / persistence. */
    public val code: String

    /** True for transient failures worth retrying later (network, 5xx, 429). */
    public val isRetryable: Boolean
        get() = when (this) {
            is Network -> reason != NetworkReason.OFFLINE
            is ServerError, is RateLimited -> true
            else -> false
        }

    /** Network failure (same classification as source requests). */
    public data class Network(val reason: NetworkReason) : BackendError {
        override val code: String get() = "network:${reason.wire}"
    }

    /** HTTP 401: missing/invalid/expired session → sign the user out locally. */
    public data class Unauthorized(val apiCode: String? = null) : BackendError {
        override val code: String get() = "unauthorized"
    }

    /** HTTP 429 (`retry-after` seconds when sent). Device-code polling maps `slow_down` separately. */
    public data class RateLimited(val retryAfterSec: Long?, val apiCode: String? = null) : BackendError {
        override val code: String get() = "rate_limited"
    }

    /** Other 4xx with an API error code (e.g. `invalid_code`, `feature_disabled`, `already_used`). */
    public data class Api(val httpStatus: Int, val apiCode: String, val message: String?) : BackendError {
        override val code: String get() = "api:$httpStatus:$apiCode"
    }

    /** 5xx (and non-JSON non-2xx). */
    public data class ServerError(val httpStatus: Int, val apiCode: String? = null) : BackendError {
        override val code: String get() = "server_error:$httpStatus"
    }

    /** 2xx/4xx body is not the expected JSON (captive portal, proxy error page …). */
    public data object InvalidResponse : BackendError {
        override val code: String get() = "invalid_response"
    }

    /** The call was cancelled. */
    public data object Cancelled : BackendError {
        override val code: String get() = "cancelled"
    }
}

/** Exception carrying a [BackendError]. */
public class BackendException(public val error: BackendError, cause: Throwable? = null) : Exception(error.code, cause)

/** Error body `{"error", "message", …}`. */
@Serializable
public data class ApiErrorBody(val error: String = "", val message: String? = null)

// ------------------------------------------------------------------ config

@Serializable
public data class BackendProducts(
    val google: String? = null,
    val appleLifetime: String? = null,
    val appleTrial: String? = null,
)

@Serializable
public data class BackendFeatures(val accounts: Boolean = false, val pairing: Boolean = false, val sync: Boolean = false)

/** `GET /v1/config`. [serverTime] epoch ms. */
@Serializable
public data class BackendConfig(
    val trialDays: Int = 7,
    val minVersion: Map<String, Int> = emptyMap(),
    val products: BackendProducts = BackendProducts(),
    val features: BackendFeatures = BackendFeatures(),
    val serverTime: Long? = null,
)

// ------------------------------------------------------------------ license

/** `platform` values of `/v1/license/sync` and `/v1/auth/device/start`. */
public object BackendPlatform {
    public const val ANDROID: String = "android"
    public const val ANDROID_TV: String = "androidtv"
    public const val IOS: String = "ios"
    public const val TVOS: String = "tvos"
}

@Serializable
public data class GooglePurchase(val productId: String, val purchaseToken: String) {
    override fun toString(): String = "GooglePurchase(productId=$productId, purchaseToken=***)"
}

@Serializable
public data class GooglePurchases(val purchases: List<GooglePurchase>)

@Serializable
public data class ApplePurchases(val trialTransactionId: String? = null, val transactionIds: List<String> = emptyList())

/** Body of `POST /v1/license/sync`. */
@Serializable
public data class LicenseSyncRequest(
    val platform: String,
    val appId: String,
    val appVersion: String,
    val deviceKey: String,
    val startTrial: Boolean = false,
    val google: GooglePurchases? = null,
    val apple: ApplePurchases? = null,
)

/** Response of `POST /v1/license/sync` ([serverTime] epoch ms). */
@Serializable
public data class LicenseSyncResponse(val token: String, val license: LicenseInfo, val serverTime: Long)

/**
 * Result of [BackendClient.licenseSync]. A `422 store_verification_failed` /
 * `503 store_unavailable` response still carries a token for the remaining state; it is returned
 * here with [partialError] set (retry the store verification later).
 */
public data class LicenseSyncResult(val response: LicenseSyncResponse, val partialError: BackendError? = null)

// ------------------------------------------------------------------ accounts

@Serializable
public data class EmailStartRequest(val email: String, val locale: String)

/** [devCode] only when the backend runs with `DEV_MODE=true`. */
@Serializable
public data class EmailStartResponse(val ok: Boolean = true, val devCode: String? = null)

@Serializable
public data class EmailVerifyRequest(val email: String, val code: String, val deviceName: String)

@Serializable
public data class AccountRef(val id: String, val email: String)

/** Successful login. Store [sessionToken] only in encrypted storage; never log it. */
@Serializable
public data class SessionResponse(val sessionToken: String, val account: AccountRef) {
    override fun toString(): String = "SessionResponse(sessionToken=***, account=$account)"
}

@Serializable
public data class OkResponse(val ok: Boolean = true)

@Serializable
public data class AccountLicense(
    val store: String,
    val status: String,
    val purchasedAt: Long? = null,
    val productId: String? = null,
)

/** Account trial window, epoch **seconds** (same values as the token's trialStart/trialEnd). */
@Serializable
public data class AccountTrial(val start: Long, val end: Long)

/** `GET /v1/account`. */
@Serializable
public data class AccountResponse(
    val id: String,
    val email: String,
    val createdAt: Long? = null,
    val licenses: List<AccountLicense> = emptyList(),
    val trial: AccountTrial? = null,
)

@Serializable
public data class DeviceStartRequest(val platform: String, val deviceName: String)

/** `POST /v1/auth/device/start`. [interval]/[expiresIn] in seconds. */
@Serializable
public data class DeviceStartResponse(
    val deviceCode: String,
    val userCode: String,
    val verificationUrl: String,
    val verificationUrlComplete: String,
    val interval: Int = 5,
    val expiresIn: Int = 600,
) {
    override fun toString(): String = "DeviceStartResponse(deviceCode=***, userCode=$userCode, interval=$interval)"
}

/** Outcome of one `POST /v1/auth/device/poll`. */
public sealed interface DevicePollResult {
    /** 428 `authorization_pending`: keep polling every `interval` seconds. */
    public data object Pending : DevicePollResult

    /** 429 `slow_down`: increase the interval to [intervalSec]. */
    public data class SlowDown(val intervalSec: Int) : DevicePollResult

    /** 410 `expired_token`: restart the flow. */
    public data object Expired : DevicePollResult

    /** 200: signed in. */
    public data class Approved(val session: SessionResponse) : DevicePollResult
}

// ------------------------------------------------------------------ sync

/** One page of `GET /v1/sync` (malformed items are dropped and counted in [skipped]). */
public data class SyncPage(val items: List<SyncItem>, val cursor: Long, val hasMore: Boolean, val skipped: Int = 0)

@Serializable
public data class SyncRejected(val key: String? = null, val reason: String = "")

/** `POST /v1/sync`. */
@Serializable
public data class SyncPushResponse(val applied: Int = 0, val cursor: Long = 0, val rejected: List<SyncRejected> = emptyList())

// ------------------------------------------------------------------ pairing

/** `POST /v1/pair/sessions`. [expiresAt] epoch ms. Keep [secret] in memory only. */
@Serializable
public data class PairSessionResponse(
    val code: String,
    val secret: String,
    val expiresAt: Long,
    val pairUrl: String,
    val expiresIn: Int? = null,
) {
    override fun toString(): String = "PairSessionResponse(code=$code, secret=***, expiresAt=$expiresAt)"
}

/** `GET /v1/pair/sessions/{code}/key`. */
@Serializable
public data class PairKeyResponse(val publicKey: EcPublicJwk, val expiresAt: Long? = null)

/** Outcome of one TV poll `GET /v1/pair/sessions/{code}?secret=`. */
public sealed interface PairPollResult {
    /** 202: nothing sent yet, poll again in 2 s. */
    public data object Pending : PairPollResult

    /** 200: the encrypted payload (deleted server-side now). */
    public data class Ready(val envelope: PairEnvelope) : PairPollResult

    /** 410: code expired – create a new session. */
    public data object Expired : PairPollResult

    /** 404: unknown code / wrong secret / already delivered. */
    public data object NotFound : PairPollResult
}
