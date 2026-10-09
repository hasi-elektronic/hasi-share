package io.iptvplayer.core.license

import io.iptvplayer.core.CoreConstants

/** Local store state of the lifetime product (Play Billing / StoreKit 2), CONTRACT §7.4. */
public enum class StoreState(public val wire: String) {
    NONE("none"),
    PENDING("pending"),
    PURCHASED("purchased"),
    REVOKED("revoked"),
    ;

    public companion object {
        public fun fromWire(v: String): StoreState = entries.first { it.wire == v }
    }
}

/** Store of the running platform family (`lic.src` value it corresponds to). */
public enum class PlatformStore(public val wire: String) {
    GOOGLE("google"),
    APPLE("apple"),
    ;

    public companion object {
        public fun fromWire(v: String): PlatformStore = entries.first { it.wire == v }
    }
}

/** Access state machine (docs/ARCHITECTURE.md §4.1). */
public enum class AccessState { TRIAL_NOT_STARTED, TRIAL_ACTIVE, TRIAL_EXPIRED, PURCHASED }

/** Output of [AccessPolicy.evaluate]. */
public data class AccessDecision(
    val state: AccessState,
    /** Trial end in epoch ms (also reported when purchased), null when no trial is known. */
    val trialEndMs: Long?,
    /** A purchase is pending (banner only, grants nothing). */
    val pendingPurchase: Boolean,
) {
    /** The player is unlocked. */
    val canPlay: Boolean get() = state == AccessState.PURCHASED || state == AccessState.TRIAL_ACTIVE
}

/**
 * Pure access policy, identical on every platform (CONTRACT §7.4, `access-policy.json`).
 * ```
 * purchasedByStore   = store == purchased
 * purchasedByLicense = token.lic.purchased && !(store == revoked && token.lic.src == platformStore)
 * trialEndMs         = token.lic.trialEnd*1000 ?: localTrialStartMs + trialDays*86_400_000
 * ```
 */
public object AccessPolicy {
    private const val DAY_MS = 86_400_000L

    /**
     * @param token `lic` claims of a **validated** token, or null.
     * @param localTrialStartMs Apple only (verified trial transaction date); null on Android.
     * @param trialDays last known server config (default 7).
     * @param nowMs trusted clock ([TrustedClock]).
     */
    public fun evaluate(
        platformStore: PlatformStore,
        store: StoreState,
        token: LicenseInfo?,
        localTrialStartMs: Long? = null,
        trialDays: Int = CoreConstants.DEFAULT_TRIAL_DAYS,
        nowMs: Long,
    ): AccessDecision {
        val purchasedByStore = store == StoreState.PURCHASED
        val purchasedByLicense = token?.purchased == true &&
            !(store == StoreState.REVOKED && token.src == platformStore.wire)
        val trialEndMs = token?.trialEnd?.let { it * 1000 }
            ?: localTrialStartMs?.let { it + trialDays * DAY_MS }
        val state = when {
            purchasedByStore || purchasedByLicense -> AccessState.PURCHASED
            trialEndMs != null && nowMs < trialEndMs -> AccessState.TRIAL_ACTIVE
            trialEndMs != null -> AccessState.TRIAL_EXPIRED
            else -> AccessState.TRIAL_NOT_STARTED
        }
        return AccessDecision(state, trialEndMs, pendingPurchase = store == StoreState.PENDING)
    }
}
