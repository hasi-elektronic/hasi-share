import Foundation

/// The app database: schema + migrations. Content of every source is replaced atomically on
/// refresh (rows are written under a staging source id and swapped in one transaction), so a
/// half-loaded list is never visible (docs/ARCHITECTURE.md §3.1).
public final class AppDatabase: Sendable {
    public let db: SQLiteDatabase
    /// Main-actor writes that must not wait for a running commit (progress, favorites, recent searches).
    public let deferredWrites = DeferredWrites()

    /// Suffix of the staging source id used while a refresh is running.
    static let stagingSuffix = "~staging"

    public init(db: SQLiteDatabase) throws {
        self.db = db
        try migrate()
    }

    /// In-memory database (tests, previews).
    public static func inMemory() throws -> AppDatabase {
        try AppDatabase(db: SQLiteDatabase(path: nil))
    }

    /// Database in Application Support, excluded from iCloud/device backups (docs/SECURITY.md §1).
    public static func onDisk(fileName: String = "catalog.sqlite") throws -> AppDatabase {
        let fm = FileManager.default
        var dir = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? dir.setResourceValues(values)
        let url = dir.appendingPathComponent(fileName)
        let db = try AppDatabase(db: SQLiteDatabase(path: url.path))
        var fileURL = url
        try? fileURL.setResourceValues(values)
        return db
    }

