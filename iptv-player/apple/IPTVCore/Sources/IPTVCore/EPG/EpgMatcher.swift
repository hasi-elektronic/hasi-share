import Foundation

/// Maps playlist channels to XMLTV channel ids (CONTRACT §5):
/// 1. `Channel.epgId` equals an XMLTV channel id (case-insensitive);
/// 2. fallback: the normalized channel name equals a normalized `display-name`
///    (see `NameNormalizer`). The first XMLTV channel wins on collisions.
public struct EpgMatcher: Sendable {
    private var idsByLowercased: [String: String] = [:]
    private var idsByName: [String: String] = [:]

    public init() {}

    /// Builds a matcher from the guide's channel list.
    public init(channels: [XMLTVChannel]) {
        for channel in channels { add(channel) }
    }

    /// Adds one XMLTV channel.
    public mutating func add(_ channel: XMLTVChannel) {
        addId(channel.id)
        for name in channel.displayNames {
            let key = NameNormalizer.normalize(name)
            if !key.isEmpty, idsByName[key] == nil { idsByName[key] = channel.id }
        }
    }

    /// Registers a programme channel id that has no `<channel>` element.
    public mutating func addId(_ id: String) {
        let key = id.lowercased()
        if !key.isEmpty, idsByLowercased[key] == nil { idsByLowercased[key] = id }
    }

    /// The XMLTV channel id for a playlist channel, or nil.
    public func match(epgId: String?, name: String) -> String? {
        if let epgId, !epgId.isEmpty, let id = idsByLowercased[epgId.lowercased()] { return id }
        let key = NameNormalizer.normalize(name)
        return key.isEmpty ? nil : idsByName[key]
    }

    /// Convenience for a `Channel`.
    public func match(_ channel: Channel) -> String? {
        match(epgId: channel.epgId, name: channel.name)
    }

    public var isEmpty: Bool { idsByLowercased.isEmpty }
}

/// EPG retention (CONTRACT §5): keep `[now − max(catchupDays, 1 day), now + 7 days]`.
public enum EpgRetention {
    public static let futureDays = 7

    /// Storage window for programmes.
    public static func window(now: Date, catchupDays: Int) -> DateInterval {
        let past = TimeInterval(max(catchupDays, 1)) * 86_400
        return DateInterval(start: now.addingTimeInterval(-past), end: now.addingTimeInterval(TimeInterval(futureDays) * 86_400))
    }

    /// True if a programme overlaps the window.
    public static func isRetained(start: Date, end: Date, in window: DateInterval) -> Bool {
        end > window.start && start < window.end
    }
}
