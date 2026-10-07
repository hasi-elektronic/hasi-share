import Foundation
import IPTVCore

/// Sort order of movie/series grids (docs/SCREENS.md §3.4).
public enum CatalogSort: String, Sendable, Hashable, CaseIterable {
    case added, az, rating
}

/// How a search hit matched (SCREENS §3.6).
public enum SearchMatch: String, Sendable, Hashable {
    /// Every word in the title.
    case title
    /// Every word in the cast/director, not in the title.
    case person
    /// In the description (or spread over title, people and description).
    case description
}

/// One full-text search hit.
public struct SearchHit: Sendable, Hashable, Identifiable {
    public var sourceId: String
    public var kind: ContentKind
    public var itemId: String
    public var title: String
    /// Person hits only (title does not match, cast/director does): the matched person ("Hasan Can Kaya").
    public var matchedPerson: String?
    /// Description hits only: an excerpt with the matched words marked.
    public var snippet: SearchSnippet?
    public var id: String { "\(sourceId)|\(kind.rawValue)|\(itemId)" }
    public var isPersonMatch: Bool { matchedPerson != nil }
    public var match: SearchMatch { matchedPerson != nil ? .person : snippet != nil ? .description : .title }

    public init(sourceId: String, kind: ContentKind, itemId: String, title: String, matchedPerson: String? = nil,
                snippet: SearchSnippet? = nil) {
        self.sourceId = sourceId
        self.kind = kind
        self.itemId = itemId
        self.title = title
        self.matchedPerson = matchedPerson
        self.snippet = snippet
    }
}

/// What a paged search list shows ("See all" of a section, filter chips; SCREENS §3.6).
public enum SearchScope: Hashable, Sendable {
    /// Title matches of one kind (the Channels / Movies / Series sections).
    case titles(ContentKind)
    /// Cast/director matches whose title does not match (People).
    case people
    /// Matches in the description or spread over the columns, neither title nor people alone (In descriptions).
    case descriptions
    /// Every match of one kind, ranked title ≫ people > description, exact phrase first (filter chips).
    case kind(ContentKind)
}

