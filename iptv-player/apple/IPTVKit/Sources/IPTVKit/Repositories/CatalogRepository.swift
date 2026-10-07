import Foundation
import IPTVCore

/// Sort order of movie/series grids (docs/SCREENS.md §3.4).
public enum CatalogSort: String, Sendable, Hashable, CaseIterable {
    case added, az, rating
}

/// One full-text search hit.
public struct SearchHit: Sendable, Hashable, Identifiable {
    public var sourceId: String
    public var kind: ContentKind
    public var itemId: String
    public var title: String
    public var id: String { "\(sourceId)|\(kind.rawValue)|\(itemId)" }
}

/// Row counts of one source.
public struct CatalogCounts: Sendable, Hashable {
    public var channels: Int
    public var movies: Int
    public var series: Int
    public var episodes: Int
}

/// Read and write access to catalog content (categories, channels, movies, series, episodes)
/// with paged queries and FTS5 search.
public final class CatalogRepository: Sendable {
    private let database: AppDatabase
    private var db: SQLiteDatabase { database.db }

    public init(database: AppDatabase) {
        self.database = database
    }

    // MARK: Refresh (atomic)

    /// Starts an atomic refresh of `sourceId`: rows are written under a staging id and become
    /// visible only on `commit()`.
    public func beginRefresh(sourceId: String) throws -> CatalogRefreshSession {
        try CatalogRefreshSession(db: db, sourceId: sourceId)
    }

    /// Removes all content of a source.
    public func deleteContent(sourceId: String) throws {
        try db.transaction {
            for table in ["categories", "item_categories", "channels", "movies", "series", "episodes", "epg"] {
                try db.run("DELETE FROM \(table) WHERE source_id = ? OR source_id = ?",
                           [.text(sourceId), .text(sourceId + AppDatabase.stagingSuffix)])
            }
            if db.hasFTS5 {
                try db.run("DELETE FROM search_index WHERE source_id = ? OR source_id = ?",
                           [.text(sourceId), .text(sourceId + AppDatabase.stagingSuffix)])
            }
        }
    }

    // MARK: Reads

    public func counts(sourceId: String) throws -> CatalogCounts {
        CatalogCounts(channels: try db.scalar("SELECT COUNT(*) FROM channels WHERE source_id = ?", [.text(sourceId)]),
                      movies: try db.scalar("SELECT COUNT(*) FROM movies WHERE source_id = ?", [.text(sourceId)]),
                      series: try db.scalar("SELECT COUNT(*) FROM series WHERE source_id = ?", [.text(sourceId)]),
                      episodes: try db.scalar("SELECT COUNT(*) FROM episodes WHERE source_id = ?", [.text(sourceId)]))
    }

    public func categories(sourceId: String, kind: CategoryKind) throws -> [IPTVCore.Category] {
        try db.query("SELECT id, name, sort FROM categories WHERE source_id = ? AND kind = ? ORDER BY sort",
                     [.text(sourceId), .text(kind.rawValue)]) {
            IPTVCore.Category(sourceId: sourceId, id: $0.string(0), kind: kind, name: $0.string(1), sort: $0.int(2))
        }
    }

    /// Categories that contain at least one item (via `item_categories`, so multi-category Xtream items
    /// count everywhere), in provider order – the full list the Movies/Series category chips offer.
    public func categoriesWithContent(sourceId: String, kind: CategoryKind) throws -> [IPTVCore.Category] {
        try db.query("""
            SELECT id, name, sort FROM categories c WHERE c.source_id = ? AND c.kind = ? AND EXISTS (
              SELECT 1 FROM item_categories ic WHERE ic.source_id = c.source_id AND ic.kind = c.kind AND ic.category_id = c.id)
            ORDER BY sort
            """, [.text(sourceId), .text(kind.rawValue)]) {
            IPTVCore.Category(sourceId: sourceId, id: $0.string(0), kind: kind, name: $0.string(1), sort: $0.int(2))
        }
    }

