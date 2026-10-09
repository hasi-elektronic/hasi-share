package io.iptvplayer.shared.license

import android.content.Context
import android.os.Build
import android.os.SystemClock
import android.provider.Settings
import io.iptvplayer.core.CoreConstants
import io.iptvplayer.core.backend.BackendClient
import io.iptvplayer.core.backend.BackendError
import io.iptvplayer.core.backend.BackendException
import io.iptvplayer.core.backend.GooglePurchases
import io.iptvplayer.core.backend.LicenseSyncRequest
import io.iptvplayer.core.license.AccessDecision
import io.iptvplayer.core.license.AccessPolicy
import io.iptvplayer.core.license.AccessState
import io.iptvplayer.core.license.LicenseClaims
import io.iptvplayer.core.license.LicenseTokenVerifier
import io.iptvplayer.core.license.LicenseVerification
import io.iptvplayer.core.license.PlatformStore
import io.iptvplayer.core.license.StoreState
import io.iptvplayer.core.license.TrustedClock
import io.iptvplayer.core.license.TrustedClockState
import io.iptvplayer.shared.billing.BillingSnapshot
import io.iptvplayer.shared.billing.StoreBilling
import io.iptvplayer.shared.log.SafeLog
import io.iptvplayer.shared.settings.SettingsRepository
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlin.coroutines.cancellation.CancellationException

/** Device clocks used by the trusted clock (CONTRACT §7.3). */
interface DeviceClocks {
    fun wallMs(): Long
    fun monoMs(): Long

    /** `Settings.Global.BOOT_COUNT` (API 24+), "" when unknown. */
    fun bootId(): String
}

class AndroidClocks(private val context: Context) : DeviceClocks {
    override fun wallMs(): Long = System.currentTimeMillis()
    override fun monoMs(): Long = SystemClock.elapsedRealtime()
    override fun bootId(): String = if (Build.VERSION.SDK_INT >= 24) {
        runCatching { Settings.Global.getInt(context.contentResolver, Settings.Global.BOOT_COUNT).toString() }.getOrDefault("")
    } else {
        ""
    }
}

/** UI-facing license state. */
data class LicenseState(
    val decision: AccessDecision = AccessDecision(AccessState.TRIAL_NOT_STARTED, null, false),
    val nowMs: Long = 0,
    val trialDays: Int = CoreConstants.DEFAULT_TRIAL_DAYS,
    /** Source of a purchase granted by the token (`google`, `account`, `admin`). */
    val purchaseSource: String? = null,
    val hasToken: Boolean = false,
    val tokenStale: Boolean = false,
    /** Last backend failure (null after a successful sync). */
    val backendError: BackendError? = null,
    val syncing: Boolean = false,
    val loaded: Boolean = false,
) {
    val canPlay: Boolean get() = decision.canPlay

    /** Remaining trial time in ms (0 when not active). */
    val trialRemainingMs: Long
        get() = if (decision.state == AccessState.TRIAL_ACTIVE) ((decision.trialEndMs ?: 0) - nowMs).coerceAtLeast(0) else 0
}

/** Result of [LicenseManager.startTrial]. */
sealed interface TrialStartResult {
    data object Started : TrialStartResult
    data object AlreadyUsed : TrialStartResult

    /** No backend reachable and no token → trial cannot start on Android (ARCHITECTURE V9). */
    data class BackendUnavailable(val error: BackendError?) : TrialStartResult
}

/**
 * Licensing (CONTRACT §7, ARCHITECTURE §4): backend `/v1/license/sync` → signed token (verified
 * with the embedded JWK set), [TrustedClock] anchored on the server time + `elapsedRealtime` +
 * `BOOT_COUNT`, [AccessPolicy] with the Play Billing store state. When the backend is unreachable
 * the last known valid token is used; if there never was one, the trial cannot start (V9).
 * Unacknowledged purchases are acknowledged by the client when the backend cannot do it.
 */