/// A completion offered while typing (title or person name).
public struct SearchSuggestion: Sendable, Hashable, Identifiable {
    public var text: String
    public var isPerson: Bool
    public var id: String { "\(isPerson ? "p" : "t")|\(text)" }
    public init(text: String, isPerson: Bool) {
        self.text = text
        self.isPerson = isPerson
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

    /// Indexed form of a long text (description): only the words with "ı"/"İ" get their "i" variant, once each,
    /// after `variantMark` – appending the whole text again would double long descriptions and skew bm25.
    public static func indexedWords(_ text: String) -> String {
        guard text.contains("ı") || text.contains("İ") else { return text }
        var seen = Set<String>()
        let variants = text.components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.contains("ı") || $0.contains("İ") }
            .map { $0.replacingOccurrences(of: "ı", with: "i").replacingOccurrences(of: "İ", with: "I") }
            .filter { seen.insert($0.lowercased()).inserted }
        return text + " \(variantMark) " + variants.joined(separator: " ")
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
            for table in ["categories", "item_categories", "item_people", "item_plot", "search_terms", "channels", "movies",
                          "series", "episodes", "epg"] {
                try db.run("DELETE FROM \(table) WHERE source_id = ? OR source_id = ?",
                           [.text(sourceId), .text(sourceId + AppDatabase.stagingSuffix)])
            }
            if db.hasFTS5 {
                try db.run("DELETE FROM search_index WHERE source_id = ? OR source_id = ?",
                           [.text(sourceId), .text(sourceId + AppDatabase.stagingSuffix)])
                try SearchBackfill.skipSource(db, sourceId)
                try SearchIndex.drop(db, sourceId: sourceId)
            }
            try EpgSearchIndex.drop(db, sourceId: sourceId)
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

    /// Channels whose EPG id is one of `epgIds` (SQLite `lower()` comparison, like the EPG lookups), list order.
    public func channels(sourceId: String, epgIds: [String]) throws -> [Channel] {
        let ids = Array(Set(epgIds))
        guard !ids.isEmpty else { return [] }
        var out: [Channel] = []
        for start in stride(from: 0, to: ids.count, by: 400) {
            let chunk = Array(ids[start..<min(start + 400, ids.count)])
            let list = Array(repeating: "lower(?)", count: chunk.count).joined(separator: ",")
            out += try db.query("SELECT \(Self.channelColumns) FROM channels WHERE source_id = ? AND lower(epg_id) IN (\(list)) ORDER BY sort",
                                [.text(sourceId)] + chunk.map(SQLiteValue.text), map: Self.channel)
        }
        return out.sorted { $0.sort < $1.sort }
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

    /// Movies by id, in the order given (search results).
    public func movies(sourceId: String, ids: [String]) throws -> [Movie] {
        try byIds(ids) { chunk in
            try db.query("SELECT \(Self.movieColumns) FROM movies WHERE source_id = ? AND id IN (\(Self.placeholders(chunk.count)))",
                         [.text(sourceId)] + chunk.map(SQLiteValue.text), map: Self.movie)
        }
    }

    /// Series by id, in the order given (search results).
    public func series(sourceId: String, ids: [String]) throws -> [Series] {
        try byIds(ids) { chunk in
            try db.query("SELECT \(Self.seriesColumns) FROM series WHERE source_id = ? AND id IN (\(Self.placeholders(chunk.count)))",
                         [.text(sourceId)] + chunk.map(SQLiteValue.text), map: Self.series)
        }
    }

    static func placeholders(_ n: Int) -> String { Array(repeating: "?", count: n).joined(separator: ",") }

    private func byIds<T: Identifiable>(_ ids: [String], _ fetch: ([String]) throws -> [T]) throws -> [T] where T.ID == String {
        guard !ids.isEmpty else { return [] }
        var byId: [String: T] = [:]
        for start in stride(from: 0, to: ids.count, by: 400) {
            for row in try fetch(Array(ids[start..<min(start + 400, ids.count)])) where byId[row.id] == nil { byId[row.id] = row }
        }
        return ids.compactMap { byId[$0] }
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

    /// Full-text search over channel, movie and series titles, cast/director and descriptions (prefix match per
    /// token, case and diacritics folded; provider prefixes/punctuation such as "TR:", "|DE|", "[HD]" are not
    /// tokens). Ranking: bm25 with column weights title 10 · people 4 · description 1, an exact phrase
    /// ("hasan can kaya") above scattered words.
    ///
    /// Returns up to `perKindLimit` **title** hits per kind, grouped live → movie → series (one global limit
    /// let the far more numerous movies fill every slot), then up to `perKindLimit` **person** hits
    /// (movies/series whose `people` match every token but whose title does not; `matchedPerson` set), then up
    /// to `perKindLimit` **description** hits (`snippet` set).
    public func search(_ text: String, sourceId: String? = nil, perKindLimit: Int = 30) throws -> [SearchHit] {
        let tokens = Self.tokens(text)
        guard !tokens.isEmpty, perKindLimit > 0 else { return [] }
        // While the index is still being filled in the background (`backfillSearchIndex`) FTS would miss
        // titles: the LIKE path answers (titles only) until it is done.
        guard ftsReady else { return try searchLike(tokens: tokens, sourceId: sourceId, perKindLimit: perKindLimit) }
        return try searchFTS(tokens: tokens, sourceId: sourceId, perKindLimit: perKindLimit)
            + searchPage(.people, tokens: tokens, sourceId: sourceId, offset: 0, limit: perKindLimit)
            + searchPage(.descriptions, tokens: tokens, sourceId: sourceId, offset: 0, limit: perKindLimit)
    }

    /// Title hits only, per kind (short queries: 1–2 letters).
    public func searchTitles(_ text: String, sourceId: String? = nil, perKindLimit: Int = 30) throws -> [SearchHit] {
        let tokens = Self.tokens(text)
        guard !tokens.isEmpty, perKindLimit > 0 else { return [] }
        guard ftsReady else { return try searchLike(tokens: tokens, sourceId: sourceId, perKindLimit: perKindLimit) }
        return try searchFTS(tokens: tokens, sourceId: sourceId, perKindLimit: perKindLimit)
    }

    /// One page of a search list (offset paging; SCREENS §3.6 "See all" and filter chips).
    public func search(_ text: String, scope: SearchScope, sourceId: String? = nil, offset: Int = 0, limit: Int = 60) throws -> [SearchHit] {
        let tokens = Self.tokens(text)
        guard !tokens.isEmpty, limit > 0 else { return [] }
        guard ftsReady else {
            switch scope {
            case .titles(let kind), .kind(let kind):
                return try searchLike(tokens: tokens, sourceId: sourceId, kinds: [kind], offset: offset, limit: limit)
            case .people, .descriptions:
                return []
            }
        }
        return try searchPage(scope, tokens: tokens, sourceId: sourceId, offset: offset, limit: limit)
    }

    /// FTS index usable (exists and not being rebuilt).
    var ftsReady: Bool { db.hasFTS5 && !database.searchBackfillPending }

    /// (Re-)indexes the search index after a v6/v7 migration (`SearchBackfill`), in transactions of
    /// `chunkSize` rows; resumable after a kill. Call off the main thread. Returns true when done.
    @discardableResult
    public func backfillSearchIndex(chunkSize: Int = 300, maxChunks: Int = .max, pause: TimeInterval = 0.015) throws -> Bool {
        try SearchBackfill.run(db, chunkSize: chunkSize, maxChunks: maxChunks, pause: pause)
    }

    /// Launch maintenance, off the main thread: leftover per-source indexes of killed refreshes, the shared v7
    /// table once no source needs it, the trigram dictionary index if it is missing but supported.
    public func maintainSearchIndex() throws {
        try SearchIndex.maintain(db)
        try SearchTermsIndex.ensure(db)
    }

    static func tokens(_ text: String) -> [String] { SearchText.tokens(text) }

    /// `"a"* "b"*` – every token, prefix match.
    static func ftsExpression(_ tokens: [String]) -> String { tokens.map { "\"\($0)\"*" }.joined(separator: " ") }

    /// `"a b"*` – the tokens as a phrase (last one a prefix); nil for one token.
    static func phraseExpression(_ tokens: [String]) -> String? {
        tokens.count > 1 ? "\"\(tokens.joined(separator: " "))\"*" : nil
    }

    /// `ORDER BY` prefix that puts rows matching the phrase first (one FTS lookup, materialised once).
    private func phraseBoost(_ phrase: String?, table: String) -> (sql: String, args: [SQLiteValue]) {
        guard let phrase else { return ("", []) }
        return ("CASE WHEN rowid IN (SELECT rowid FROM \(table) WHERE \(table) MATCH ?) THEN 0 ELSE 1 END, ", [.text(phrase)])
    }

    /// Titles ranked per kind with a window function (measured ~40 % faster than three `AND kind = ?`
    /// queries, which each re-scan every match of the token at 50k+ rows).
    func searchFTS(tokens: [String], sourceId: String?, perKindLimit: Int) throws -> [SearchHit] {
        let expr = Self.ftsExpression(tokens)
        var hits: [SearchHit] = []
        for target in SearchIndex.targets(db, sourceId: sourceId) {
            let t = target.table
            let boost = phraseBoost(Self.phraseExpression(tokens).map { "{title} : \($0)" }, table: t)
            let inner = "SELECT source_id, kind, item_id, title, ROW_NUMBER() OVER (PARTITION BY kind ORDER BY \(boost.sql)rank) AS rn "
                + "FROM \(t) WHERE \(t) MATCH ?" + target.filter
            let sql = "SELECT source_id, kind, item_id, title FROM (\(inner)) WHERE rn <= ? "
                + "ORDER BY CASE kind WHEN 'live' THEN 0 WHEN 'movie' THEN 1 ELSE 2 END, rn"
            hits += try db.query(sql, boost.args + [.text("{title} : (\(expr))")] + target.args + [.int(Int64(perKindLimit))]) {
                SearchHit(sourceId: $0.string(0), kind: ContentKind(rawValue: $0.string(1)) ?? .live,
                          itemId: $0.string(2), title: CatalogPeople.display($0.string(3)))
            }
        }
        return hits
    }

    /// One page of a scope: MATCH expression, kind filter, phrase boost, then bm25 (`rank`, weights 10/4/1).
    func searchPage(_ searchScope: SearchScope, tokens: [String], sourceId: String?, offset: Int, limit: Int) throws -> [SearchHit] {
        let expr = Self.ftsExpression(tokens)
        let phrase = Self.phraseExpression(tokens)
        let match: String
        var kindFilter = ""
        var kindArgs: [SQLiteValue] = []
        let boostPhrase: String?
        switch searchScope {
        case .titles(let kind):
            match = "{title} : (\(expr))"
            kindFilter = " AND kind = ?"
            kindArgs = [.text(kind.rawValue)]
            boostPhrase = phrase.map { "{title} : \($0)" }
        case .people:
            match = "{people} : (\(expr)) NOT {title} : (\(expr))"
            boostPhrase = phrase.map { "{people} : \($0)" }
        case .descriptions:
            match = "(\(expr)) NOT {title} : (\(expr)) NOT {people} : (\(expr))"
            boostPhrase = phrase
        case .kind(let kind):
            match = "(\(expr))"
            kindFilter = " AND kind = ?"
            kindArgs = [.text(kind.rawValue)]
            boostPhrase = phrase
        }
        let folded = tokens.map(CategoryCountry.fold)
        var hits: [SearchHit] = []
        for target in SearchIndex.targets(db, sourceId: sourceId) {
            let t = target.table
            let boost = phraseBoost(boostPhrase, table: t)
            let sql = "SELECT source_id, kind, item_id, title, people, plot FROM \(t) WHERE \(t) MATCH ?"
                + target.filter + kindFilter + " ORDER BY \(boost.sql)rank LIMIT ? OFFSET ?"
            hits += try db.query(sql, [.text(match)] + target.args + kindArgs + boost.args + [.int(Int64(limit)), .int(Int64(offset))]) { r in
            let title = CatalogPeople.display(r.string(3))
            var hit = SearchHit(sourceId: r.string(0), kind: ContentKind(rawValue: r.string(1)) ?? .movie, itemId: r.string(2), title: title)
            switch searchScope {
            case .titles: break
            case .people:
                hit.matchedPerson = CatalogPeople.matchedPerson(CatalogPeople.display(r.string(4)), tokens: tokens)
            case .descriptions, .kind:
                let people = CatalogPeople.display(r.string(4))
                if case .kind = searchScope, SearchText.matchesAll(title, folded: folded) { break }
                if !people.isEmpty, SearchText.matchesAll(people, folded: folded) {
                    hit.matchedPerson = CatalogPeople.matchedPerson(people, tokens: tokens)
                    break
                }
                let plot = CatalogPeople.display(r.string(5))
                let snippet = SearchText.snippet(plot, tokens: tokens)
                // Words spread over title/people and no description word: the people text is the excerpt.
                hit.snippet = snippet.matchedWords.isEmpty && !people.isEmpty ? SearchText.snippet(people, tokens: tokens) : snippet
            }
            return hit
            }
        }
        return hits
    }

    /// Cast/director learned from a detail fetch (Xtream `get_vod_info` / `get_series_info`): searchable at
    /// once and kept across refreshes (`item_people`). Unchanged people are not rewritten; the index row is
    /// found through its title tokens (FTS) and updated by rowid – no scan of the whole index. Call off the
    /// main thread.
    public func updatePeople(sourceId: String, kind: ContentKind, itemId: String, cast: String?, director: String?) throws {
        try updateDetails(sourceId: sourceId, kind: kind, itemId: itemId, cast: cast, director: director, plot: nil)
    }

    /// Cast/director and description learned from a detail fetch: searchable at once and kept across refreshes
    /// (`item_people`, `item_plot`). A description the list already had is not replaced. Call off the main thread.
    public func updateDetails(sourceId: String, kind: ContentKind, itemId: String, cast: String?, director: String?, plot: String?) throws {
        let key: [SQLiteValue] = [.text(sourceId), .text(kind.rawValue), .text(itemId)]
        if let people = CatalogPeople.text(cast: cast, director: director),
           try db.queryFirst("SELECT people FROM item_people WHERE source_id = ? AND kind = ? AND item_id = ?", key, map: { $0.string(0) }) != people {
            try db.transaction {
                try db.run("INSERT OR REPLACE INTO item_people (source_id, kind, item_id, people) VALUES (?,?,?,?)", key + [.text(people)])
                try Self.setIndexColumn(db: db, "people", sourceId: sourceId, kind: kind, itemId: itemId, value: CatalogPeople.indexed(people))
                var terms = SearchTermCounter()
                terms.add(sourceId, people)
                try terms.upsert(db)
            }
        }
        guard let plot = plot?.trimmingCharacters(in: .whitespacesAndNewlines), !plot.isEmpty,
              let table = SearchBackfill.contentTable(kind.rawValue), table != "channels" else { return }
        let listed = try db.queryFirst("SELECT plot FROM \(table) WHERE source_id = ? AND id = ?", [.text(sourceId), .text(itemId)]) { $0.optString(0) }
        if case let listed?? = listed, !listed.isEmpty { return }
        guard try db.queryFirst("SELECT plot FROM item_plot WHERE source_id = ? AND kind = ? AND item_id = ?", key, map: { $0.string(0) }) != plot else { return }
        try db.transaction {
            try db.run("INSERT OR REPLACE INTO item_plot (source_id, kind, item_id, plot) VALUES (?,?,?,?)", key + [.text(plot)])
            try db.run("UPDATE \(table) SET plot = ? WHERE source_id = ? AND id = ?", [.text(plot), .text(sourceId), .text(itemId)])
            try Self.setIndexColumn(db: db, "plot", sourceId: sourceId, kind: kind, itemId: itemId,
                                    value: CatalogPeople.indexedWords(String(plot.prefix(SearchBackfill.maxPlot))))
        }
    }

    /// Writes `people` into the search index row of one item (located via its title tokens, then rowid).
    static func setIndexPeople(db: SQLiteDatabase, sourceId: String, kind: ContentKind, itemId: String, people: String) throws {
        try setIndexColumn(db: db, "people", sourceId: sourceId, kind: kind, itemId: itemId, value: CatalogPeople.indexed(people))
    }

    /// Writes one column (`people` / `plot`) of the search index row of an item (found via its title tokens).
    static func setIndexColumn(db: SQLiteDatabase, _ column: String, sourceId: String, kind: ContentKind, itemId: String, value: String) throws {
        guard db.hasFTS5, column == "people" || column == "plot", let table = SearchBackfill.contentTable(kind.rawValue) else { return }
        let name = try db.queryFirst("SELECT name FROM \(table) WHERE source_id = ? AND id = ?", [.text(sourceId), .text(itemId)]) { $0.string(0) }
        let scope: [SQLiteValue] = [.text(sourceId), .text(kind.rawValue), .text(itemId)]
        let rowids: [Int64]
        let titleTokens = name.map(tokens) ?? []
        let t = SearchIndex.tableForWrites(db, sourceId: sourceId)
        if titleTokens.isEmpty {
            rowids = try db.query("SELECT rowid FROM \(t) WHERE source_id = ? AND kind = ? AND item_id = ?", scope) { $0.int64(0) }
        } else {
            let match = "{title} : (" + titleTokens.map { "\"\($0)\"" }.joined(separator: " ") + ")"
            rowids = try db.query("SELECT rowid FROM \(t) WHERE \(t) MATCH ? AND source_id = ? AND kind = ? AND item_id = ?",
                                  [.text(match)] + scope) { $0.int64(0) }
        }
        for rowid in rowids {
            try db.run("UPDATE \(t) SET \(column) = ? WHERE rowid = ?", [.text(value), .int(rowid)])
        }
    }

    // MARK: Suggestions and did-you-mean

    /// Up to `limit` completions while typing (≥ 2 characters): titles whose words start with the tokens, then
    /// person names (at most two), without repeats or the query itself.
    public func completions(_ text: String, sourceId: String?, limit: Int = 5) throws -> [SearchSuggestion] {
        let tokens = Self.tokens(text)
        guard text.trimmingCharacters(in: .whitespaces).count >= 2, !tokens.isEmpty, limit > 0, ftsReady else { return [] }
        let expr = Self.ftsExpression(tokens)
        let targets = SearchIndex.targets(db, sourceId: sourceId)
        let folded = tokens.map(CategoryCountry.fold)
        let queryKey = folded.joined(separator: " ")
        var seen: Set<String> = [queryKey]
        var titles: [SearchSuggestion] = []
        let titleRows = try targets.flatMap { t in
            try db.query("SELECT title FROM \(t.table) WHERE \(t.table) MATCH ?" + t.filter + " ORDER BY rank LIMIT 25",
                         [.text("{title} : (\(expr))")] + t.args, map: { $0.string(0) })
        }
        for raw in titleRows {
            let title = CategoryCountry.nameWithoutPrefix(CatalogPeople.display(raw)).trimmingCharacters(in: .whitespaces)
            let key = SearchText.foldedTokens(title).joined(separator: " ")
            guard !title.isEmpty, seen.insert(key).inserted else { continue }
            titles.append(SearchSuggestion(text: title, isPerson: false))
        }
        var people: [SearchSuggestion] = []
        let peopleRows = try targets.flatMap { t in
            try db.query("SELECT people FROM \(t.table) WHERE \(t.table) MATCH ?" + t.filter + " ORDER BY rank LIMIT 25",
                         [.text("{people} : (\(expr))")] + t.args, map: { $0.string(0) })
        }
        for raw in peopleRows {
            for name in CatalogPeople.display(raw).split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) })
            where SearchText.matchesAll(name, folded: folded) {
                let key = SearchText.foldedTokens(name).joined(separator: " ")
                if seen.insert(key).inserted { people.append(SearchSuggestion(text: name, isPerson: true)) }
            }
            if people.count >= 2 { break }
        }
        let personCount = min(people.count, 2, limit)
        return Array(titles.prefix(limit - personCount)) + people.prefix(personCount)
    }

