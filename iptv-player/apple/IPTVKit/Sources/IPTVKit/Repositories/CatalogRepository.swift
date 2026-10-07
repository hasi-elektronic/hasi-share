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
    /// Person hits only (title does not match, cast/director does): the matched person ("Hasan Can Kaya").
    public var matchedPerson: String?
    public var id: String { "\(sourceId)|\(kind.rawValue)|\(itemId)" }
    public var isPersonMatch: Bool { matchedPerson != nil }

    public init(sourceId: String, kind: ContentKind, itemId: String, title: String, matchedPerson: String? = nil) {
        self.sourceId = sourceId
        self.kind = kind
        self.itemId = itemId
        self.title = title
        self.matchedPerson = matchedPerson
    }
}

/// Cast + director → the `people` text of the search index ("Hasan Can Kaya, Ali Yılmaz").
public enum CatalogPeople {
    /// Separates the dotless-i variant appended to indexed text (an invisible separator, not a token).
    static let variantMark = "\u{2063}"

    /// Indexed form of a title / people text. FTS5 `remove_diacritics` folds "ş", "ç", "ü" … but not the
    /// Turkish dotless "ı" / dotted "İ" (separate letters), so "yilmaz" would never find "Yılmaz": such texts
    /// get an "ı → i" variant appended after `variantMark`.
    public static func indexed(_ text: String) -> String {
        guard text.contains("ı") || text.contains("İ") else { return text }
        return text + " \(variantMark) " + text.replacingOccurrences(of: "ı", with: "i").replacingOccurrences(of: "İ", with: "I")
    }

    /// Display part of an indexed text (variant removed).
    static func display(_ indexed: String) -> String {
        guard let range = indexed.range(of: variantMark) else { return indexed }
        return indexed[..<range.lowerBound].trimmingCharacters(in: .whitespaces)
    }

    public static func text(cast: String?, director: String?) -> String? {
        let parts = [cast, director].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    /// The person of a `people` text that matches every token (prefix match per word, case and diacritics
    /// folded): "hasan" in "Hasan Can Kaya, Ali Yılmaz" → "Hasan Can Kaya". Otherwise the (at most two)
    /// people matching some token, joined; then the whole text.
    public static func matchedPerson(_ people: String, tokens: [String]) -> String {
        let names = people.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let folded = tokens.map(CategoryCountry.fold)
        func words(_ name: String) -> [String] {
            CategoryCountry.fold(name).components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        }
        if let all = names.first(where: { name in let w = words(name); return folded.allSatisfy { t in w.contains { $0.hasPrefix(t) } } }) {
            return all
        }
        // No single person has every token ("hasan kaya" in "Hasan Yılmaz, Ali Kaya"): the names that matched,
        // at most two.
        let some = names.filter { name in let w = words(name); return folded.contains { t in w.contains { $0.hasPrefix(t) } } }
        if !some.isEmpty { return some.prefix(2).joined(separator: ", ") }
        return people
    }
}

/// Row counts of one source.
public struct CatalogCounts: Sendable, Hashable {
    public var channels: Int
    public var movies: Int
    public var series: Int
    public var episodes: Int
}

/// A category of the Movies/Series navigation: the category, how many items it lists and the country
/// detected from its name (nil = no single country; such categories appear only under "All").
public struct CategoryInfo: Sendable, Hashable, Identifiable {
    public var category: IPTVCore.Category
    public var itemCount: Int
    public var countryCode: String?
    public var id: String { category.id }

