import Foundation

/// The live channel that was playing when the app last left the player (docs/SCREENS.md §3.2 QuickStart).
public struct LastSession: Codable, Sendable, Equatable {
    public var sourceId: String
    public var channelId: String
    /// true if the app went to background/terminated while this live channel was playing
    public var endedInPlayer: Bool
    public init(sourceId: String, channelId: String, endedInPlayer: Bool) {
        self.sourceId = sourceId; self.channelId = channelId; self.endedInPlayer = endedInPlayer
    }
}

public enum QuickStartDecision: Equatable { case none, play(sourceId: String, channelId: String) }

public enum QuickStart {
    public static func decide(enabled: Bool, last: LastSession?, canPlay: Bool, channelExists: Bool) -> QuickStartDecision {
        guard enabled, let last, last.endedInPlayer, canPlay, channelExists else { return .none }
        return .play(sourceId: last.sourceId, channelId: last.channelId)
    }

    /// Whether a launch without quick start should consume `endedInPlayer` (the session can never resume:
    /// the feature is off or the channel is gone). A transient `canPlay == false` (StoreKit entitlements not
    /// loaded yet, trial expired) must NOT consume it – that would wipe the session for good.
    public static func shouldDiscard(enabled: Bool, last: LastSession?, channelExists: Bool) -> Bool {
        guard let last, last.endedInPlayer else { return false }
        return !enabled || !channelExists
    }

    /// Upper bound for waiting on the first StoreKit entitlement snapshot before deciding.
    public static let entitlementTimeout: Duration = .milliseconds(1500)

    /// Waits for `task` until `deadline` at the latest; true when it finished in time. The task is not
    /// cancelled – it keeps running past the deadline (e.g. the TestFlight `AppTransaction` confirmation,
    /// which must not hold the launch beyond QuickStart's own wait).
    public static func wait(for task: Task<Void, Never>, until deadline: ContinuousClock.Instant) async -> Bool {
        let gate = ResumeOnce()
        let result = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            gate.set(continuation)
            gate.timer = Task { try? await Task.sleep(until: deadline, clock: .continuous); gate.resume(false) }
            Task { await task.value; gate.resume(true) }
        }
        gate.cancelTimer()
        return result
    }
}

/// Resumes a continuation once (first of task completion / deadline wins).
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, Never>?
    private var _timer: Task<Void, Never>?

    var timer: Task<Void, Never>? {
        get { lock.withLock { _timer } }
        set { lock.withLock { _timer = newValue } }
    }

    func set(_ continuation: CheckedContinuation<Bool, Never>) { lock.withLock { self.continuation = continuation } }

    func resume(_ value: Bool) {
        let c: CheckedContinuation<Bool, Never>? = lock.withLock {
            defer { continuation = nil }
            return continuation
        }
        c?.resume(returning: value)
    }

    func cancelTimer() { timer?.cancel() }
}