    /// "Did you mean": the query with every unknown word (no dictionary term starts with it) replaced by the
    /// closest title/person word of the source (edit distance ≤ 1 for ≤ 4 letters, else ≤ 2; ties → the more
    /// frequent word), found through the trigram index. nil when nothing could be corrected.
    public func correction(for text: String, sourceId: String?) throws -> String? {
        guard db.hasTrigram, SearchTermsIndex.exists(db) else { return nil }
        let tokens = Self.tokens(text)
        guard !tokens.isEmpty else { return nil }
        var changed = false
        var out: [String] = []
        for token in tokens {
            let folded = CategoryCountry.fold(token)
            guard folded.count >= 3, !folded.allSatisfy(\.isNumber), try !isKnownTerm(folded, sourceId: sourceId),
                  let best = try closestTerm(folded, sourceId: sourceId) else {
                out.append(token)
                continue
            }
            out.append(best)
            changed = true
        }
        return changed ? out.joined(separator: " ") : nil
    }

    /// A dictionary term starts with `prefix` (index range scan).
    private func isKnownTerm(_ prefix: String, sourceId: String?) throws -> Bool {
        let upper = prefix + "\u{10FFFF}"
        if let sourceId {
            return try db.scalar("SELECT EXISTS (SELECT 1 FROM search_terms WHERE source_id = ? AND term >= ? AND term < ?)",
                                 [.text(sourceId), .text(prefix), .text(upper)]) != 0
        }
        return try db.scalar("SELECT EXISTS (SELECT 1 FROM search_terms WHERE term >= ? AND term < ?)", [.text(prefix), .text(upper)]) != 0
    }

