import Foundation

/// Test hook run inside a commit's swap transaction (reproduces maintenance racing a commit).
final class CommitTestHook: @unchecked Sendable {
    private let lock = NSLock()
    private var block: (@Sendable () -> Void)?
    func set(_ block: (@Sendable () -> Void)?) { lock.lock(); self.block = block; lock.unlock() }
    func run() { lock.lock(); let b = block; lock.unlock(); b?() }
    static let catalog = CommitTestHook()
    static let epg = CommitTestHook()
}

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

    /// Makes `table` the source's index (inside the commit transaction). The previous one goes to `IndexGarbage`
    /// (emptied in small steps later, never a long DROP in the swap). The caller removes `table` from the in-flight
    /// set only after its transaction committed – until then maintenance must keep it.
    static func register(_ db: SQLiteDatabase, sourceId: String, table: String) throws {
        let old = string(db, key(sourceId))
        try db.run("INSERT INTO kv (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                   [.text(key(sourceId)), .text(table)])
        if let old, old != table, isValidName(old) { try IndexGarbage.add(db, old) }
    }

    static func isIndexName(_ name: String) -> Bool { isValidName(name) || EpgSearchIndex.isValidName(name) }

    /// Immediate DROP (small/empty tables only); statements are evicted before and after (a reader may have
    /// prepared one in between).
    static func dropTable(_ db: SQLiteDatabase, _ name: String) throws {
        guard isIndexName(name) else { return }
        db.evictStatements(containing: name)
        try db.execute("DROP TABLE IF EXISTS \(name);")
        db.evictStatements(containing: name)
    }

    /// A refresh aborted: its partial index is garbage.
    static func discard(_ db: SQLiteDatabase, table: String) {
        try? db.transaction { try IndexGarbage.add(db, table) }
        IndexTablesInFlight.shared.remove(table)
    }

    /// Source content deleted: its own index goes too (to the garbage, emptied in the background).
    static func drop(_ db: SQLiteDatabase, sourceId: String) throws {
        guard db.hasFTS5 else { return }
        if let name = string(db, key(sourceId)), isValidName(name) { try IndexGarbage.add(db, name) }
        try db.run("DELETE FROM kv WHERE key = ?", [.text(key(sourceId))])
    }

    static let sharedEmptyKey = "search.shared.empty"

    /// Launch maintenance (background). Everything is decided **inside one writer transaction**: kv, the schema
    /// and the in-flight set are read on the writer, so a refresh committing right now is either fully before
    /// (its table referenced) or after (its table still in flight) – never seen half (Build 12: maintenance read
    /// the old mapping on the reader and then dropped the freshly committed index). Unreferenced tables go to the
    /// garbage; the shared v7 table is renamed into the garbage once no source needs it.
    static func maintain(_ db: SQLiteDatabase) throws {
        guard db.hasFTS5 else { return }
        try db.transaction {
            let referenced = Set(owned(db).map(\.table)).union(EpgSearchIndex.referenced(db)).union(IndexGarbage.list(db))
            let tables = try db.query("SELECT name FROM sqlite_master WHERE type = 'table' AND (name LIKE 'search\\_fts\\_%' ESCAPE '\\' OR name LIKE 'epg\\_fts\\_%' ESCAPE '\\') AND sql LIKE 'CREATE VIRTUAL TABLE%'") { $0.string(0) }
            for name in tables where isIndexName(name) && !referenced.contains(name) && !IndexTablesInFlight.shared.contains(name) {
                try IndexGarbage.add(db, name)
            }
            guard !SearchBackfill.isPending(db), string(db, sharedEmptyKey) == nil else { return }
            if try db.scalar("SELECT EXISTS (SELECT 1 FROM \(shared))") == 0 {
                try db.run("INSERT OR REPLACE INTO kv (key, value) VALUES (?, '1')", [.text(sharedEmptyKey)])
                return
            }
            let ownedSources = Set(owned(db).map(\.sourceId))
            let sharedSources = try db.query("SELECT DISTINCT source_id FROM \(shared)") { $0.string(0) }
            guard sharedSources.allSatisfy({ ownedSources.contains($0) || $0.hasSuffix(AppDatabase.stagingSuffix) }) else { return }
            let retired = "search_fts_" + String(format: "%012llx", UInt64.random(in: 0...0xFFFF_FFFF_FFFF))
            db.evictStatements(containing: shared)
            try db.execute("""
                ALTER TABLE \(shared) RENAME TO \(retired);
                CREATE VIRTUAL TABLE \(shared) USING fts5(\(columns), \(tokenizer));
                INSERT INTO \(shared) (\(shared), rank) VALUES ('rank', '\(rank)');
                """)
            db.evictStatements(containing: shared)
            try IndexGarbage.add(db, retired)
            try db.run("INSERT OR REPLACE INTO kv (key, value) VALUES (?, '1')", [.text(sharedEmptyKey)])
        }
    }
}

/// Index tables no longer used (replaced by a refresh, aborted, deleted source, retired shared table). Each is
/// dropped in its own transaction after the swap – one DROP (≈ 40 ms for 50k rows) is far cheaper than emptying
/// it first (chunked FTS deletes: 1.6 s of writer time). Listed in kv `index.garbage`, so a kill before the
/// DROP leaves nothing behind. `collectInBackground` runs it without making the caller wait.
enum IndexGarbage {
    static let key = "index.garbage"

    static func list(_ db: SQLiteDatabase) -> [String] {
        ((try? db.queryFirst("SELECT value FROM kv WHERE key = ?", [.text(key)]) { $0.string(0) }) ?? nil)?
            .split(separator: "\n").map(String.init).filter(SearchIndex.isIndexName) ?? []
    }

    static func add(_ db: SQLiteDatabase, _ name: String) throws {
        guard SearchIndex.isIndexName(name) else { return }
        var names = list(db)
        guard !names.contains(name) else { return }
        names.append(name)
        try db.run("INSERT INTO kv (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                   [.text(key), .text(names.joined(separator: "\n"))])
    }

    private static func remove(_ db: SQLiteDatabase, _ name: String) throws {
        let names = list(db).filter { $0 != name }
        if names.isEmpty {
            try db.run("DELETE FROM kv WHERE key = ?", [.text(key)])
        } else {
            try db.run("UPDATE kv SET value = ? WHERE key = ?", [.text(names.joined(separator: "\n")), .text(key)])
        }
    }

    /// Drops every garbage table, one per transaction. Returns false when stopped by `maxTables`.
    @discardableResult
    static func collect(_ db: SQLiteDatabase, maxTables: Int = .max) throws -> Bool {
        var dropped = 0
        for name in list(db) {
            guard dropped < maxTables else { return false }
            try db.transaction {
                guard list(db).contains(name) else { return }   // another collector was faster
                try SearchIndex.dropTable(db, name)
                try remove(db, name)
            }
            dropped += 1
        }
        return true
    }

    /// `collect` on a utility queue (after a commit: the refresh does not wait for the DROP).
    /// Background collections still running (tests wait for them before reopening a database file).
    static let inFlight = DispatchGroup()

    static func collectInBackground(_ db: SQLiteDatabase) {
        DispatchQueue.global(qos: .utility).async(group: inFlight) {
            do { try collect(db) } catch { SafeLog.warning("index garbage failed") }
        }
    }

    /// Waits until every background collection started so far is done (tests).
    @discardableResult
    static func waitForBackground(timeout: TimeInterval = 10) -> Bool {
        inFlight.wait(timeout: .now() + timeout) == .success
    }
}