    private func migrate() throws {
        if db.userVersion < 1 {
            try db.transaction {
                try db.execute("""
                CREATE TABLE IF NOT EXISTS sources (
                  id TEXT PRIMARY KEY, sort INTEGER NOT NULL, json TEXT NOT NULL);
                CREATE TABLE IF NOT EXISTS categories (
                  source_id TEXT NOT NULL, id TEXT NOT NULL, kind TEXT NOT NULL, name TEXT NOT NULL,
                  sort INTEGER NOT NULL, PRIMARY KEY (source_id, kind, id));
                CREATE TABLE IF NOT EXISTS channels (
                  source_id TEXT NOT NULL, id TEXT NOT NULL, name TEXT NOT NULL, number INTEGER,
                  logo_url TEXT, category_id TEXT, epg_id TEXT, catchup_type TEXT NOT NULL DEFAULT 'none',
                  catchup_days INTEGER NOT NULL DEFAULT 0, catchup_source TEXT, url TEXT, user_agent TEXT,
                  referrer TEXT, drm INTEGER NOT NULL DEFAULT 0, sort INTEGER NOT NULL,
                  PRIMARY KEY (source_id, id));
                CREATE INDEX IF NOT EXISTS channels_cat ON channels (source_id, category_id, sort);
                CREATE INDEX IF NOT EXISTS channels_sort ON channels (source_id, sort);
                CREATE TABLE IF NOT EXISTS movies (
                  source_id TEXT NOT NULL, id TEXT NOT NULL, name TEXT NOT NULL, poster_url TEXT,
                  category_id TEXT, rating REAL, year INTEGER, plot TEXT, container_ext TEXT, url TEXT,
                  added_at INTEGER, sort INTEGER NOT NULL, PRIMARY KEY (source_id, id));
                CREATE INDEX IF NOT EXISTS movies_cat ON movies (source_id, category_id, sort);
                CREATE TABLE IF NOT EXISTS series (
                  source_id TEXT NOT NULL, id TEXT NOT NULL, name TEXT NOT NULL, poster_url TEXT,
                  category_id TEXT, plot TEXT, rating REAL, year INTEGER, sort INTEGER NOT NULL,
                  PRIMARY KEY (source_id, id));
                CREATE INDEX IF NOT EXISTS series_cat ON series (source_id, category_id, sort);
                CREATE TABLE IF NOT EXISTS episodes (
                  source_id TEXT NOT NULL, id TEXT NOT NULL, series_id TEXT NOT NULL, season INTEGER NOT NULL,
                  number INTEGER NOT NULL, title TEXT NOT NULL, container_ext TEXT, duration_sec INTEGER,
                  plot TEXT, poster_url TEXT, url TEXT, PRIMARY KEY (source_id, id));
                CREATE INDEX IF NOT EXISTS episodes_series ON episodes (source_id, series_id, season, number);
                CREATE TABLE IF NOT EXISTS epg (
                  source_id TEXT NOT NULL, channel_epg_id TEXT NOT NULL, start INTEGER NOT NULL,
                  end INTEGER NOT NULL, title TEXT NOT NULL, description TEXT, category TEXT);
                CREATE INDEX IF NOT EXISTS epg_lookup ON epg (source_id, channel_epg_id, start);
                CREATE TABLE IF NOT EXISTS library (
                  key TEXT PRIMARY KEY, kind TEXT NOT NULL, content_key TEXT NOT NULL,
                  title TEXT NOT NULL, content_kind TEXT NOT NULL, poster_url TEXT,
                  position_ms INTEGER, duration_ms INTEGER, series_key TEXT,
                  updated_at INTEGER NOT NULL, deleted INTEGER NOT NULL DEFAULT 0);
                CREATE INDEX IF NOT EXISTS library_kind ON library (kind, deleted, updated_at);
                CREATE TABLE IF NOT EXISTS kv (key TEXT PRIMARY KEY, value TEXT NOT NULL);
                """)
                if db.hasFTS5 {
                    try db.execute("""
                    CREATE VIRTUAL TABLE IF NOT EXISTS search_index USING fts5(
                      title, source_id UNINDEXED, kind UNINDEXED, item_id UNINDEXED,
                      tokenize = 'unicode61 remove_diacritics 2');
                    """)
                }
                try db.execute("PRAGMA user_version = 1")   // with the schema change: a kill cannot re-run it
            }
        }
        if db.userVersion < 2 {
            // v1 looked EPG programmes up with `lower(channel_epg_id)` / COLLATE NOCASE, which the plain
            // (source_id, channel_epg_id, start) index cannot serve → every now/next and grid query scanned
            // the whole source's EPG. Index the lowercased id instead (expression index, built over the
            // existing rows; the unused v1 index is dropped to keep EPG writes cheap).
            try db.transaction {
                try db.execute("""
                CREATE INDEX IF NOT EXISTS epg_lookup_lc ON epg (source_id, lower(channel_epg_id), start);
                DROP INDEX IF EXISTS epg_lookup;
                """)
                try db.execute("PRAGMA user_version = 2")   // with the schema change: a kill cannot re-run it
            }
        }
        if db.userVersion < 3 {
            // Xtream panels (XUI.one …) put one item into several categories (`category_ids`); `category_id` is
            // only the first one or null. Category lists therefore read this membership table (one row per item
            // and category, `sort` = the item's list position). v3 backfills it from the v1/v2 `category_id`
            // columns so existing catalogs keep working until their next refresh.
            try db.transaction {
                try db.execute("""
                CREATE TABLE IF NOT EXISTS item_categories (
                  source_id TEXT NOT NULL, kind TEXT NOT NULL, category_id TEXT NOT NULL, item_id TEXT NOT NULL,
                  sort INTEGER NOT NULL, PRIMARY KEY (source_id, kind, category_id, item_id));
                CREATE INDEX IF NOT EXISTS item_categories_sort ON item_categories (source_id, kind, category_id, sort);
                INSERT OR IGNORE INTO item_categories (source_id, kind, category_id, item_id, sort)
                  SELECT source_id, 'live', category_id, id, sort FROM channels WHERE category_id IS NOT NULL;
                INSERT OR IGNORE INTO item_categories (source_id, kind, category_id, item_id, sort)
                  SELECT source_id, 'movie', category_id, id, sort FROM movies WHERE category_id IS NOT NULL;
                INSERT OR IGNORE INTO item_categories (source_id, kind, category_id, item_id, sort)
                  SELECT source_id, 'series', category_id, id, sort FROM series WHERE category_id IS NOT NULL;
                """)
                try db.execute("PRAGMA user_version = 3")   // with the schema change: a kill cannot re-run it
            }
        }
        if db.userVersion < 4 {
            // TV number zapping looks a channel up by its number across the whole source (SCREENS §3.7).
            try db.transaction {
                try db.execute("CREATE INDEX IF NOT EXISTS channels_number ON channels (source_id, number);")
                try db.execute("PRAGMA user_version = 4")   // with the schema change: a kill cannot re-run it
            }
        }
        if db.userVersion < 5 {
            // Category lists read `item_categories` since v3; the v1 `category_id` indexes serve no query any
            // more and only slow down catalog refreshes.
            try db.transaction {
                try db.execute("""
                DROP INDEX IF EXISTS channels_cat;
                DROP INDEX IF EXISTS movies_cat;
                DROP INDEX IF EXISTS series_cat;
                """)
                try db.execute("PRAGMA user_version = 5")   // with the schema change: a kill cannot re-run it
            }
        }
        if db.userVersion < 6 {
            // People search (Build 10): the FTS index gets a second searchable column `people` (cast + director).
            // FTS5 tables cannot be altered → drop and recreate. Re-indexing every title here blocked app launch
            // (≈ 1 s on Apple TV HD at 65k rows), so the migration only records which content rows still need
            // their title indexed (`SearchBackfill`, kv cursors) and `CatalogRepository.backfillSearchIndex()`
            // does it in small transactions in the background – resumable after a kill. Until it is done
            // search uses the LIKE path. `people` is filled by the next catalog refresh (`CatalogFormat` 3) and
            // by detail fetches; `item_people` keeps people known only from details across refreshes.
            try db.transaction {
                try db.execute("""
                CREATE TABLE IF NOT EXISTS item_people (
                  source_id TEXT NOT NULL, kind TEXT NOT NULL, item_id TEXT NOT NULL, people TEXT NOT NULL,
                  PRIMARY KEY (source_id, kind, item_id));
                """)
                if db.hasFTS5 {
                    try db.execute("""
                    DROP TABLE IF EXISTS search_index;
                    CREATE VIRTUAL TABLE search_index USING fts5(
                      title, people, source_id UNINDEXED, kind UNINDEXED, item_id UNINDEXED,
                      tokenize = 'unicode61 remove_diacritics 2');
                    """)
                    try SearchBackfill.schedule(db)
                }
                try db.execute("PRAGMA user_version = 6")   // with the schema change: a kill cannot re-run it
            }
        }
        if db.userVersion < 7 {
            // Professional search (Build 11): the FTS index gets a third column `plot` (description), ranked
            // title ≫ people > plot (bm25 10/4/1, stored as the table's `rank`). FTS5 tables cannot be altered:
            // the v6 index is renamed (`search_index_v6`, instant) and copied into the new table in the
            // background (`SearchBackfill`, kv cursors, resumable) – the v6 people column is not stored
            // anywhere else. Search uses the LIKE path until the copy is done. `item_plot` keeps plots known only
            // from detail fetches across refreshes (like `item_people`). `search_terms` (+ trigram index
            // `search_terms_tri`) is the per-source dictionary of title/person words for "did you mean".
            try db.transaction {
                try db.execute("""
                CREATE TABLE IF NOT EXISTS item_plot (
                  source_id TEXT NOT NULL, kind TEXT NOT NULL, item_id TEXT NOT NULL, plot TEXT NOT NULL,
                  PRIMARY KEY (source_id, kind, item_id));
                CREATE TABLE IF NOT EXISTS search_terms (
                  source_id TEXT NOT NULL, term TEXT NOT NULL, gram TEXT NOT NULL, display TEXT NOT NULL,
                  freq INTEGER NOT NULL);
                CREATE UNIQUE INDEX IF NOT EXISTS search_terms_key ON search_terms (source_id, term);
                """)
                if db.hasTrigram {
                    try db.execute("""
                    CREATE VIRTUAL TABLE IF NOT EXISTS search_terms_tri USING fts5(
                      gram, content = 'search_terms', content_rowid = 'rowid', tokenize = 'trigram');
                    CREATE TRIGGER IF NOT EXISTS search_terms_ai AFTER INSERT ON search_terms BEGIN
                      INSERT INTO search_terms_tri (rowid, gram) VALUES (new.rowid, new.gram); END;
                    CREATE TRIGGER IF NOT EXISTS search_terms_ad AFTER DELETE ON search_terms BEGIN
                      INSERT INTO search_terms_tri (search_terms_tri, rowid, gram) VALUES ('delete', old.rowid, old.gram); END;
                    """)
                }
                // Build 11 set the version after this transaction: a kill in between left a v7 schema at version 6.
                // Then the copy state is intact – re-running would drop the renamed v6 table (and its people).
                let alreadyV7 = try db.scalar("SELECT COUNT(*) FROM pragma_table_info('search_index') WHERE name = 'plot'") > 0
                if db.hasFTS5, !alreadyV7 {
                    try db.execute("DROP TABLE IF EXISTS search_index_v6;")
                    if try db.scalar("SELECT COUNT(*) FROM sqlite_master WHERE name = 'search_index'") > 0 {
                        try db.execute("ALTER TABLE search_index RENAME TO search_index_v6;")
                    }
                    try db.execute("""
                    CREATE VIRTUAL TABLE search_index USING fts5(
                      title, people, plot, source_id UNINDEXED, kind UNINDEXED, item_id UNINDEXED,
                      tokenize = 'unicode61 remove_diacritics 2');
                    INSERT INTO search_index (search_index, rank) VALUES ('rank', 'bm25(10.0, 4.0, 1.0)');
                    """)
                    try SearchBackfill.scheduleCopy(db)
                }
                try db.execute("PRAGMA user_version = 7")   // with the schema change: a kill cannot re-run it
            }
        }
        if db.userVersion < 8 {
            // Library items written late (a local change queued behind a commit) keep the user's action time as
            // `updatedAt` (LWW); a marker makes sync push them even when the push cursor already passed that time.
            try db.transaction {
                try db.execute("""
                CREATE TABLE IF NOT EXISTS library_push (key TEXT PRIMARY KEY);
                PRAGMA user_version = 8;
                """)
            }
        }
    }

