package io.iptvplayer.core.license

import kotlinx.serialization.Serializable

/**
 * Persisted anchor of the trusted clock (CONTRACT §7.3): last known server time [serverMs],
 * the monotonic clock [monoMs] at that moment (Android `SystemClock.elapsedRealtime()`) and the
 * [bootId] (Android `Settings.Global.BOOT_COUNT`, "" when unknown).
 */
@Serializable
public data class TrustedClockState(val serverMs: Long, val monoMs: Long, val bootId: String)

/**
 * Trusted "now" that never relies on the device wall clock alone (CONTRACT §7.3):
 * ```
 * now(wall, mono, boot):
 *   state == null                                          → wall
 *   boot != "" && boot == state.bootId && mono >= state.mono → state.server + (mono − state.mono)
 *   else                                                   → max(wall, state.server)
 * ```
 * Pure functions; the Android layer persists the state (DataStore).
 */
public object TrustedClock {
    /** Trusted epoch ms. */
    public fun now(state: TrustedClockState?, deviceWallMs: Long, monoNowMs: Long, bootIdNow: String): Long {
        if (state == null) return deviceWallMs
        if (bootIdNow.isNotEmpty() && bootIdNow == state.bootId && monoNowMs >= state.monoMs) {
            return state.serverMs + (monoNowMs - state.monoMs)
        }
        return maxOf(deviceWallMs, state.serverMs)
    }

    /**
     * Applies a new server time observation (e.g. token `iat`, `serverTime`): replaces the state
     * only if the new server time is later than the stored one.
     */
    public fun update(state: TrustedClockState?, observed: TrustedClockState): TrustedClockState =
        if (state == null || observed.serverMs > state.serverMs) observed else state
}
