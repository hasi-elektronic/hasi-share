import Foundation
import IPTVCore

/// Favorites and watch progress, stored as `SyncItem`s keyed by `contentKey` (CONTRACT §8).
/// They survive source refreshes because content keys are stable.
public final class LibraryRepository: Sendable {
    private let database: AppDatabase
    private var db: SQLiteDatabase { database.db }

    public init(database: AppDatabase) {
        self.database = database
    }

    private static let columns = "key, kind, title, content_kind, poster_url, position_ms, duration_ms, series_key, updated_at, deleted"

    private static func item(_ r: SQLiteRow) -> SyncItem {
        SyncItem(key: r.string(0), kind: SyncKind(rawValue: r.string(1)) ?? .favorite,
                 data: SyncItemData(title: r.string(2), contentKind: ContentKind(rawValue: r.string(3)) ?? .live,
                                    posterUrl: r.optString(4), positionMs: r.optInt64(5), durationMs: r.optInt64(6),
                                    seriesKey: r.optString(7)),
                 updatedAt: r.int64(8), deleted: r.bool(9))
    }

    /// Writes an item unconditionally (local change).
    public func put(_ item: SyncItem) throws {
        try db.run("""
            INSERT INTO library (key, kind, content_key, title, content_kind, poster_url, position_ms, duration_ms,
              series_key, updated_at, deleted) VALUES (?,?,?,?,?,?,?,?,?,?,?)
            ON CONFLICT(key) DO UPDATE SET kind = excluded.kind, content_key = excluded.content_key,
              title = excluded.title, content_kind = excluded.content_kind, poster_url = excluded.poster_url,
              position_ms = excluded.position_ms, duration_ms = excluded.duration_ms, series_key = excluded.series_key,
              updated_at = excluded.updated_at, deleted = excluded.deleted
            """, [.text(item.key), .text(item.kind.rawValue), .text(item.contentKey), .text(item.data.title),
                  .text(item.data.contentKind.rawValue), .from(item.data.posterUrl), .from(item.data.positionMs),
                  .from(item.data.durationMs), .from(item.data.seriesKey), .int(item.updatedAt), .from(item.deleted)])
    }

    /// Merges remote items with the LWW rule (ties keep stored); returns the applied ones.
    @discardableResult
    public func merge(_ incoming: [SyncItem]) throws -> [SyncItem] {
        try db.transaction {
            var applied: [SyncItem] = []
            for item in incoming {
                guard SyncMerge.shouldApply(incoming: item, stored: try self.item(key: item.key)) else { continue }
                try put(item)
                applied.append(item)
            }
            return applied
        }
    }

    public func item(key: String) throws -> SyncItem? {
        try db.queryFirst("SELECT \(Self.columns) FROM library WHERE key = ?", [.text(key)], map: Self.item)
    }

    public func isFavorite(contentKey: String) throws -> Bool {
        try item(key: SyncItem.favoriteKey(contentKey)).map { !$0.deleted } ?? false
    }

    /// Toggles a favorite; returns the new state.
    @discardableResult
    public func setFavorite(_ on: Bool, contentKey: String, title: String, kind: ContentKind, posterUrl: String?,
                            nowMs: Int64) throws -> SyncItem {
        let item = SyncItem.favorite(contentKey: contentKey, title: title, contentKind: kind, posterUrl: posterUrl,
                                     updatedAt: nowMs, deleted: !on)
        try put(item)
        return item
    }

    /// Non-deleted favorites, newest first.
    public func favorites(kind: ContentKind? = nil) throws -> [SyncItem] {
        var sql = "SELECT \(Self.columns) FROM library WHERE kind = 'favorite' AND deleted = 0"
        var args: [SQLiteValue] = []
        if let kind { sql += " AND content_kind = ?"; args.append(.text(kind.rawValue)) }
        sql += " ORDER BY updated_at DESC"
        return try db.query(sql, args, map: Self.item)
    }

    /// Progress items, newest first.
    public func progressItems(limit: Int = 500) throws -> [SyncItem] {
        try db.query("SELECT \(Self.columns) FROM library WHERE kind = 'progress' AND deleted = 0 ORDER BY updated_at DESC LIMIT ?",
                     [.int(Int64(limit))], map: Self.item)
    }

    public func progress(contentKey: String) throws -> SyncItem? {
        try item(key: SyncItem.progressKey(contentKey)).flatMap { $0.deleted ? nil : $0 }
    }

    @discardableResult
    public func saveProgress(contentKey: String, title: String, kind: ContentKind, positionMs: Int64, durationMs: Int64,
                             posterUrl: String?, seriesKey: String? = nil, nowMs: Int64) throws -> SyncItem {
        let item = SyncItem.progress(contentKey: contentKey, title: title, contentKind: kind, positionMs: positionMs,
                                     durationMs: durationMs, posterUrl: posterUrl, seriesKey: seriesKey, updatedAt: nowMs)
        try put(item)
        return item
    }

    /// Progress / "watched" from the player (main actor): written at once when the database is free; while a
    /// refresh commit holds the writer it goes to a serial background queue instead of blocking the main thread
    /// (zapping during the launch refresh). Later saves queue behind earlier ones, so the order is kept.
    /// `onDone` runs on the main actor after the write (synchronously when written at once).
    @MainActor
    public func saveProgressWithoutBlocking(contentKey: String, title: String, kind: ContentKind, positionMs: Int64, durationMs: Int64,
                                            posterUrl: String?, seriesKey: String? = nil, nowMs: Int64,
                                            onDone: @escaping @MainActor @Sendable () -> Void) {
        let write: @Sendable () -> Void = { [self] in
            _ = try? saveProgress(contentKey: contentKey, title: title, kind: kind, positionMs: positionMs, durationMs: durationMs,
                                  posterUrl: posterUrl, seriesKey: seriesKey, nowMs: nowMs)
        }
        if deferred.isEmpty, db.ifWriterFree(write) != nil {
            onDone()
            return
        }
        deferred.increment()
        Self.writeQueue.async { [deferred] in
            write()
            deferred.decrement()
            Task { @MainActor in onDone() }
        }
    }

    private static let writeQueue = DispatchQueue(label: "library.deferred-writes", qos: .userInitiated)
    private let deferred = DeferredCount()

    /// Items changed after `ms` (for sync push), oldest first.
    public func changed(after ms: Int64, limit: Int = 500) throws -> [SyncItem] {
        try db.query("SELECT \(Self.columns) FROM library WHERE updated_at > ? ORDER BY updated_at ASC LIMIT ?",
                     [.int(ms), .int(Int64(limit))], map: Self.item)
    }

    public func all() throws -> [SyncItem] {
        try db.query("SELECT \(Self.columns) FROM library", map: Self.item)
    }

    public func deleteAll() throws {
        try db.run("DELETE FROM library")
    }
}

/// Number of library writes waiting on the background queue.
final class DeferredCount: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var isEmpty: Bool { lock.lock(); defer { lock.unlock() }; return count == 0 }
    func increment() { lock.lock(); count += 1; lock.unlock() }
    func decrement() { lock.lock(); count -= 1; lock.unlock() }
}
