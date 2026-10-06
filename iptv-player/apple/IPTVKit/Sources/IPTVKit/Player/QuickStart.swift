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
}