    /// True while the search index is still being (re-)built in the background after a v6/v7 migration
    /// (search uses the LIKE path meanwhile).
    public var searchBackfillPending: Bool { SearchBackfill.isPending(db) }

    // MARK: Key/value (small app state such as sync cursor)

    public func value(forKey key: String) -> String? {
        try? db.queryFirst("SELECT value FROM kv WHERE key = ?", [.text(key)]) { $0.string(0) }
    }

    public func setValue(_ value: String?, forKey key: String) {
        if let value {
            _ = try? db.run("INSERT INTO kv (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                            [.text(key), .text(value)])
        } else {
            _ = try? db.run("DELETE FROM kv WHERE key = ?", [.text(key)])
        }
    }
}

/// Background (re-)indexing after search index rebuilds, in small transactions, resumable after a kill:
///
/// 1. **Copy (v7):** rows of the renamed v6 index (`search_index_v6`, title + people) up to the rowid that
///    existed at migration time are copied into the v7 index with the description (`plot` of the content row,
///    else `item_plot`); people learned from details (`item_people`) win. Sources refreshed or deleted while the
///    copy runs are listed in `skipKey` and not copied (their refresh indexed them). Then the v6 table is dropped.
/// 2. **Content (v6):** per content table the highest rowid at migration time (`…max`) and the last rowid
///    indexed (`…at`); rows created later are indexed by their own refresh.
///
/// Each chunk inserts its index rows, adds their words to the term dictionary and advances the cursor in ONE
/// transaction, so a kill loses nothing and indexes nothing twice.
enum SearchBackfill {
    static let tables: [(table: String, kind: String)] = [("channels", "live"), ("movies", "movie"), ("series", "series")]
    static let pendingKey = "search.backfill.pending"
    static func maxKey(_ table: String) -> String { "search.backfill.\(table).max" }
    static func atKey(_ table: String) -> String { "search.backfill.\(table).at" }
    static let copyMaxKey = "search.backfill.copy.max"
    static let copyAtKey = "search.backfill.copy.at"
    /// Sources whose v6 rows must not be copied (refreshed or deleted while the copy is pending), "\n"-joined.
    static let skipKey = "search.backfill.copy.skip"
    /// Descriptions are indexed up to this length (index size; snippets need only the first part).
    static let maxPlot = 1200

