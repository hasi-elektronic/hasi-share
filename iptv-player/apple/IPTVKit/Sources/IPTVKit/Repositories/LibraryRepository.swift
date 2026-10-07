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

    /// The item, a not yet written local change first.
    public func item(key: String) throws -> SyncItem? {
        if let pending = overlay.get(key) { return pending }
        return try storedItem(key: key)
    }

    func storedItem(key: String) throws -> SyncItem? {
        try db.queryFirst("SELECT \(Self.columns) FROM library WHERE key = ?", [.text(key)], map: Self.item)
    }

    /// `rows` with the pending local changes of `kind` applied (replace / add / remove deleted), newest first.
    private func overlaid(_ rows: [SyncItem], kind: SyncKind, contentKind: ContentKind? = nil) -> [SyncItem] {
        let pending = overlay.all().filter { $0.kind == kind && (contentKind == nil || $0.data.contentKind == contentKind) }
        guard !pending.isEmpty else { return rows }
        var byKey = Dictionary(rows.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        for item in pending { byKey[item.key] = item.deleted ? nil : item }
        return byKey.values.sorted { $0.updatedAt > $1.updatedAt }
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
        return overlaid(try db.query(sql, args, map: Self.item), kind: .favorite, contentKind: kind)
    }

    /// Progress items, newest first.
    public func progressItems(limit: Int = 500) throws -> [SyncItem] {
        Array(overlaid(try db.query("SELECT \(Self.columns) FROM library WHERE kind = 'progress' AND deleted = 0 ORDER BY updated_at DESC LIMIT ?",
                                    [.int(Int64(limit))], map: Self.item), kind: .progress).prefix(limit))
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

    /// Progress / "watched" from the player (main actor), never blocking: see `putWithoutBlocking`. `onDone` runs
    /// on the main actor after the write (synchronously when written at once).
    @MainActor
    public func saveProgressWithoutBlocking(contentKey: String, title: String, kind: ContentKind, positionMs: Int64, durationMs: Int64,
                                            posterUrl: String?, seriesKey: String? = nil, nowMs: Int64,
                                            onDone: @escaping @MainActor @Sendable () -> Void) {
        let item = SyncItem.progress(contentKey: contentKey, title: title, contentKind: kind, positionMs: positionMs,
                                     durationMs: durationMs, posterUrl: posterUrl, seriesKey: seriesKey, updatedAt: nowMs)
        if putWithoutBlocking(item, onDone: { Task { @MainActor in onDone() } }) { onDone() }
    }

    /// Favorite toggle from the UI, never blocking (`putWithoutBlocking`).
    /// Throws only when written at once and the write failed (the caller restores its optimistic state).
    @discardableResult
    public func setFavoriteWithoutBlocking(_ on: Bool, contentKey: String, title: String, kind: ContentKind, posterUrl: String?,
                                           nowMs: Int64) throws -> SyncItem {
        let item = SyncItem.favorite(contentKey: contentKey, title: title, contentKind: kind, posterUrl: posterUrl,
                                     updatedAt: nowMs, deleted: !on)
        try putWithoutBlockingThrowing(item)
        return item
    }

    /// Writes a local change without ever blocking the caller: at once when the writer is free (returns true);
    /// while a commit holds it the item waits in `deferredWrites` (in order) and meanwhile **overlays** every read
    /// of this repository (read-your-writes). When it is finally written its `updatedAt` is moved on by the
    /// time it waited (a sync push after the save must still see it as changed), and it is skipped if the stored
    /// row became newer meanwhile (LWW: a sync merge won). `onDone` runs after a queued write.
    @discardableResult
    public func putWithoutBlocking(_ item: SyncItem, onDone: (@Sendable () -> Void)? = nil) -> Bool {
        (try? putWithoutBlockingThrowing(item, onDone: onDone)) ?? true
    }

    /// `putWithoutBlocking`, rethrowing the error of a write made at once.
    @discardableResult
    func putWithoutBlockingThrowing(_ item: SyncItem, onDone: (@Sendable () -> Void)? = nil) throws -> Bool {
        if database.deferredWrites.isIdle, try db.ifWriterFree({ try put(item) }) != nil { return true }
        let enqueued = DispatchTime.now()
        let overlay = overlay
        let token = overlay.set(item)
        database.deferredWrites.enqueue { [self] in
            // Decided once the writer is ours (inside the transaction): the wait is over, the stored row is final.
            try? db.transaction {
                var adjusted = item
                adjusted.updatedAt = item.updatedAt + Int64((DispatchTime.now().uptimeNanoseconds - enqueued.uptimeNanoseconds) / 1_000_000)
                if let stored = try storedItem(key: item.key), stored.updatedAt > adjusted.updatedAt {
                    return   // a newer version arrived meanwhile (sync merge): keep it
                }
                try put(adjusted)
            }
            overlay.remove(item.key, token: token)
            onDone?()
        }
        return false
    }

    private let overlay = LibraryOverlay()

    /// True while local changes still wait to be written.
    public var hasPendingWrites: Bool { !overlay.isEmpty }

    /// Items changed after `ms` (for sync push), oldest first.
    public func changed(after ms: Int64, limit: Int = 500) throws -> [SyncItem] {
        // Sync runs off the main actor: let queued local changes land first so they are pushed.
        if !overlay.isEmpty { database.deferredWrites.drain(timeout: 2) }
        return try db.query("SELECT \(Self.columns) FROM library WHERE updated_at > ? ORDER BY updated_at ASC LIMIT ?",
                     [.int(ms), .int(Int64(limit))], map: Self.item)
    }

    public func all() throws -> [SyncItem] {
        try db.query("SELECT \(Self.columns) FROM library", map: Self.item)
    }

    public func deleteAll() throws {
        try db.run("DELETE FROM library")
    }
}

/// Local changes queued in `DeferredWrites`, by key (read-your-writes overlay).
final class LibraryOverlay: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: (item: SyncItem, token: UInt64)] = [:]
    private var next: UInt64 = 0

    var isEmpty: Bool { lock.lock(); defer { lock.unlock() }; return items.isEmpty }

    func set(_ item: SyncItem) -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        next += 1
        items[item.key] = (item, next)
        return next
    }

    /// Removes the entry once its write is done – unless a newer change of the key replaced it.
    func remove(_ key: String, token: UInt64) {
        lock.lock(); defer { lock.unlock() }
        if items[key]?.token == token { items[key] = nil }
    }

    func get(_ key: String) -> SyncItem? { lock.lock(); defer { lock.unlock() }; return items[key]?.item }
    func all() -> [SyncItem] { lock.lock(); defer { lock.unlock() }; return items.values.map(\.item) }
}