    public init(category: IPTVCore.Category, itemCount: Int, countryCode: String?) {
        self.category = category
        self.itemCount = itemCount
        self.countryCode = countryCode
    }
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
            for table in ["categories", "item_categories", "item_people", "channels", "movies", "series", "episodes", "epg"] {
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

    /// Categories with ≥ 1 item, provider order, with item counts (all memberships) and the detected
    /// country – the Movies/Series category navigation (docs/SCREENS.md §3.2). One grouped query over the
    /// `item_categories` index; the country comes from the name (cached per name in `CategoryCountry`).
    public func categoryInfos(sourceId: String, kind: CategoryKind) throws -> [CategoryInfo] {
        try db.query("""
            SELECT c.id, c.name, c.sort, n.cnt FROM categories c
            JOIN (SELECT category_id, COUNT(*) AS cnt FROM item_categories WHERE source_id = ? AND kind = ? GROUP BY category_id) n
              ON n.category_id = c.id
            WHERE c.source_id = ? AND c.kind = ?
            ORDER BY c.sort
            """, [.text(sourceId), .text(kind.rawValue), .text(sourceId), .text(kind.rawValue)]) {
            let name = $0.string(1)
            return CategoryInfo(category: IPTVCore.Category(sourceId: sourceId, id: $0.string(0), kind: kind, name: name, sort: $0.int(2)),
                                itemCount: $0.int(3), countryCode: CategoryCountry.code(for: name))
        }
    }

    /// `id IN (…)` filter: items of a set of categories (country filter: "new" / Top 10 of one country).
    static func memberSetFilter(_ kind: CategoryKind, count: Int) -> String {
        let placeholders = Array(repeating: "?", count: count).joined(separator: ",")
        return "id IN (SELECT item_id FROM item_categories WHERE source_id = ? AND kind = '\(kind.rawValue)' AND category_id IN (\(placeholders)))"
    }

    /// Movies that belong to any of `categoryIds` (each once), sorted, first `limit`.
    public func movies(sourceId: String, categoryIds: [String], sort: CatalogSort, offset: Int = 0, limit: Int) throws -> [Movie] {
        guard !categoryIds.isEmpty else { return [] }
        let sql = "SELECT \(Self.movieColumns) FROM movies WHERE source_id = ? AND \(Self.memberSetFilter(.movie, count: categoryIds.count))"
            + " ORDER BY \(Self.order(sort)) LIMIT ? OFFSET ?"
        let args: [SQLiteValue] = [.text(sourceId), .text(sourceId)] + categoryIds.map(SQLiteValue.text) + [.int(Int64(limit)), .int(Int64(offset))]
        return try db.query(sql, args, map: Self.movie)
    }

    /// Series that belong to any of `categoryIds` (each once), sorted, first `limit`.
    public func series(sourceId: String, categoryIds: [String], sort: CatalogSort, offset: Int = 0, limit: Int) throws -> [Series] {
        guard !categoryIds.isEmpty else { return [] }
        let order = sort == .added ? "sort DESC" : Self.order(sort)
        let sql = "SELECT \(Self.seriesColumns) FROM series WHERE source_id = ? AND \(Self.memberSetFilter(.series, count: categoryIds.count))"
            + " ORDER BY \(order) LIMIT ? OFFSET ?"
        let args: [SQLiteValue] = [.text(sourceId), .text(sourceId)] + categoryIds.map(SQLiteValue.text) + [.int(Int64(limit)), .int(Int64(offset))]
        return try db.query(sql, args, map: Self.series)
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

    /// Full-text search over channel, movie and series titles plus cast/director (prefix match per token, case
    /// and diacritics folded; provider prefixes/punctuation such as "TR:", "|DE|", "[HD]" are not tokens).
    ///
    /// Returns up to `perKindLimit` **title** hits per kind, grouped live → movie → series (one global limit
    /// let the far more numerous movies fill every slot), followed by up to `perKindLimit` **person** hits
    /// (movies/series whose `people` match every token but whose title does not; `matchedPerson` set).
    public func search(_ text: String, sourceId: String? = nil, perKindLimit: Int = 30) throws -> [SearchHit] {
        let tokens = Self.tokens(text)
        guard !tokens.isEmpty, perKindLimit > 0 else { return [] }
        // While the v6 index is still being filled in the background (`backfillSearchIndex`) FTS would miss
        // titles: the LIKE path answers (titles only) until it is done.
        if db.hasFTS5, !database.searchBackfillPending {
            return try searchFTS(tokens: tokens, sourceId: sourceId, perKindLimit: perKindLimit)
        }
        return try searchLike(tokens: tokens, sourceId: sourceId, perKindLimit: perKindLimit)
    }

    /// Re-indexes titles of content stored before search index v6 (`SearchBackfill`), in transactions of
    /// `chunkSize` rows; resumable after a kill. Call off the main thread. Returns true when done.
    @discardableResult
    public func backfillSearchIndex(chunkSize: Int = 2000, maxChunks: Int = .max) throws -> Bool {
        try SearchBackfill.run(db, chunkSize: chunkSize, maxChunks: maxChunks)
    }

    static func tokens(_ text: String) -> [String] {
        text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
    }

    /// Two FTS queries: titles ranked per kind with a window function (measured ~40 % faster than three
    /// `AND kind = ?` queries, which each re-scan every match of the token at 50k+ rows), then people
    /// (`{people}` column filter, title matches excluded with NOT).
    func searchFTS(tokens: [String], sourceId: String?, perKindLimit: Int) throws -> [SearchHit] {
        let phrase = tokens.map { "\"\($0)\"*" }.joined(separator: " ")
        var scope = ""
        var scopeArgs: [SQLiteValue] = []
        if let sourceId { scope = " AND source_id = ?"; scopeArgs = [.text(sourceId)] }
        else { scope = " AND source_id NOT LIKE '%\(AppDatabase.stagingSuffix)'" }

        let inner = "SELECT source_id, kind, item_id, title, ROW_NUMBER() OVER (PARTITION BY kind ORDER BY rank) AS rn "
            + "FROM search_index WHERE search_index MATCH ?" + scope
        let sql = "SELECT source_id, kind, item_id, title FROM (\(inner)) WHERE rn <= ? "
            + "ORDER BY CASE kind WHEN 'live' THEN 0 WHEN 'movie' THEN 1 ELSE 2 END, rn"
        var hits = try db.query(sql, [.text("{title} : (\(phrase))")] + scopeArgs + [.int(Int64(perKindLimit))]) {
            SearchHit(sourceId: $0.string(0), kind: ContentKind(rawValue: $0.string(1)) ?? .live,
                      itemId: $0.string(2), title: CatalogPeople.display($0.string(3)))
        }
        let people = "SELECT source_id, kind, item_id, title, people FROM search_index WHERE search_index MATCH ?" + scope
            + " ORDER BY rank LIMIT ?"
        hits += try db.query(people, [.text("{people} : (\(phrase)) NOT {title} : (\(phrase))")] + scopeArgs
                             + [.int(Int64(perKindLimit))]) {
            SearchHit(sourceId: $0.string(0), kind: ContentKind(rawValue: $0.string(1)) ?? .movie, itemId: $0.string(2),
                      title: CatalogPeople.display($0.string(3)),
                      matchedPerson: CatalogPeople.matchedPerson(CatalogPeople.display($0.string(4)), tokens: tokens))
        }
        return hits
    }

    /// Cast/director learned from a detail fetch (Xtream `get_vod_info` / `get_series_info`): searchable at
    /// once and kept across refreshes (`item_people`). Unchanged people are not rewritten; the index row is
    /// found through its title tokens (FTS) and updated by rowid – no scan of the whole index. Call off the
    /// main thread.
    public func updatePeople(sourceId: String, kind: ContentKind, itemId: String, cast: String?, director: String?) throws {
        guard let people = CatalogPeople.text(cast: cast, director: director) else { return }
        let known = try db.queryFirst("SELECT people FROM item_people WHERE source_id = ? AND kind = ? AND item_id = ?",
                                      [.text(sourceId), .text(kind.rawValue), .text(itemId)]) { $0.string(0) }
        guard known != people else { return }
        try db.transaction {
            try db.run("INSERT OR REPLACE INTO item_people (source_id, kind, item_id, people) VALUES (?,?,?,?)",
                       [.text(sourceId), .text(kind.rawValue), .text(itemId), .text(people)])
            try Self.setIndexPeople(db: db, sourceId: sourceId, kind: kind, itemId: itemId, people: people)
        }
    }

    /// Writes `people` into the search index row of one item (located via its title tokens, then rowid).
    static func setIndexPeople(db: SQLiteDatabase, sourceId: String, kind: ContentKind, itemId: String, people: String) throws {
        guard db.hasFTS5 else { return }
        let table: String
        switch kind {
        case .live: table = "channels"
        case .movie: table = "movies"
        case .series: table = "series"
        case .episode: return
        }
        let name = try db.queryFirst("SELECT name FROM \(table) WHERE source_id = ? AND id = ?", [.text(sourceId), .text(itemId)]) { $0.string(0) }
        let scope: [SQLiteValue] = [.text(sourceId), .text(kind.rawValue), .text(itemId)]
        let rowids: [Int64]
        let titleTokens = name.map(tokens) ?? []
        if titleTokens.isEmpty {
            rowids = try db.query("SELECT rowid FROM search_index WHERE source_id = ? AND kind = ? AND item_id = ?", scope) { $0.int64(0) }
        } else {
            let match = "{title} : (" + titleTokens.map { "\"\($0)\"" }.joined(separator: " ") + ")"
            rowids = try db.query("SELECT rowid FROM search_index WHERE search_index MATCH ? AND source_id = ? AND kind = ? AND item_id = ?",
                                  [.text(match)] + scope) { $0.int64(0) }
        }
        for rowid in rowids {
            try db.run("UPDATE search_index SET people = ? WHERE rowid = ?", [.text(CatalogPeople.indexed(people)), .int(rowid)])
        }
    }

    /// Categories matching every token of `text` (≥ 2 characters): each token is the start of a word of the
    /// name without its group code ("disney" → "EN | Disney+ Movies"); the group code itself only counts next
    /// to another token ("tr disney"), so "tr" or "a" alone do not fill the result with whole countries.
    /// Movie, series, then live, provider order, at most `limit`; hidden ones left out.
    public static func matchCategories(_ text: String, infos: [CategoryInfo], limit: Int = 12,
                                       hidden: (CategoryKind) -> Set<String> = { _ in [] }) -> [CategoryInfo] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let tokens = trimmed.split(whereSeparator: { $0.isWhitespace }).map { CategoryCountry.fold(String($0)) }.filter { !$0.isEmpty }
        guard trimmed.count >= 2, !tokens.isEmpty, limit > 0 else { return [] }
        let order: [CategoryKind: Int] = [.movie: 0, .series: 1, .live: 2]
        var hiddenCache: [CategoryKind: Set<String>] = [:]
        var out: [CategoryInfo] = []
        for info in infos.sorted(by: { (order[$0.category.kind] ?? 3, $0.category.sort) < (order[$1.category.kind] ?? 3, $1.category.sort) }) {
            let kind = info.category.kind
            if hiddenCache[kind] == nil { hiddenCache[kind] = hidden(kind) }
            guard !(hiddenCache[kind] ?? []).contains(info.id) else { continue }
            let words = CategoryCountry.fold(CategoryCountry.nameWithoutPrefix(info.category.name))
                .components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
            let codes = Set([info.countryCode, CategoryCountry.leadingPrefix(info.category.name)?.token]
                .compactMap { $0.map(CategoryCountry.fold) })
            var nameHits = 0
            let all = tokens.allSatisfy { t in
                if words.contains(where: { $0.hasPrefix(t) }) { nameHits += 1; return true }
                return tokens.count > 1 && codes.contains(t)
            }
            guard all, nameHits > 0 else { continue }
            out.append(info)
            if out.count == limit { break }
        }
        return out
    }

    /// `matchCategories` over the source's movie, series and live categories (tests / one-off use; the search
    /// screen caches `categoryInfos`).
    public func searchCategories(_ text: String, sourceId: String, limit: Int = 12,
                                 hidden: (CategoryKind) -> Set<String> = { _ in [] }) throws -> [CategoryInfo] {
        let infos = try [CategoryKind.movie, .series, .live].flatMap { try categoryInfos(sourceId: sourceId, kind: $0) }
        return Self.matchCategories(text, infos: infos, limit: limit, hidden: hidden)
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

    /// "kind|itemId" → people learned from detail fetches (`item_people`), used when a list row has none.
    private let detailPeople: [String: String]

    init(db: SQLiteDatabase, sourceId: String) throws {
        self.db = db
        self.sourceId = sourceId
        self.stagingId = sourceId + AppDatabase.stagingSuffix
        let rows = try db.query("SELECT kind, item_id, people FROM item_people WHERE source_id = ?", [.text(sourceId)]) {
            ("\($0.string(0))|\($0.string(1))", $0.string(2))
        }
        detailPeople = Dictionary(rows, uniquingKeysWith: { a, _ in a })
        try clearStaging()
    }

    private func people(kind: ContentKind, itemId: String, cast: String?, director: String?) -> String {
        CatalogPeople.text(cast: cast, director: director) ?? detailPeople["\(kind.rawValue)|\(itemId)"] ?? ""
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
                try index(title: c.name, people: "", kind: .live, itemId: c.id)
                try member(kind: .live, itemId: c.id, categoryIds: c.categoryIds, sort: c.sort)
            }
            for m in movies {
                try db.run("INSERT OR REPLACE INTO movies (\(CatalogRepository.movieColumns)) VALUES (?,?,?,?,?,?,?,?,?,?,?,?)",
                           [.text(sid), .text(m.id), .text(m.name), .from(m.posterUrl), .from(m.categoryId), .from(m.rating),
                            .from(m.year), .from(m.plot), .from(m.containerExt), .from(m.url), .from(m.addedAt), .from(m.sort)])
                try index(title: m.name, people: people(kind: .movie, itemId: m.id, cast: m.cast, director: m.director),
                          kind: .movie, itemId: m.id)
                try member(kind: .movie, itemId: m.id, categoryIds: m.categoryIds, sort: m.sort)
            }
            for s in series {
                try db.run("INSERT OR REPLACE INTO series (\(CatalogRepository.seriesColumns)) VALUES (?,?,?,?,?,?,?,?,?)",
                           [.text(sid), .text(s.id), .text(s.name), .from(s.posterUrl), .from(s.categoryId), .from(s.plot),
                            .from(s.rating), .from(s.year), .from(s.sort)])
                try index(title: s.name, people: people(kind: .series, itemId: s.id, cast: s.cast, director: s.director),
                          kind: .series, itemId: s.id)
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

    private func index(title: String, people: String, kind: ContentKind, itemId: String) throws {
        guard db.hasFTS5 else { return }
        try db.run("INSERT INTO search_index (title, people, source_id, kind, item_id) VALUES (?,?,?,?,?)",
                   [.text(CatalogPeople.indexed(title)), .text(CatalogPeople.indexed(people)), .text(stagingId),
                    .text(kind.rawValue), .text(itemId)])
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
                // People learned from detail pages while this refresh ran (after the snapshot in `init`).
                let current = try db.query("SELECT kind, item_id, people FROM item_people WHERE source_id = ?", [.text(sourceId)]) {
                    (kind: $0.string(0), itemId: $0.string(1), people: $0.string(2))
                }
                for row in current where detailPeople["\(row.kind)|\(row.itemId)"] != row.people {
                    guard let kind = ContentKind(rawValue: row.kind) else { continue }
                    try CatalogRepository.setIndexPeople(db: db, sourceId: sourceId, kind: kind, itemId: row.itemId, people: row.people)
                }
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
