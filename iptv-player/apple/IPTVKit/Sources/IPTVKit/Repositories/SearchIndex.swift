import Foundation

/// Tables being built in this process (refresh sessions, backfills): never dropped as leftovers.
final class IndexTablesInFlight: @unchecked Sendable {
    static let shared = IndexTablesInFlight()
    private let lock = NSLock()
    private var names: Set<String> = []
    func insert(_ name: String) { lock.lock(); names.insert(name); lock.unlock() }
    func remove(_ name: String) { lock.lock(); names.remove(name); lock.unlock() }
    func contains(_ name: String) -> Bool { lock.lock(); defer { lock.unlock() }; return names.contains(name) }
}

/// Per-source FTS5 search index (Build 12): `search_fts_<random>` with the v7 columns, its name in kv
/// `search.fts.<sourceId>`. A catalog refresh fills a **new** table next to its staging rows and the commit only
/// re-points the kv entry and drops the old table – no re-tokenising `UPDATE … SET source_id` of every row in
/// the commit (that held the database lock for seconds at 35k movies with plots). Sources not refreshed since
/// Build 11 stay in the shared `search_index` (v7) until their next refresh; once no source needs it the shared
/// table is emptied (`maintain`).
enum SearchIndex {
    static let shared = "search_index"
    static let columns = "title, people, plot, source_id UNINDEXED, kind UNINDEXED, item_id UNINDEXED"
    static let tokenizer = "tokenize = 'unicode61 remove_diacritics 2'"
    static let rank = "bm25(10.0, 4.0, 1.0)"

    static func key(_ sourceId: String) -> String { "search.fts.\(sourceId)" }

    static func isValidName(_ name: String) -> Bool {
        name.hasPrefix("search_fts_") && name.count == 23 && name.dropFirst(11).allSatisfy { $0.isHexDigit }
    }

    static func string(_ db: SQLiteDatabase, _ key: String) -> String? {
        (try? db.queryFirst("SELECT value FROM kv WHERE key = ?", [.text(key)]) { $0.string(0) }) ?? nil
    }

    /// The source's own index (nil: still in the shared table).
    static func table(_ db: SQLiteDatabase, sourceId: String) -> String? {
        guard db.hasFTS5, let name = string(db, key(sourceId)), isValidName(name) else { return nil }
        return name
    }

    /// Sources with an own index.
    static func owned(_ db: SQLiteDatabase) -> [(sourceId: String, table: String)] {
        let rows = (try? db.query("SELECT key, value FROM kv WHERE key LIKE 'search.fts.%'") {
            (String($0.string(0).dropFirst("search.fts.".count)), $0.string(1))
        }) ?? []
        return rows.filter { isValidName($0.1) }.map { (sourceId: $0.0, table: $0.1) }
    }

    /// A search target: table + extra WHERE filter (+ args).
    struct Target {
        var table: String
        var filter: String
        var args: [SQLiteValue]
    }

    /// Where to search: one source → its own index, else its rows of the shared table; all sources → every
    /// own index + the shared rows of sources without one (staging rows excluded).
    static func targets(_ db: SQLiteDatabase, sourceId: String?) -> [Target] {
        if let sourceId {
            if let table = table(db, sourceId: sourceId) { return [Target(table: table, filter: "", args: [])] }
            return [Target(table: shared, filter: " AND source_id = ?", args: [.text(sourceId)])]
        }
        let owned = owned(db)
        var filter = " AND source_id NOT LIKE '%\(AppDatabase.stagingSuffix)'"
        if !owned.isEmpty { filter += " AND source_id NOT IN (\(CatalogRepository.placeholders(owned.count)))" }
        return [Target(table: shared, filter: filter, args: owned.map { .text($0.sourceId) })]
            + owned.map { Target(table: $0.table, filter: "", args: []) }
    }

    /// The table one item's index row lives in.
    static func tableForWrites(_ db: SQLiteDatabase, sourceId: String) -> String {
        table(db, sourceId: sourceId) ?? shared
    }

    /// Creates an empty index (registered in-flight before it exists, so a concurrent cleanup keeps it).
    static func create(_ db: SQLiteDatabase) throws -> String {
        let name = "search_fts_" + String(format: "%012llx", UInt64.random(in: 0...0xFFFF_FFFF_FFFF))
        IndexTablesInFlight.shared.insert(name)
        // `prefix = '1 2'`: 1–2 letter prefix queries ("k", "ka" while typing) read a prefix index instead of
        // expanding to every term.
        try db.execute("""
            CREATE VIRTUAL TABLE \(name) USING fts5(\(columns), \(tokenizer), prefix = '1 2');
            INSERT INTO \(name) (\(name), rank) VALUES ('rank', '\(rank)');
            """)
        return name
    }

    /// Makes `table` the source's index (inside the commit transaction). Returns the previous one, which the
    /// caller drops after the swap (its DROP need not lengthen the swap; a kill leaves it to `maintain`).
    @discardableResult
    static func register(_ db: SQLiteDatabase, sourceId: String, table: String) throws -> String? {
        let old = string(db, key(sourceId))
        try db.run("INSERT INTO kv (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                   [.text(key(sourceId)), .text(table)])
        IndexTablesInFlight.shared.remove(table)
        return old != table && old.map(isValidName) == true ? old : nil
    }

    static func dropTable(_ db: SQLiteDatabase, _ name: String) throws {
        guard isValidName(name) || EpgSearchIndex.isValidName(name) else { return }
        db.evictStatements(containing: name)
        try db.execute("DROP TABLE IF EXISTS \(name);")
    }

    static func discard(_ db: SQLiteDatabase, table: String) {
        try? dropTable(db, table)
        IndexTablesInFlight.shared.remove(table)
    }

    /// Source content deleted: its own index goes too.
    static func drop(_ db: SQLiteDatabase, sourceId: String) throws {
        guard db.hasFTS5 else { return }
        if let name = string(db, key(sourceId)) { try dropTable(db, name) }
        try db.run("DELETE FROM kv WHERE key = ?", [.text(key(sourceId))])
    }

    /// Launch maintenance (background): drops leftovers of killed refreshes and empties the shared v7 table
    /// once every source in it has its own index and no background copy needs it.
    static func maintain(_ db: SQLiteDatabase) throws {
        guard db.hasFTS5 else { return }
        let referenced = Set(owned(db).map(\.table))
        let tables = try db.query("SELECT name FROM sqlite_master WHERE type = 'table' AND name LIKE 'search\\_fts\\_%' ESCAPE '\\' AND sql LIKE 'CREATE VIRTUAL TABLE%'") { $0.string(0) }
        for name in tables where isValidName(name) && !referenced.contains(name) && !IndexTablesInFlight.shared.contains(name) {
            try dropTable(db, name)
        }
        guard !SearchBackfill.isPending(db) else { return }
        let ownedSources = Set(owned(db).map(\.sourceId))
        let sharedSources = try db.query("SELECT DISTINCT source_id FROM \(shared)") { $0.string(0) }
        guard !sharedSources.isEmpty,
              sharedSources.allSatisfy({ ownedSources.contains($0) || $0.hasSuffix(AppDatabase.stagingSuffix) }) else { return }
        try db.transaction {
            db.evictStatements(containing: shared)
            try db.execute("""
                DROP TABLE \(shared);
                CREATE VIRTUAL TABLE \(shared) USING fts5(\(columns), \(tokenizer));
                INSERT INTO \(shared) (\(shared), rank) VALUES ('rank', '\(rank)');
                """)
        }
    }
}