    /// `id IN (…)` filter: items of one category (all memberships, not just the primary `category_id`).
    static func memberFilter(_ kind: CategoryKind) -> String {
        "id IN (SELECT item_id FROM item_categories WHERE source_id = ? AND kind = '\(kind.rawValue)' AND category_id = ?)"
    }

    static let channelColumns = "source_id, id, name, number, logo_url, category_id, epg_id, catchup_type, catchup_days, catchup_source, url, user_agent, referrer, drm, sort"
    static let qualifiedChannelColumns = channelColumns.components(separatedBy: ", ").map { "c.\($0)" }.joined(separator: ", ")

    static func channel(_ r: SQLiteRow) -> Channel {
        Channel(sourceId: r.string(0), id: r.string(1), name: r.string(2), number: r.optInt(3), logoUrl: r.optString(4),
                categoryId: r.optString(5), epgId: r.optString(6),
                catchup: CatchupInfo(type: CatchupType(rawValue: r.string(7)) ?? .none, days: r.int(8), source: r.optString(9)),
                url: r.optString(10), userAgent: r.optString(11), referrer: r.optString(12), drm: r.bool(13), sort: r.int(14))
    }

    /// A page of channels; `categoryId == nil` → all.
    public func channels(sourceId: String, categoryId: String? = nil, offset: Int = 0, limit: Int = 100) throws -> [Channel] {
        if let categoryId {
            // Walks the membership index in list order (no sort step) and joins the channel rows.
            return try db.query("""
                SELECT \(Self.qualifiedChannelColumns) FROM item_categories ic
                JOIN channels c ON c.source_id = ic.source_id AND c.id = ic.item_id
                WHERE ic.source_id = ? AND ic.kind = 'live' AND ic.category_id = ? ORDER BY ic.sort LIMIT ? OFFSET ?
                """, [.text(sourceId), .text(categoryId), .int(Int64(limit)), .int(Int64(offset))], map: Self.channel)
        }
        return try db.query("SELECT \(Self.channelColumns) FROM channels WHERE source_id = ? ORDER BY sort LIMIT ? OFFSET ?",
                            [.text(sourceId), .int(Int64(limit)), .int(Int64(offset))], map: Self.channel)
    }

    public func channelCount(sourceId: String, categoryId: String? = nil) throws -> Int {
        if let categoryId {
            return try db.scalar("SELECT COUNT(*) FROM item_categories WHERE source_id = ? AND kind = 'live' AND category_id = ?",
                                 [.text(sourceId), .text(categoryId)])
        }
        return try db.scalar("SELECT COUNT(*) FROM channels WHERE source_id = ?", [.text(sourceId)])
    }

    /// Live channels per category (all memberships) in one query – the category chips' counts.
    public func channelCountsByCategory(sourceId: String) throws -> [String: Int] {
        let pairs = try db.query("SELECT category_id, COUNT(*) FROM item_categories WHERE source_id = ? AND kind = 'live' GROUP BY category_id",
                                 [.text(sourceId)]) { ($0.string(0), $0.int(1)) }
        return Dictionary(pairs, uniquingKeysWith: +)
    }

    public func channel(sourceId: String, id: String) throws -> Channel? {
        try db.queryFirst("SELECT \(Self.channelColumns) FROM channels WHERE source_id = ? AND id = ?",
                          [.text(sourceId), .text(id)], map: Self.channel)
    }

    /// Number zapping (SCREENS §3.7): the channel with this number anywhere in the source (first in list
    /// order; indexed). Only a source without any channel numbers falls back to the n-th channel of its
    /// list (1-based); in a numbered source a missing number is nil.
    public func channelForNumberZap(sourceId: String, number: Int) throws -> Channel? {
        guard number > 0 else { return nil }
        if let match = try db.queryFirst("SELECT \(Self.channelColumns) FROM channels WHERE source_id = ? AND number = ? ORDER BY sort LIMIT 1",
                                         [.text(sourceId), .int(Int64(number))], map: Self.channel) {
            return match
        }
        let numbered: Int = try db.scalar("SELECT EXISTS (SELECT 1 FROM channels WHERE source_id = ? AND number IS NOT NULL)", [.text(sourceId)])
        guard numbered == 0 else { return nil }
        return try channels(sourceId: sourceId, offset: number - 1, limit: 1).first
    }

