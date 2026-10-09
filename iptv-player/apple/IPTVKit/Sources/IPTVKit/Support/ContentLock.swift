import Foundation
import IPTVCore

/// Parental lock state the catalog queries apply (docs/SCREENS.md §3.10, ARCHITECTURE "Ebeveyn kilidi"): locked
/// categories per source and kind, individually locked channels, and whether locked content is hidden or listed
/// with a lock. Only set while a PIN exists and the session is locked (`ParentalControl.filter`).
///
/// Rules (CatalogRepository):
/// * an item is **locked** when it belongs to a locked category (any membership, `item_categories`), or – live – when
///   the channel itself is locked;
/// * category lists: locked categories are left out when `hideLocked`, else listed (the UI draws the lock and asks for
///   the PIN before opening one);
/// * item lists / lookups / search resolution leave out items of locked categories in both modes (titles and posters
///   never leak into "All", search, home rows or continue watching); individually locked channels are left out when
///   `hideLocked`, else listed (with a lock, playing needs the PIN).
public struct ContentLockFilter: Sendable, Hashable, Codable {
    /// sourceId → kind → locked category ids.
    public var categories: [String: [CategoryKind: Set<String>]]
    /// sourceId → locked channel ids.
    public var channels: [String: Set<String>]
    public var hideLocked: Bool

    public init(categories: [String: [CategoryKind: Set<String>]] = [:], channels: [String: Set<String>] = [:], hideLocked: Bool = true) {
        self.categories = categories
        self.channels = channels
        self.hideLocked = hideLocked
    }

    public func lockedCategories(_ sourceId: String, _ kind: CategoryKind) -> Set<String> {
        categories[sourceId]?[kind] ?? []
    }

    public func lockedChannels(_ sourceId: String) -> Set<String> {
        channels[sourceId] ?? []
    }

    /// Anything locked in this source.
    public func hasLocks(_ sourceId: String) -> Bool {
        !(categories[sourceId]?.values.allSatisfy(\.isEmpty) ?? true) || !lockedChannels(sourceId).isEmpty
    }

    public func isCategoryLocked(_ categoryId: String?, kind: CategoryKind, sourceId: String) -> Bool {
        categoryId.map { lockedCategories(sourceId, kind).contains($0) } ?? false
    }

    /// Category lists: drop locked categories in hide mode.
    public func visibleCategories<T>(_ items: [T], kind: CategoryKind, sourceId: String, id: (T) -> String) -> [T] {
        guard hideLocked else { return items }
        let locked = lockedCategories(sourceId, kind)
        guard !locked.isEmpty else { return items }
        return items.filter { !locked.contains(id($0)) }
    }
}

/// Thread-safe holder of the active filter (read by every catalog query, written on the main actor).
public final class ContentLockBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _filter: ContentLockFilter?

    public init() {}

    public var filter: ContentLockFilter? {
        get { lock.withLock { _filter } }
        set { lock.withLock { _filter = newValue } }
    }
}

extension CatalogRepository {
    /// `AND …` predicate that leaves out locked items of `kind` (empty without an active filter / locks).
    /// `alias`: table alias of the item row ("c." for joins); `idColumn`: the item id column (episodes: `series_id`).
    func lockClause(_ kind: CategoryKind, sourceId: String, alias: String = "", idColumn: String = "id",
                    filter: ContentLockFilter? = nil) -> (sql: String, args: [SQLiteValue]) {
        guard let filter = filter ?? contentLock.filter else { return ("", []) }
        var sql = ""
        var args: [SQLiteValue] = []
        let categories = filter.lockedCategories(sourceId, kind).sorted()
        if !categories.isEmpty {
            sql += " AND NOT EXISTS (SELECT 1 FROM item_categories lk WHERE lk.source_id = \(alias)source_id AND lk.kind = '\(kind.rawValue)'"
                + " AND lk.item_id = \(alias)\(idColumn) AND lk.category_id IN (\(Self.placeholders(categories.count))))"
            args += categories.map(SQLiteValue.text)
        }
        if kind == .live, filter.hideLocked {
            let channels = filter.lockedChannels(sourceId).sorted()
            if !channels.isEmpty {
                sql += " AND \(alias)\(idColumn) NOT IN (\(Self.placeholders(channels.count)))"
                args += channels.map(SQLiteValue.text)
            }
        }
        return (sql, args)
    }

    /// True when the item is locked by `filter` (default: the active one) – category membership, or the channel itself
    /// (in both modes). Episodes are checked through their series (`itemId` = series id, `kind` = `.series`).
    public func isLocked(sourceId: String, kind: CategoryKind, itemId: String, filter: ContentLockFilter? = nil) -> Bool {
        guard let filter = filter ?? contentLock.filter else { return false }
        if kind == .live, filter.lockedChannels(sourceId).contains(itemId) { return true }
        let categories = filter.lockedCategories(sourceId, kind).sorted()
        guard !categories.isEmpty else { return false }
        let found: Int = (try? database.db.scalar("""
            SELECT EXISTS (SELECT 1 FROM item_categories WHERE source_id = ? AND kind = ? AND item_id = ?
            AND category_id IN (\(Self.placeholders(categories.count))))
            """, [.text(sourceId), .text(kind.rawValue), .text(itemId)] + categories.map(SQLiteValue.text))) ?? 0
        return found != 0
    }

    /// An episode row whatever the lock (to find the series of a progress entry).
    func episodeIgnoringLock(sourceId: String, id: String) throws -> Episode? {
        try database.db.queryFirst("""
            SELECT source_id, id, series_id, season, number, title, container_ext, duration_sec, plot, poster_url, url
            FROM episodes WHERE source_id = ? AND id = ?
            """, [.text(sourceId), .text(id)], map: Self.episode)
    }

    /// A channel whatever the lock (a reminder's channel: playing it then asks for the PIN).
    public func channelIgnoringLock(sourceId: String, id: String) throws -> Channel? {
        try database.db.queryFirst("SELECT \(Self.channelColumns) FROM channels WHERE source_id = ? AND id = ?",
                                   [.text(sourceId), .text(id)], map: Self.channel)
    }

    /// Deepest catch-up archive (days) of the source's channels – the guide's past days.
    public func maxCatchupDays(sourceId: String) throws -> Int {
        try database.db.scalar("SELECT COALESCE(MAX(catchup_days), 0) FROM channels WHERE source_id = ? AND catchup_type != 'none'",
                               [.text(sourceId)])
    }
}
