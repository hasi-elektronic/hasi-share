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
}