    static func setValue(_ db: SQLiteDatabase, _ value: String?, _ key: String) throws {
        if let value {
            try db.run("INSERT INTO kv (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                       [.text(key), .text(value)])
        } else {
            try db.run("DELETE FROM kv WHERE key = ?", [.text(key)])
        }
    }

    static func string(_ db: SQLiteDatabase, _ key: String) -> String? {
        (try? db.queryFirst("SELECT value FROM kv WHERE key = ?", [.text(key)]) { $0.string(0) }) ?? nil
    }

    static func value(_ db: SQLiteDatabase, _ key: String) -> Int64? { string(db, key).flatMap { Int64($0) } }

    /// v6: content rows to index. Nothing to do for an empty catalog (new install): the flag is only set when rows exist.
    static func schedule(_ db: SQLiteDatabase) throws {
        var any = false
        for (table, _) in tables {
            let max = Int64(try db.scalar("SELECT COALESCE(MAX(rowid), 0) FROM \(table)"))
            any = any || max > 0
            try setValue(db, String(max), maxKey(table))
            try setValue(db, "0", atKey(table))
        }
        if any { try setValue(db, "1", pendingKey) }
    }

    /// v7: copy of the renamed v6 index. An empty v6 table is dropped right away.
    static func scheduleCopy(_ db: SQLiteDatabase) throws {
        guard try db.scalar("SELECT COUNT(*) FROM sqlite_master WHERE name = 'search_index_v6'") > 0 else {
            for key in [copyMaxKey, copyAtKey, skipKey] { try setValue(db, nil, key) }
            return
        }
        let max = Int64(try db.scalar("SELECT COALESCE(MAX(rowid), 0) FROM search_index_v6"))
        guard max > 0 else {
            try db.execute("DROP TABLE search_index_v6;")
            for key in [copyMaxKey, copyAtKey, skipKey] { try setValue(db, nil, key) }
            return
        }
        try setValue(db, String(max), copyMaxKey)
        try setValue(db, "0", copyAtKey)
        try setValue(db, nil, skipKey)
        try setValue(db, "1", pendingKey)
    }

    static func isPending(_ db: SQLiteDatabase) -> Bool { value(db, pendingKey) != nil }

    /// A refresh committed / a source deleted: its v6 rows must not be copied any more.
    static func skipSource(_ db: SQLiteDatabase, _ sourceId: String) throws {
        guard value(db, copyMaxKey) != nil else { return }
        var list = Set((string(db, skipKey) ?? "").split(separator: "\n").map(String.init))
        guard list.insert(sourceId).inserted else { return }
        try setValue(db, list.sorted().joined(separator: "\n"), skipKey)
    }

    static func contentTable(_ kind: String) -> String? {
        switch kind {
        case "live": return "channels"
        case "movie": return "movies"
        case "series": return "series"
        default: return nil
        }
    }

    /// Indexes up to `chunkSize` rows per transaction; stops after `maxChunks` (tests simulate a kill).
    /// Returns true when everything is indexed (flag cleared).
    /// `pause`: sleep between chunks so other writers (favorites, refreshes) get the writer lock in between.
    @discardableResult
    static func run(_ db: SQLiteDatabase, chunkSize: Int, maxChunks: Int, pause: TimeInterval = 0) throws -> Bool {
        guard db.hasFTS5, isPending(db) else { return true }
        var chunks = 0
        func breathe() { if pause > 0 { Thread.sleep(forTimeInterval: pause) } }
        if let max = value(db, copyMaxKey) {
            // The renamed v6 table is gone (state of an interrupted Build 11 migration): nothing left to copy.
            let hasV6 = try db.scalar("SELECT COUNT(*) FROM sqlite_master WHERE name = 'search_index_v6'") > 0
            while hasV6, (value(db, copyAtKey) ?? 0) < max {
                guard chunks < maxChunks else { return false }
                chunks += 1
                try db.transaction { try copyChunk(db, max: max, chunkSize: chunkSize) }
                breathe()
            }
            try db.transaction {
                try db.execute("DROP TABLE IF EXISTS search_index_v6;")
                for key in [copyMaxKey, copyAtKey, skipKey] { try setValue(db, nil, key) }
            }
        }
        for (table, kind) in tables {
            guard let max = value(db, maxKey(table)) else { continue }
            while (value(db, atKey(table)) ?? 0) < max {
                guard chunks < maxChunks else { return false }
                chunks += 1
                try db.transaction { try contentChunk(db, table: table, kind: kind, max: max, chunkSize: chunkSize) }
                breathe()
            }
        }
        try db.transaction {
            for (table, _) in tables {
                try setValue(db, nil, maxKey(table))
                try setValue(db, nil, atKey(table))
            }
            try setValue(db, nil, pendingKey)
        }
        return true
    }

    /// Description of an item: the content row's, else one learned from a detail fetch.
    static func plot(_ db: SQLiteDatabase, table: String?, sourceId: String, kind: String, itemId: String) throws -> String {
        if let table, table != "channels",
           let p = try db.queryFirst("SELECT plot FROM \(table) WHERE source_id = ? AND id = ?", [.text(sourceId), .text(itemId)], map: { $0.optString(0) }) ?? nil,
           !p.isEmpty {
            return p
        }
        return try db.queryFirst("SELECT plot FROM item_plot WHERE source_id = ? AND kind = ? AND item_id = ?",
                                 [.text(sourceId), .text(kind), .text(itemId)]) { $0.string(0) } ?? ""
    }

    static func detailPeople(_ db: SQLiteDatabase, sourceId: String, kind: String, itemId: String) throws -> String? {
        try db.queryFirst("SELECT people FROM item_people WHERE source_id = ? AND kind = ? AND item_id = ?",
                          [.text(sourceId), .text(kind), .text(itemId)]) { $0.string(0) }
    }

    private static func copyChunk(_ db: SQLiteDatabase, max: Int64, chunkSize: Int) throws {
        let at = value(db, copyAtKey) ?? 0
        let skip = Set((string(db, skipKey) ?? "").split(separator: "\n").map(String.init))
        let rows = try db.query("""
            SELECT rowid, title, people, source_id, kind, item_id FROM search_index_v6
            WHERE rowid > ? AND rowid <= ? ORDER BY rowid LIMIT ?
            """, [.int(at), .int(max), .int(Int64(chunkSize))]) {
            (rowid: $0.int64(0), title: $0.string(1), people: $0.string(2), sourceId: $0.string(3), kind: $0.string(4), itemId: $0.string(5))
        }
        var terms = SearchTermCounter()
        for r in rows where !skip.contains(r.sourceId) && !r.sourceId.hasSuffix(AppDatabase.stagingSuffix) {
            let people = try detailPeople(db, sourceId: r.sourceId, kind: r.kind, itemId: r.itemId).map(CatalogPeople.indexed) ?? r.people
            let plot = try plot(db, table: contentTable(r.kind), sourceId: r.sourceId, kind: r.kind, itemId: r.itemId)
            try insert(db, title: r.title, people: people, plot: plot, sourceId: r.sourceId, kind: r.kind, itemId: r.itemId, indexed: true)
            terms.add(r.sourceId, CatalogPeople.display(r.title))
            terms.add(r.sourceId, CatalogPeople.display(people))
        }
        try terms.upsert(db)
        try setValue(db, String(rows.last?.rowid ?? max), copyAtKey)
    }

    private static func contentChunk(_ db: SQLiteDatabase, table: String, kind: String, max: Int64, chunkSize: Int) throws {
        let at = value(db, atKey(table)) ?? 0
        let rows = try db.query("""
            SELECT rowid, source_id, id, name FROM \(table) WHERE rowid > ? AND rowid <= ? ORDER BY rowid LIMIT ?
            """, [.int(at), .int(max), .int(Int64(chunkSize))]) { (rowid: $0.int64(0), sourceId: $0.string(1), id: $0.string(2), name: $0.string(3)) }
        var terms = SearchTermCounter()
        for r in rows where !r.sourceId.hasSuffix(AppDatabase.stagingSuffix) {
            let people = try detailPeople(db, sourceId: r.sourceId, kind: kind, itemId: r.id) ?? ""
            let plot = try plot(db, table: table, sourceId: r.sourceId, kind: kind, itemId: r.id)
            try insert(db, title: r.name, people: people, plot: plot, sourceId: r.sourceId, kind: kind, itemId: r.id, indexed: false)
            terms.add(r.sourceId, r.name)
            terms.add(r.sourceId, people)
        }
        try terms.upsert(db)
        try setValue(db, String(rows.last?.rowid ?? max), atKey(table))
    }

    /// One search index row (`indexed`: title/people already carry the dotless-i variant).
    static func insert(_ db: SQLiteDatabase, table: String = SearchIndex.shared, title: String, people: String, plot: String,
                       sourceId: String, kind: String, itemId: String, indexed: Bool) throws {
        try db.run("INSERT INTO \(table) (title, people, plot, source_id, kind, item_id) VALUES (?,?,?,?,?,?)",
                   [.text(indexed ? title : CatalogPeople.indexed(title)), .text(indexed ? people : CatalogPeople.indexed(people)),
                    .text(CatalogPeople.indexedWords(String(plot.prefix(maxPlot)))), .text(sourceId), .text(kind), .text(itemId)])
    }
}

/// The trigram index of the term dictionary (did-you-mean). Created by the v7 migration when the tokenizer is
/// available; `ensure` creates it later (launch maintenance) if it is missing but supported, rebuilt from the
/// dictionary rows.
enum SearchTermsIndex {
    static let fillKey = "search.terms.tri.fill"   // "<max rowid at creation>|<last rowid filled>"

