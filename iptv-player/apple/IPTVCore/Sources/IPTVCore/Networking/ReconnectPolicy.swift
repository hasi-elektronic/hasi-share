import Foundation

/// Decision of `ReconnectPolicy.error(_:nowMs:)`.
public enum ReconnectDecision: Sendable, Hashable {
    /// Retry attempt `attempt` of `maxAttempts` after `delayMs` ("Reconnecting… (2/5)").
    case retry(attempt: Int, maxAttempts: Int, delayMs: Int64)
    /// Give up after `attempts` attempts → show the error card.
    case giveUp(attempts: Int)
}

/// Immutable state of the playback reconnect machine.
public struct ReconnectState: Sendable, Hashable {
    /// Reconnect attempts made in the current failure streak.
    public var attempts: Int
    /// When playback (re)started successfully (monotonic ms); nil while failing/buffering.
    public var playingSinceMs: Int64?

    public init(attempts: Int = 0, playingSinceMs: Int64? = nil) {
        self.attempts = attempts
        self.playingSinceMs = playingSinceMs
    }
}

/// Playback reconnect policy (docs/ARCHITECTURE.md §3, docs/SCREENS.md): delays 1, 2, 4, 8,
/// 15 s, at most 5 attempts; the attempt counter resets once playback has been stable for
/// 30 s. Pure state machine – the player layer drives it with `playing` (ready + playing),
/// `error` (recoverable error) and `tick`; time is passed in (monotonic ms) so it is fully
/// testable. Identical to the Kotlin `ReconnectPolicy`.
public struct ReconnectPolicy: Sendable, Hashable {
    public var delaysMs: [Int64]
    public var stableResetMs: Int64

    public init(delaysMs: [Int64] = [1_000, 2_000, 4_000, 8_000, 15_000], stableResetMs: Int64 = 30_000) {
        self.delaysMs = delaysMs
        self.stableResetMs = stableResetMs
    }

    /// Maximum attempts in one failure streak.
    public var maxAttempts: Int { delaysMs.count }

    /// Playback is running (again).
    public func playing(_ state: ReconnectState, nowMs: Int64) -> ReconnectState {
        guard state.playingSinceMs == nil else { return state }
        var s = state
        s.playingSinceMs = nowMs
        return s
    }

    /// A recoverable playback error happened: the new state and what to do.
    public func error(_ state: ReconnectState, nowMs: Int64) -> (state: ReconnectState, decision: ReconnectDecision) {
        var base = state.attempts
        if let since = state.playingSinceMs, nowMs - since >= stableResetMs { base = 0 }
        guard base < maxAttempts else {
            return (ReconnectState(attempts: base, playingSinceMs: nil), .giveUp(attempts: base))
        }
        let next = base + 1
        return (ReconnectState(attempts: next, playingSinceMs: nil),
                .retry(attempt: next, maxAttempts: maxAttempts, delayMs: delaysMs[base]))
    }

    /// Periodic stability check: resets the counter after ≥ `stableResetMs` of playback.
    public func tick(_ state: ReconnectState, nowMs: Int64) -> ReconnectState {
        guard let since = state.playingSinceMs, state.attempts > 0, nowMs - since >= stableResetMs else { return state }
        var s = state
        s.attempts = 0
        return s
    }
}
