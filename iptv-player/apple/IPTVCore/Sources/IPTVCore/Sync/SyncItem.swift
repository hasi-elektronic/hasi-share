import Foundation

/// Kind of a synced item (CONTRACT §8).
public enum SyncKind: String, Codable, Sendable, Hashable {
    case favorite, progress
}

/// Payload of a sync item. Favorites use title/contentKind/posterUrl; progress items add
/// positionMs/durationMs/seriesKey (live channels: positionMs = 0).
public struct SyncItemData: Codable, Sendable, Hashable {
    public var title: String
    public var contentKind: ContentKind
    public var posterUrl: String?
    public var positionMs: Int64?
    public var durationMs: Int64?
    /// Content key of the series for episodes ("continue S02E05").
    public var seriesKey: String?

    public init(title: String, contentKind: ContentKind, posterUrl: String? = nil, positionMs: Int64? = nil,
                durationMs: Int64? = nil, seriesKey: String? = nil) {
        self.title = title
        self.contentKind = contentKind
        self.posterUrl = posterUrl
        self.positionMs = positionMs
        self.durationMs = durationMs
        self.seriesKey = seriesKey
    }

    /// Watched fraction 0…1 (nil without a positive duration).
    public var fraction: Double? {
        guard let positionMs, let durationMs, durationMs > 0 else { return nil }
        return min(1, max(0, Double(positionMs) / Double(durationMs)))
    }
}

/// A favorite or progress record, synchronized last-writer-wins (CONTRACT §8).
public struct SyncItem: Codable, Sendable, Hashable, Identifiable {
    /// `"fav:" + contentKey` or `"prog:" + contentKey`.
    public var key: String
    public var kind: SyncKind
    public var data: SyncItemData
    /// Client epoch ms of the last change.
    public var updatedAt: Int64
    public var deleted: Bool
    /// Server sequence number (only on items received from the server).
    public var seq: Int64?

    public var id: String { key }

    public init(key: String, kind: SyncKind, data: SyncItemData, updatedAt: Int64, deleted: Bool = false, seq: Int64? = nil) {
        self.key = key
        self.kind = kind
        self.data = data
        self.updatedAt = updatedAt
        self.deleted = deleted
        self.seq = seq
    }

    /// The content key embedded in `key`.
    public var contentKey: String {
        if key.hasPrefix("fav:") { return String(key.dropFirst(4)) }
        if key.hasPrefix("prog:") { return String(key.dropFirst(5)) }
        return key
    }

    public static func favoriteKey(_ contentKey: String) -> String { "fav:" + contentKey }
    public static func progressKey(_ contentKey: String) -> String { "prog:" + contentKey }

    /// New/updated favorite.
    public static func favorite(contentKey: String, title: String, contentKind: ContentKind, posterUrl: String?,
                                updatedAt: Int64, deleted: Bool = false) -> SyncItem {
        SyncItem(key: favoriteKey(contentKey), kind: .favorite,
                 data: SyncItemData(title: title, contentKind: contentKind, posterUrl: posterUrl),
                 updatedAt: updatedAt, deleted: deleted)
    }

    /// New/updated progress record.
    public static func progress(contentKey: String, title: String, contentKind: ContentKind, positionMs: Int64,
                                durationMs: Int64, posterUrl: String? = nil, seriesKey: String? = nil,
                                updatedAt: Int64) -> SyncItem {
        SyncItem(key: progressKey(contentKey), kind: .progress,
                 data: SyncItemData(title: title, contentKind: contentKind, posterUrl: posterUrl,
                                    positionMs: contentKind == .live ? 0 : positionMs, durationMs: durationMs,
                                    seriesKey: seriesKey),
                 updatedAt: updatedAt)
    }
}

/// Last-writer-wins merge (CONTRACT §8): an incoming item replaces the stored one only if
/// `incoming.updatedAt > stored.updatedAt` (ties keep the stored item).
public enum SyncMerge {
    public static func shouldApply(incoming: SyncItem, stored: SyncItem?) -> Bool {
        guard let stored else { return true }
        return incoming.updatedAt > stored.updatedAt
    }

    /// Merges `incoming` into `local` (keyed by `SyncItem.key`). Returns the merged map and
    /// the items that were applied (to persist / to refresh UI).
    public static func merge(local: [String: SyncItem], incoming: [SyncItem]) -> (merged: [String: SyncItem], applied: [SyncItem]) {
        var merged = local
        var applied: [SyncItem] = []
        for item in incoming where shouldApply(incoming: item, stored: merged[item.key]) {
            merged[item.key] = item
            applied.append(item)
        }
        return (merged, applied)
    }

    /// Local items that changed since the last successful push (to upload).
    public static func pending(_ items: [SyncItem], changedAfter lastPushMs: Int64) -> [SyncItem] {
        items.filter { $0.updatedAt > lastPushMs }.sorted { $0.updatedAt < $1.updatedAt }
    }
}

/// Home-screen selections over progress items (CONTRACT §8).
public enum WatchHistory {
    public static let completedFraction = 0.95
    public static let startedFraction = 0.05
    public static let recentLimit = 50

    /// ≥ 95 % watched.
    public static func isCompleted(positionMs: Int64, durationMs: Int64) -> Bool {
        durationMs > 0 && Double(positionMs) / Double(durationMs) >= completedFraction
    }

    /// "Continue watching": live progress items with 5 % < position/duration < 95 %, newest first.
    public static func continueWatching(_ items: [SyncItem], limit: Int? = nil) -> [SyncItem] {
        let selected = items.filter { item in
            guard item.kind == .progress, !item.deleted, let fraction = item.data.fraction else { return false }
            return fraction > startedFraction && fraction < completedFraction
        }.sorted { $0.updatedAt > $1.updatedAt }
        return limit.map { Array(selected.prefix($0)) } ?? selected
    }

    /// "Recently watched": most recent progress items of any kind, max 50 (or `kind` only).
    public static func recentlyWatched(_ items: [SyncItem], kind: ContentKind? = nil, limit: Int = recentLimit) -> [SyncItem] {
        Array(items.filter { $0.kind == .progress && !$0.deleted && (kind == nil || $0.data.contentKind == kind) }
            .sorted { $0.updatedAt > $1.updatedAt }
            .prefix(limit))
    }
}