    /// Zap list for a number-zap target (SCREENS §3.7): up to `before` channels before and `after` after
    /// it in its category's list order, so ▲▼ reach real neighbours wherever the target sits. Empty when
    /// the channel is not a member of the category. Walks the membership index from the target's row.
    public func channelZapWindow(sourceId: String, categoryId: String, around channelId: String,
                                 before: Int = 100, after: Int = 100) throws -> [Channel] {
        let args: [SQLiteValue] = [.text(sourceId), .text(categoryId)]
        guard let sort = try db.queryFirst(
            "SELECT sort FROM item_categories WHERE source_id = ? AND kind = 'live' AND category_id = ? AND item_id = ?",
            args + [.text(channelId)], map: { $0.int(0) }) else { return [] }
        let select = """
            SELECT \(Self.qualifiedChannelColumns) FROM item_categories ic
            JOIN channels c ON c.source_id = ic.source_id AND c.id = ic.item_id
            WHERE ic.source_id = ? AND ic.kind = 'live' AND ic.category_id = ?
            """
        let head = try db.query(select + " AND ic.sort < ? ORDER BY ic.sort DESC LIMIT ?",
                                args + [.int(Int64(sort)), .int(Int64(before))], map: Self.channel)
        let tail = try db.query(select + " AND ic.sort >= ? ORDER BY ic.sort LIMIT ?",
                                args + [.int(Int64(sort)), .int(Int64(after + 1))], map: Self.channel)
        return head.reversed() + tail
    }

    /// Channels by id, in the order given (favorites / recent rows).
    public func channels(sourceId: String, ids: [String]) throws -> [Channel] {
        guard !ids.isEmpty else { return [] }
        let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
        let rows = try db.query("SELECT \(Self.channelColumns) FROM channels WHERE source_id = ? AND id IN (\(placeholders))",
                                [.text(sourceId)] + ids.map(SQLiteValue.text), map: Self.channel)
        let byId = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return ids.compactMap { byId[$0] }
    }

    static let movieColumns = "source_id, id, name, poster_url, category_id, rating, year, plot, container_ext, url, added_at, sort"

    static func movie(_ r: SQLiteRow) -> Movie {
        Movie(sourceId: r.string(0), id: r.string(1), name: r.string(2), posterUrl: r.optString(3), categoryId: r.optString(4),
              rating: r.optDouble(5), year: r.optInt(6), plot: r.optString(7), containerExt: r.optString(8),
              url: r.optString(9), addedAt: r.optDate(10), sort: r.int(11))
    }

    private static func order(_ sort: CatalogSort) -> String {
        switch sort {
        case .added: return "COALESCE(added_at, 0) DESC, sort DESC"
        case .az: return "name COLLATE NOCASE ASC"
        case .rating: return "COALESCE(rating, -1) DESC, name COLLATE NOCASE"
        }
    }

    public func movies(sourceId: String, categoryId: String? = nil, sort: CatalogSort = .added,
                       offset: Int = 0, limit: Int = 60) throws -> [Movie] {
        var sql = "SELECT \(Self.movieColumns) FROM movies WHERE source_id = ?"
        var args: [SQLiteValue] = [.text(sourceId)]
        if let categoryId { sql += " AND " + Self.memberFilter(.movie); args += [.text(sourceId), .text(categoryId)] }
        sql += " ORDER BY \(Self.order(sort)) LIMIT ? OFFSET ?"
        args += [.int(Int64(limit)), .int(Int64(offset))]
        return try db.query(sql, args, map: Self.movie)
    }

    public func movie(sourceId: String, id: String) throws -> Movie? {
        try db.queryFirst("SELECT \(Self.movieColumns) FROM movies WHERE source_id = ? AND id = ?", [.text(sourceId), .text(id)], map: Self.movie)
    }