    static func exists(_ db: SQLiteDatabase) -> Bool {
        ((try? db.scalar("SELECT COUNT(*) FROM sqlite_master WHERE name = 'search_terms_tri'")) ?? 0) > 0
    }

    /// Usable: exists and, if it was created after the migration, completely filled.
    static func isReady(_ db: SQLiteDatabase) -> Bool {
        exists(db) && ((try? db.queryFirst("SELECT value FROM kv WHERE key = ?", [.text(fillKey)]) { $0.string(0) }) ?? nil) == nil
    }

    static func createDeleteTrigger(_ db: SQLiteDatabase) throws {
        try db.execute("""
        CREATE TRIGGER IF NOT EXISTS search_terms_ad AFTER DELETE ON search_terms BEGIN
          INSERT INTO search_terms_tri (search_terms_tri, rowid, gram) VALUES ('delete', old.rowid, old.gram); END;
        """)
    }

    /// Creates the index if missing but supported: table + triggers at once (new words are indexed from now on),
    /// the words that already existed then in transactions of `chunkSize` (no single long 'rebuild'). Resumable.
    static func ensure(_ db: SQLiteDatabase, chunkSize: Int = 2000, pause: TimeInterval = 0.01) throws {
        guard db.hasTrigram else { return }
        if !exists(db) {
            try db.transaction {
                let max = try db.scalar("SELECT COALESCE(MAX(rowid), 0) FROM search_terms")
                try db.execute("""
                CREATE VIRTUAL TABLE IF NOT EXISTS search_terms_tri USING fts5(
                  gram, content = 'search_terms', content_rowid = 'rowid', tokenize = 'trigram');
                CREATE TRIGGER IF NOT EXISTS search_terms_ai AFTER INSERT ON search_terms BEGIN
                  INSERT INTO search_terms_tri (rowid, gram) VALUES (new.rowid, new.gram); END;
                """)
                // The delete trigger only after the fill: an FTS5 'delete' of a row never inserted corrupts the index.
                if max > 0 {
                    try db.run("INSERT OR REPLACE INTO kv (key, value) VALUES (?, ?)", [.text(fillKey), .text("\(max)|0")])
                } else {
                    try createDeleteTrigger(db)
                }
            }
        }
        while let state = (try db.queryFirst("SELECT value FROM kv WHERE key = ?", [.text(fillKey)]) { $0.string(0) }) {
            let parts = state.split(separator: "|").compactMap { Int64($0) }
            guard parts.count == 2 else { try db.run("DELETE FROM kv WHERE key = ?", [.text(fillKey)]); break }
            let (max, at) = (parts[0], parts[1])
            try db.transaction {
                let last = try db.queryFirst("SELECT MAX(rowid) FROM (SELECT rowid FROM search_terms WHERE rowid > ? AND rowid <= ? ORDER BY rowid LIMIT ?)",
                                             [.int(at), .int(max), .int(Int64(chunkSize))]) { $0.optInt64(0) } ?? nil
                if let last {
                    try db.run("INSERT INTO search_terms_tri (rowid, gram) SELECT rowid, gram FROM search_terms WHERE rowid > ? AND rowid <= ?",
                               [.int(at), .int(last)])
                    try db.run("UPDATE kv SET value = ? WHERE key = ?", [.text("\(max)|\(last)"), .text(fillKey)])
                } else {
                    try createDeleteTrigger(db)
                    try db.run("DELETE FROM kv WHERE key = ?", [.text(fillKey)])
                }
            }
            if pause > 0 { Thread.sleep(forTimeInterval: pause) }
        }
    }
}

/// Word counts of titles and people per source → `search_terms` (did-you-mean dictionary).
struct SearchTermCounter {
    /// sourceId → term → (display, count)
    private(set) var counts: [String: [String: (display: String, count: Int)]] = [:]