class LicenseManager(
    private val backend: BackendClient?,
    private val billing: StoreBilling,
    private val settings: SettingsRepository,
    private val verifier: LicenseTokenVerifier,
    private val clocks: DeviceClocks,
    private val deviceKey: () -> String,
    private val appId: String,
    private val appVersion: String,
    private val platform: () -> String,
    private val sessionToken: () -> String?,
    private val scope: CoroutineScope,
) {
    private val _state = MutableStateFlow(LicenseState())
    val state: StateFlow<LicenseState> = _state

    private val mutex = Mutex()
    private var claims: LicenseClaims? = null
    private var clock: TrustedClockState? = null
    private var trialDays: Int = CoreConstants.DEFAULT_TRIAL_DAYS

    /** Loads the cached token, starts observing billing and periodic re-evaluation. */
    fun start() {
        scope.launch {
            val cache = settings.licenseCache()
            clock = cache.clock
            trialDays = cache.trialDays ?: CoreConstants.DEFAULT_TRIAL_DAYS
            claims = cache.token?.let { verify(it) }
            if (cache.token != null && claims == null) {
                SafeLog.w(TAG, "cached license token rejected – dropped")
                settings.saveLicense(null, clock, null, null)
            }
            recompute(loaded = true)
            sync()
        }
        scope.launch {
            billing.state.map { it.storeState to it.purchases.map { p -> p.purchaseToken } }.distinctUntilChanged().collect { (store, tokens) ->
                recompute()
                if (store == StoreState.PURCHASED && tokens.isNotEmpty() && _state.value.loaded) sync()
            }
        }
        scope.launch {
            while (isActive) {
                delay(30_000)
                recompute()
            }
        }
    }

    /** Trusted now (CONTRACT §7.3). */
    fun nowMs(): Long = TrustedClock.now(clock, clocks.wallMs(), clocks.monoMs(), clocks.bootId())

    /** `POST /v1/license/sync` with the current store purchases. */
    suspend fun sync(startTrial: Boolean = false): BackendError? = mutex.withLock {
        val client = backend ?: return@withLock BackendError.Network(io.iptvplayer.core.error.NetworkReason.OTHER).also { fallback(it) }
        _state.update { it.copy(syncing = true) }
        try {
            runCatching { client.config() }.getOrNull()?.let { cfg ->
                trialDays = cfg.trialDays
                cfg.serverTime?.let { observeServerTime(it) }
            }
            val snap: BillingSnapshot = billing.state.value
            val req = LicenseSyncRequest(
                platform = platform(),
                appId = appId,
                appVersion = appVersion,
                deviceKey = deviceKey(),
                startTrial = startTrial,
                google = snap.purchases.takeIf { it.isNotEmpty() }?.let { GooglePurchases(it) },
            )
            val result = client.licenseSync(req, sessionToken())
            observeServerTime(result.response.serverTime)
            val verified = verify(result.response.token)
            if (verified == null) {
                SafeLog.w(TAG, "server token failed verification (kid/signature/aud)")
                val err = BackendError.InvalidResponse
                _state.update { it.copy(backendError = err) }
                fallback(err)
                return@withLock err
            }
            claims = verified
            settings.saveLicense(result.response.token, clock, trialDays, clocks.wallMs())
            _state.update { it.copy(backendError = result.partialError) }
            recompute()
            null
        } catch (e: CancellationException) {
            throw e
        } catch (e: BackendException) {
            SafeLog.w(TAG, "license sync failed: ${e.error.code}")
            _state.update { it.copy(backendError = e.error) }
            fallback(e.error)
            recompute()
            e.error
        } finally {
            // Persist the trusted-clock anchor and trial days even when the sync itself failed.
            settings.saveLicense(settings.licenseCache().token, clock, trialDays, null)
            _state.update { it.copy(syncing = false) }
        }
    }

    /** "Start free trial" (CONTRACT §7.5): never silent, needs the backend on Android. */
    suspend fun startTrial(): TrialStartResult {
        val before = claims?.lic
        if (before?.trialEnd != null) return if (_state.value.decision.state == AccessState.TRIAL_ACTIVE) TrialStartResult.Started else TrialStartResult.AlreadyUsed
        val err = sync(startTrial = true)
        val after = claims?.lic
        return when {
            after?.trialEnd == null -> TrialStartResult.BackendUnavailable(err)
            _state.value.decision.state == AccessState.TRIAL_EXPIRED -> TrialStartResult.AlreadyUsed
            else -> TrialStartResult.Started
        }
    }

    /** Backend unreachable: acknowledge store purchases ourselves (3-day refund protection). */
    private suspend fun fallback(error: BackendError) {
        if (error is BackendError.Api) return
        for (t in billing.state.value.unacknowledged) {
            val ok = billing.acknowledge(t)
            SafeLog.i(TAG, "client acknowledge fallback: $ok")
        }
    }

    private fun observeServerTime(serverMs: Long) {
        clock = TrustedClock.update(clock, TrustedClockState(serverMs, clocks.monoMs(), clocks.bootId()))
    }

    private fun verify(token: String): LicenseClaims? {
        val v = verifier.verify(token, clocks.wallMs() / 1000)
        if (v !is LicenseVerification.Valid) return null
        if (v.claims.sub != deviceKey()) return null
        return v.claims
    }

    private fun recompute(loaded: Boolean? = null) {
        val now = nowMs()
        val c = claims
        val decision = AccessPolicy.evaluate(
            platformStore = PlatformStore.GOOGLE,
            store = billing.state.value.storeState,
            token = c?.lic,
            localTrialStartMs = null,
            trialDays = trialDays,
            nowMs = now,
        )
        _state.update {
            it.copy(
                decision = decision,
                nowMs = now,
                trialDays = trialDays,
                purchaseSource = if (billing.state.value.storeState == StoreState.PURCHASED) "google" else c?.lic?.src?.takeIf { c.lic.purchased },
                hasToken = c != null,
                tokenStale = c != null && clocks.wallMs() / 1000 >= c.exp,
                loaded = loaded ?: it.loaded,
            )
        }
    }

    companion object {
        private const val TAG = "License"
    }
}