    static let seriesColumns = "source_id, id, name, poster_url, category_id, plot, rating, year, sort"

    static func series(_ r: SQLiteRow) -> Series {
        Series(sourceId: r.string(0), id: r.string(1), name: r.string(2), posterUrl: r.optString(3), categoryId: r.optString(4),
               plot: r.optString(5), rating: r.optDouble(6), year: r.optInt(7), sort: r.int(8))
    }

    public func series(sourceId: String, categoryId: String? = nil, sort: CatalogSort = .added,
                       offset: Int = 0, limit: Int = 60) throws -> [Series] {
        var sql = "SELECT \(Self.seriesColumns) FROM series WHERE source_id = ?"
        var args: [SQLiteValue] = [.text(sourceId)]
        if let categoryId { sql += " AND " + Self.memberFilter(.series); args += [.text(sourceId), .text(categoryId)] }
        let order = sort == .added ? "sort DESC" : Self.order(sort)
        sql += " ORDER BY \(order) LIMIT ? OFFSET ?"
        args += [.int(Int64(limit)), .int(Int64(offset))]
        return try db.query(sql, args, map: Self.series)
    }

    public func seriesItem(sourceId: String, id: String) throws -> Series? {
        try db.queryFirst("SELECT \(Self.seriesColumns) FROM series WHERE source_id = ? AND id = ?", [.text(sourceId), .text(id)], map: Self.series)
    }

    static func episode(_ r: SQLiteRow) -> Episode {
        Episode(sourceId: r.string(0), id: r.string(1), seriesId: r.string(2), season: r.int(3), number: r.int(4),
                title: r.string(5), containerExt: r.optString(6), durationSec: r.optInt(7), plot: r.optString(8),
                posterUrl: r.optString(9), url: r.optString(10))
    }

    public func episodes(sourceId: String, seriesId: String) throws -> [Episode] {
        try db.query("""
            SELECT source_id, id, series_id, season, number, title, container_ext, duration_sec, plot, poster_url, url
            FROM episodes WHERE source_id = ? AND series_id = ? ORDER BY season, number
            """, [.text(sourceId), .text(seriesId)], map: Self.episode)
    }

    /// Stores episodes fetched lazily (Xtream `get_series_info`), replacing those of the series.
    public func replaceEpisodes(sourceId: String, seriesId: String, episodes: [Episode]) throws {
        try db.transaction {
            try db.run("DELETE FROM episodes WHERE source_id = ? AND series_id = ?", [.text(sourceId), .text(seriesId)])
            for e in episodes { try CatalogRefreshSession.insert(episode: e, sourceId: sourceId, db: db) }
        }
    }

    /// Full-text search over channel, movie and series titles (prefix match per token, case and
    /// diacritics folded; provider prefixes/punctuation such as "TR:", "|DE|", "[HD]" are not tokens).
    ///
    /// Returns up to `perKindLimit` hits **per kind**, grouped live → movie → series. One global limit let the
    /// (usually far more numerous) movies fill every slot, so channels and series never showed up.
    public func search(_ text: String, sourceId: String? = nil, perKindLimit: Int = 30) throws -> [SearchHit] {
        let tokens = text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        guard !tokens.isEmpty, perKindLimit > 0 else { return [] }
        if db.hasFTS5 { return try searchFTS(tokens: tokens, sourceId: sourceId, perKindLimit: perKindLimit) }
        return try searchLike(tokens: tokens, sourceId: sourceId, perKindLimit: perKindLimit)
    }