    mutating func add(_ sourceId: String, _ text: String) {
        guard !text.isEmpty else { return }
        for (term, display) in SearchText.terms(text) {
            counts[sourceId, default: [:]][term, default: (display, 0)].count += 1
        }
    }

    /// Adds the counts to the dictionary (backfill / detail fetch).
    func upsert(_ db: SQLiteDatabase) throws {
        for (sourceId, terms) in counts {
            for (term, entry) in terms {
                try db.run("""
                    INSERT INTO search_terms (source_id, term, gram, display, freq) VALUES (?,?,?,?,?)
                    ON CONFLICT (source_id, term) DO UPDATE SET freq = freq + excluded.freq
                    """, [.text(sourceId), .text(term), .text(SearchText.gram(term)), .text(entry.display), .int(Int64(entry.count))])
            }
        }
    }

    /// Makes the dictionary of `sourceId` exactly these counts, touching only the terms that changed (a
    /// refresh usually changes few words, so the trigram index sees little churn). Written in transactions of
    /// `chunkSize` changes (the first fill after the update is ~30k words – one long transaction held the writer).
    func replace(_ db: SQLiteDatabase, sourceId: String, chunkSize: Int = 1500) throws {
        let fresh = counts[sourceId] ?? [:]
        let existing = try db.query("SELECT rowid, term, freq FROM search_terms WHERE source_id = ?", [.text(sourceId)]) {
            (rowid: $0.int64(0), term: $0.string(1), freq: $0.int(2))
        }
        var changes: [(String, [SQLiteValue])] = []
        var known: Set<String> = []
        for row in existing {
            known.insert(row.term)
            if let entry = fresh[row.term] {
                if entry.count != row.freq {
                    changes.append(("UPDATE search_terms SET freq = ? WHERE rowid = ?", [.int(Int64(entry.count)), .int(row.rowid)]))
                }
            } else {
                changes.append(("DELETE FROM search_terms WHERE rowid = ?", [.int(row.rowid)]))
            }
        }
        for (term, entry) in fresh where !known.contains(term) {
            changes.append(("INSERT OR IGNORE INTO search_terms (source_id, term, gram, display, freq) VALUES (?,?,?,?,?)",
                            [.text(sourceId), .text(term), .text(SearchText.gram(term)), .text(entry.display), .int(Int64(entry.count))]))
        }
        for start in stride(from: 0, to: changes.count, by: chunkSize) {
            try db.transaction {
                for (sql, args) in changes[start..<min(start + chunkSize, changes.count)] { try db.run(sql, args) }
            }
        }
    }
}