    private func closestTerm(_ token: String, sourceId: String?) throws -> String? {
        guard let query = SearchText.trigramQuery(token) else { return nil }
        // The source filter comes before the candidate limit (other sources' words must not take the 300 slots).
        var sql = "SELECT s.term, s.display, s.freq FROM search_terms_tri f JOIN search_terms s ON s.rowid = f.rowid "
            + "WHERE search_terms_tri MATCH ?"
        var args: [SQLiteValue] = [.text(query)]
        if let sourceId { sql += " AND s.source_id = ?"; args.append(.text(sourceId)) }
        sql += " ORDER BY f.rank LIMIT 300"
        let limit = SearchText.maxTypos(token.count)
        var best: (distance: Int, prefixOnly: Bool, freq: Int, display: String)?
        for row in try db.query(sql, args, map: { (term: $0.string(0), display: $0.string(1), freq: $0.int(2)) }) {
            let full = SearchText.distance(token, row.term, limit: limit)
            let prefix = row.term.count > token.count ? SearchText.distance(token, String(row.term.prefix(token.count)), limit: limit) : full
            let distance = min(full, prefix)
            guard distance <= limit else { continue }
            let candidate = (distance: distance, prefixOnly: full > distance, freq: row.freq, display: row.display)
            if let b = best, (b.distance, b.prefixOnly ? 1 : 0, -b.freq) <= (candidate.distance, candidate.prefixOnly ? 1 : 0, -candidate.freq) { continue }
            best = candidate
        }
        return best?.display
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

    /// Fallback without FTS5 (or while the index is rebuilt): LIKE over the titles, same per-kind limit and order.
    func searchLike(tokens: [String], sourceId: String?, perKindLimit: Int) throws -> [SearchHit] {
        try searchLike(tokens: tokens, sourceId: sourceId, kinds: [.live, .movie, .series], offset: 0, limit: perKindLimit)
    }

    func searchLike(tokens: [String], sourceId: String?, kinds: [ContentKind], offset: Int, limit: Int) throws -> [SearchHit] {
        var hits: [SearchHit] = []
        // Tokens carry "ı/İ → i"; the name gets the same folding, so "kızılcık" finds "Kızılcık" here too.
        let pattern = "%" + tokens.joined(separator: "%") + "%"
        for kind in kinds {
            guard let table = SearchBackfill.contentTable(kind.rawValue) else { continue }
            var sql = "SELECT source_id, id, name FROM \(table) WHERE replace(replace(name, 'ı', 'i'), 'İ', 'i') LIKE ? "
                + "AND source_id NOT LIKE '%\(AppDatabase.stagingSuffix)'"
            var args: [SQLiteValue] = [.text(pattern)]
            if let sourceId { sql += " AND source_id = ?"; args.append(.text(sourceId)) }
            sql += " ORDER BY sort LIMIT ? OFFSET ?"
            args += [.int(Int64(limit)), .int(Int64(offset))]
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

    /// "kind|itemId" → people / description learned from detail fetches (`item_people`, `item_plot`), used
    /// when a list row has none.
    private let detailPeople: [String: String]
    private let detailPlot: [String: String]
    /// Words of the written titles and people (did-you-mean dictionary, replaced on commit).
    private var terms = SearchTermCounter()
    /// The source's new search index (`SearchIndex`), filled with the batches and swapped in on commit.
    let searchTable: String?

    init(db: SQLiteDatabase, sourceId: String) throws {
        self.db = db
        self.sourceId = sourceId
        self.stagingId = sourceId + AppDatabase.stagingSuffix
        detailPeople = try Self.details(db, "item_people", "people", sourceId)
        detailPlot = try Self.details(db, "item_plot", "plot", sourceId)
        searchTable = db.hasFTS5 ? try SearchIndex.create(db) : nil
        try clearStaging()
    }

    private static func details(_ db: SQLiteDatabase, _ table: String, _ column: String, _ sourceId: String) throws -> [String: String] {
        let rows = try db.query("SELECT kind, item_id, \(column) FROM \(table) WHERE source_id = ?", [.text(sourceId)]) {
            ("\($0.string(0))|\($0.string(1))", $0.string(2))
        }
        return Dictionary(rows, uniquingKeysWith: { a, _ in a })
    }

    private func people(kind: ContentKind, itemId: String, cast: String?, director: String?) -> String {
        CatalogPeople.text(cast: cast, director: director) ?? detailPeople["\(kind.rawValue)|\(itemId)"] ?? ""
    }

    private func plot(kind: ContentKind, itemId: String, listed: String?) -> String? {
        if let listed = listed?.trimmingCharacters(in: .whitespacesAndNewlines), !listed.isEmpty { return listed }
        return detailPlot["\(kind.rawValue)|\(itemId)"]
    }

    private func clearStaging() throws {
        try db.transaction {
            for table in ["categories", "item_categories", "channels", "movies", "series", "episodes"] {
                try db.run("DELETE FROM \(table) WHERE source_id = ?", [.text(stagingId)])
            }
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
                try index(title: c.name, people: "", plot: nil, kind: .live, itemId: c.id)
                try member(kind: .live, itemId: c.id, categoryIds: c.categoryIds, sort: c.sort)
            }
            for m in movies {
                let plot = plot(kind: .movie, itemId: m.id, listed: m.plot)
                try db.run("INSERT OR REPLACE INTO movies (\(CatalogRepository.movieColumns)) VALUES (?,?,?,?,?,?,?,?,?,?,?,?)",
                           [.text(sid), .text(m.id), .text(m.name), .from(m.posterUrl), .from(m.categoryId), .from(m.rating),
                            .from(m.year), .from(plot), .from(m.containerExt), .from(m.url), .from(m.addedAt), .from(m.sort)])
                try index(title: m.name, people: people(kind: .movie, itemId: m.id, cast: m.cast, director: m.director),
                          plot: plot, kind: .movie, itemId: m.id)
                try member(kind: .movie, itemId: m.id, categoryIds: m.categoryIds, sort: m.sort)
            }
            for s in series {
                let plot = plot(kind: .series, itemId: s.id, listed: s.plot)
                try db.run("INSERT OR REPLACE INTO series (\(CatalogRepository.seriesColumns)) VALUES (?,?,?,?,?,?,?,?,?)",
                           [.text(sid), .text(s.id), .text(s.name), .from(s.posterUrl), .from(s.categoryId), .from(plot),
                            .from(s.rating), .from(s.year), .from(s.sort)])
                try index(title: s.name, people: people(kind: .series, itemId: s.id, cast: s.cast, director: s.director),
                          plot: plot, kind: .series, itemId: s.id)
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

    private func index(title: String, people: String, plot: String?, kind: ContentKind, itemId: String) throws {
        terms.add(sourceId, title)
        terms.add(sourceId, people)
        guard let searchTable else { return }
        try SearchBackfill.insert(db, table: searchTable, title: title, people: people, plot: plot ?? "", sourceId: sourceId,
                                  kind: kind.rawValue, itemId: itemId, indexed: false)
    }

    /// Milliseconds the last `commit()` held the writer: the atomic swap, its search-index part (re-pointing +
    /// dropping the old index + detail merges) and the dictionary update after it.
    public private(set) var swapMilliseconds = 0.0
    public private(set) var indexMilliseconds = 0.0
    public private(set) var dictionaryMilliseconds = 0.0

    /// Makes the staged rows the live content of the source (atomic swap).
    public func commit() throws {
        guard !finished else { return }
        finished = true
        let started = DispatchTime.now()
        var previousIndex: String?
        try db.transaction {
            for table in ["categories", "item_categories", "channels", "movies", "series", "episodes"] {
                try db.run("DELETE FROM \(table) WHERE source_id = ?", [.text(sourceId)])
                try db.run("UPDATE \(table) SET source_id = ? WHERE source_id = ?", [.text(sourceId), .text(stagingId)])
            }
            let indexStart = DispatchTime.now()
            defer { indexMilliseconds = Self.ms(since: indexStart) }
            if let searchTable {
                // The new index becomes the source's (kv + DROP of the old one): no row is re-tokenised here.
                // Its rows left in the shared v7 table are ignored from now on and emptied by `SearchIndex.maintain`.
                previousIndex = try SearchIndex.register(db, sourceId: sourceId, table: searchTable)
                try SearchBackfill.skipSource(db, sourceId)   // a pending v7 copy must not bring the old rows back
                // People / descriptions learned from detail pages while this refresh ran (after the snapshot in `init`).
                for (table, column, known) in [("item_people", "people", detailPeople), ("item_plot", "plot", detailPlot)] {
                    let current = try db.query("SELECT kind, item_id, \(column) FROM \(table) WHERE source_id = ?", [.text(sourceId)]) {
                        (kind: $0.string(0), itemId: $0.string(1), value: $0.string(2))
                    }
                    for row in current where known["\(row.kind)|\(row.itemId)"] != row.value {
                        guard let kind = ContentKind(rawValue: row.kind) else { continue }
                        if column == "people" {
                            terms.add(sourceId, row.value)
                            try CatalogRepository.setIndexPeople(db: db, sourceId: sourceId, kind: kind, itemId: row.itemId, people: row.value)
                        } else if let contentTable = SearchBackfill.contentTable(row.kind), contentTable != "channels" {
                            let listed = try db.queryFirst("SELECT plot FROM \(contentTable) WHERE source_id = ? AND id = ?",
                                                           [.text(sourceId), .text(row.itemId)]) { $0.optString(0) }
                            guard case let .some(value) = listed else { continue }   // not in the new catalog
                            if let value, !value.isEmpty { continue }                // the list has its own description
                            try db.run("UPDATE \(contentTable) SET plot = ? WHERE source_id = ? AND id = ?",
                                       [.text(row.value), .text(sourceId), .text(row.itemId)])
                            try CatalogRepository.setIndexColumn(db: db, "plot", sourceId: sourceId, kind: kind, itemId: row.itemId,
                                                                 value: CatalogPeople.indexedWords(String(row.value.prefix(SearchBackfill.maxPlot))))
                        }
                    }
                }
            }
        }
        // The did-you-mean dictionary follows in its own transaction (only a suggestion source; the first fill
        // after the v7 update writes ~30k words, which should not lengthen the swap's lock).
        swapMilliseconds = Self.ms(since: started)
        if let previousIndex { try? db.transaction { try SearchIndex.dropTable(db, previousIndex) } }
        let dictionaryStart = DispatchTime.now()
        do { try db.transaction { try terms.replace(db, sourceId: sourceId) } } catch { SafeLog.warning("search terms update failed") }
        dictionaryMilliseconds = Self.ms(since: dictionaryStart)
    }

    static func ms(since start: DispatchTime) -> Double { Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1e6 }

    /// Discards the staged rows; live content stays untouched.
    public func abort() {
        guard !finished else { return }
        finished = true
        try? clearStaging()
        if let searchTable { SearchIndex.discard(db, table: searchTable) }
    }
}