    /// One FTS scan, ranked per kind with a window function (measured ~40 % faster than three
    /// `AND kind = ?` queries, which each re-scan every match of the token at 50k+ rows).
    func searchFTS(tokens: [String], sourceId: String?, perKindLimit: Int) throws -> [SearchHit] {
        let match = tokens.map { "\"\($0)\"*" }.joined(separator: " ")
        var inner = "SELECT source_id, kind, item_id, title, ROW_NUMBER() OVER (PARTITION BY kind ORDER BY rank) AS rn "
            + "FROM search_index WHERE search_index MATCH ?"
        var args: [SQLiteValue] = [.text(match)]
        if let sourceId { inner += " AND source_id = ?"; args.append(.text(sourceId)) }
        else { inner += " AND source_id NOT LIKE '%\(AppDatabase.stagingSuffix)'" }
        let sql = "SELECT source_id, kind, item_id, title FROM (\(inner)) WHERE rn <= ? "
            + "ORDER BY CASE kind WHEN 'live' THEN 0 WHEN 'movie' THEN 1 ELSE 2 END, rn"
        args.append(.int(Int64(perKindLimit)))
        return try db.query(sql, args) {
            SearchHit(sourceId: $0.string(0), kind: ContentKind(rawValue: $0.string(1)) ?? .live,
                      itemId: $0.string(2), title: $0.string(3))
        }
    }

    /// Fallback without FTS5: LIKE over the three tables, same per-kind limit and order.
    func searchLike(tokens: [String], sourceId: String?, perKindLimit: Int) throws -> [SearchHit] {
        var hits: [SearchHit] = []
        let pattern = "%" + tokens.joined(separator: "%") + "%"
        for (table, kind) in [("channels", ContentKind.live), ("movies", .movie), ("series", .series)] {
            var sql = "SELECT source_id, id, name FROM \(table) WHERE name LIKE ? AND source_id NOT LIKE '%\(AppDatabase.stagingSuffix)'"
            var args: [SQLiteValue] = [.text(pattern)]
            if let sourceId { sql += " AND source_id = ?"; args.append(.text(sourceId)) }
            sql += " LIMIT ?"
            args.append(.int(Int64(perKindLimit)))
            hits += try db.query(sql, args) { SearchHit(sourceId: $0.string(0), kind: kind, itemId: $0.string(1), title: $0.string(2)) }
        }
        return hits
    }
}

/// One running refresh of a source's catalog. Rows go to the staging id in transactions of
/// one batch each; `commit()` swaps staging → live in a single transaction.
public final class CatalogRefreshSession: @unchecked Sendable {
    let db: SQLiteDatabase
    public let sourceId: String
    let stagingId: String
    private var finished = false

    init(db: SQLiteDatabase, sourceId: String) throws {
        self.db = db
        self.sourceId = sourceId
        self.stagingId = sourceId + AppDatabase.stagingSuffix
        try clearStaging()
    }

    private func clearStaging() throws {
        try db.transaction {
            for table in ["categories", "item_categories", "channels", "movies", "series", "episodes"] {
                try db.run("DELETE FROM \(table) WHERE source_id = ?", [.text(stagingId)])
            }
            if db.hasFTS5 { try db.run("DELETE FROM search_index WHERE source_id = ?", [.text(stagingId)]) }
        }
    }

    /// Writes one M3U batch.
    public func write(_ batch: M3UCatalogBatch) throws {
        try write(categories: batch.categories, channels: batch.channels, movies: batch.movies,
                  series: batch.series, episodes: batch.episodes)
    }

