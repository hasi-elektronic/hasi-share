package io.iptvplayer.core.retry

import io.iptvplayer.core.error.SourceError

/**
 * Retry policy for idempotent source GETs (CONTRACT §2): at most 2 retries (2 s, 4 s) on
 * `Network` / `ServerError(5xx)`; never on 4xx. Offline is not retried (pointless, and the
 * user should see "no internet" immediately).
 */
public data class SourceRetryPolicy(val delaysMs: List<Long> = listOf(2_000L, 4_000L)) {
    /** Maximum number of retries. */
    val maxRetries: Int get() = delaysMs.size

    /** Delay before the next retry, or null when [error] must not be retried (anymore). */
    public fun delayBeforeRetry(error: SourceError, retriesSoFar: Int): Long? =
        if (error.isRetryable && retriesSoFar in delaysMs.indices) delaysMs[retriesSoFar] else null

    public companion object {
        /** CONTRACT default (2 s, 4 s). */
        public val DEFAULT: SourceRetryPolicy = SourceRetryPolicy()

        /** No retries. */
        public val NONE: SourceRetryPolicy = SourceRetryPolicy(emptyList())
    }
}

/** Decision of [ReconnectPolicy.onError]. */
public sealed interface ReconnectDecision {
    /** Retry attempt [attempt] of [maxAttempts] after [delayMs] ("Reconnecting… (2/5)"). */
    public data class Retry(val attempt: Int, val maxAttempts: Int, val delayMs: Long) : ReconnectDecision

    /** Give up after [attempts] attempts → show the error card. */
    public data class GiveUp(val attempts: Int) : ReconnectDecision
}

/**
 * Immutable state of the playback reconnect machine.
 * @property attempts reconnect attempts made in the current failure streak.
 * @property playingSinceMs when playback (re)started successfully, null while failing/buffering.
 */
public data class ReconnectState(val attempts: Int = 0, val playingSinceMs: Long? = null)

/**
 * Playback reconnect policy (docs/SCREENS.md §3.7): delays 1, 2, 4, 8, 15 s, max 5 attempts;
 * the attempt counter resets once playback has been stable for 30 s.
 *
 * Pure state machine: the player layer drives it with
 * [onPlaying] (STATE_READY + playWhenReady), [onError] (recoverable error) and [reset]
 * (user retry / channel change). Time is passed in (monotonic ms) so it is fully testable.
 */
public class ReconnectPolicy(
    public val delaysMs: List<Long> = listOf(1_000L, 2_000L, 4_000L, 8_000L, 15_000L),
    public val stableResetMs: Long = 30_000L,
) {
    /** Maximum attempts in one failure streak. */
    public val maxAttempts: Int get() = delaysMs.size

    /** Current state. */
    public var state: ReconnectState = ReconnectState()
        private set

    /** Pure transition for [onPlaying]. */
    public fun playing(s: ReconnectState, nowMs: Long): ReconnectState =
        if (s.playingSinceMs != null) s else s.copy(playingSinceMs = nowMs)

    /** Pure transition for [onError]: returns the new state and the decision. */
    public fun error(s: ReconnectState, nowMs: Long): Pair<ReconnectState, ReconnectDecision> {
        val since = s.playingSinceMs
        val base = if (since != null && nowMs - since >= stableResetMs) 0 else s.attempts
        if (base >= maxAttempts) {
            return ReconnectState(attempts = base, playingSinceMs = null) to ReconnectDecision.GiveUp(base)
        }
        val next = base + 1
        return ReconnectState(attempts = next, playingSinceMs = null) to
            ReconnectDecision.Retry(attempt = next, maxAttempts = maxAttempts, delayMs = delaysMs[base])
    }

    /** Pure stability check: resets the counter when playing for ≥ [stableResetMs]. */
    public fun tick(s: ReconnectState, nowMs: Long): ReconnectState {
        val since = s.playingSinceMs ?: return s
        return if (s.attempts > 0 && nowMs - since >= stableResetMs) s.copy(attempts = 0) else s
    }

    /** Playback is running (again). */
    public fun onPlaying(nowMs: Long) {
        state = playing(state, nowMs)
    }

    /** A recoverable playback error happened; returns what to do. */
    public fun onError(nowMs: Long): ReconnectDecision {
        val (s, d) = error(state, nowMs)
        state = s
        return d
    }

    /** Periodic check (optional): resets the counter after stable playback. */
    public fun onTick(nowMs: Long) {
        state = tick(state, nowMs)
    }

    /** Resets everything (manual retry, new stream). */
    public fun reset() {
        state = ReconnectState()
    }
}