    /// Writes rows (one transaction).
    public func write(categories: [IPTVCore.Category] = [], channels: [Channel] = [], movies: [Movie] = [],
                      series: [Series] = [], episodes: [Episode] = []) throws {
        let sid = stagingId
        try db.transaction {
            for c in categories {
                try db.run("INSERT OR REPLACE INTO categories (source_id, id, kind, name, sort) VALUES (?,?,?,?,?)",
                           [.text(sid), .text(c.id), .text(c.kind.rawValue), .text(c.name), .from(c.sort)])
            }
            for c in channels {
                try db.run("INSERT OR REPLACE INTO channels (\(CatalogRepository.channelColumns)) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
                           [.text(sid), .text(c.id), .text(c.name), .from(c.number), .from(c.logoUrl), .from(c.categoryId),
                            .from(c.epgId), .text(c.catchup.type.rawValue), .from(c.catchup.days), .from(c.catchup.source),
                            .from(c.url), .from(c.userAgent), .from(c.referrer), .from(c.drm), .from(c.sort)])
                try index(title: c.name, kind: .live, itemId: c.id)
                try member(kind: .live, itemId: c.id, categoryIds: c.categoryIds, sort: c.sort)
            }
            for m in movies {
                try db.run("INSERT OR REPLACE INTO movies (\(CatalogRepository.movieColumns)) VALUES (?,?,?,?,?,?,?,?,?,?,?,?)",
                           [.text(sid), .text(m.id), .text(m.name), .from(m.posterUrl), .from(m.categoryId), .from(m.rating),
                            .from(m.year), .from(m.plot), .from(m.containerExt), .from(m.url), .from(m.addedAt), .from(m.sort)])
                try index(title: m.name, kind: .movie, itemId: m.id)
                try member(kind: .movie, itemId: m.id, categoryIds: m.categoryIds, sort: m.sort)
            }
            for s in series {
                try db.run("INSERT OR REPLACE INTO series (\(CatalogRepository.seriesColumns)) VALUES (?,?,?,?,?,?,?,?,?)",
                           [.text(sid), .text(s.id), .text(s.name), .from(s.posterUrl), .from(s.categoryId), .from(s.plot),
                            .from(s.rating), .from(s.year), .from(s.sort)])
                try index(title: s.name, kind: .series, itemId: s.id)
                try member(kind: .series, itemId: s.id, categoryIds: s.categoryIds, sort: s.sort)
            }
            for e in episodes { try Self.insert(episode: e, sourceId: sid, db: db) }
        }
    }

    static func insert(episode e: Episode, sourceId: String, db: SQLiteDatabase) throws {
        try db.run("""
            INSERT OR REPLACE INTO episodes (source_id, id, series_id, season, number, title, container_ext, duration_sec,
            plot, poster_url, url) VALUES (?,?,?,?,?,?,?,?,?,?,?)
            """, [.text(sourceId), .text(e.id), .text(e.seriesId), .from(e.season), .from(e.number), .text(e.title),
                  .from(e.containerExt), .from(e.durationSec), .from(e.plot), .from(e.posterUrl), .from(e.url)])
    }

    /// One `item_categories` row per category of the item (all Xtream `category_ids`, M3U: its group).
    private func member(kind: CategoryKind, itemId: String, categoryIds: [String], sort: Int) throws {
        for categoryId in categoryIds {
            try db.run("INSERT OR REPLACE INTO item_categories (source_id, kind, category_id, item_id, sort) VALUES (?,?,?,?,?)",
                       [.text(stagingId), .text(kind.rawValue), .text(categoryId), .text(itemId), .from(sort)])
        }
    }

    private func index(title: String, kind: ContentKind, itemId: String) throws {
        guard db.hasFTS5 else { return }
        try db.run("INSERT INTO search_index (title, source_id, kind, item_id) VALUES (?,?,?,?)",
                   [.text(title), .text(stagingId), .text(kind.rawValue), .text(itemId)])
    }

    /// Makes the staged rows the live content of the source (atomic swap).
    public func commit() throws {
        guard !finished else { return }
        finished = true
        try db.transaction {
            for table in ["categories", "item_categories", "channels", "movies", "series", "episodes"] {
                try db.run("DELETE FROM \(table) WHERE source_id = ?", [.text(sourceId)])
                try db.run("UPDATE \(table) SET source_id = ? WHERE source_id = ?", [.text(sourceId), .text(stagingId)])
            }
            if db.hasFTS5 {
                try db.run("DELETE FROM search_index WHERE source_id = ?", [.text(sourceId)])
                try db.run("UPDATE search_index SET source_id = ? WHERE source_id = ?", [.text(sourceId), .text(stagingId)])
            }
        }
    }

    /// Discards the staged rows; live content stays untouched.
    public func abort() {
        guard !finished else { return }
        finished = true
        try? clearStaging()
    }
}
