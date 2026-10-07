import Foundation

/// The app database: schema + migrations. Content of every source is replaced atomically on
/// refresh (rows are written under a staging source id and swapped in one transaction), so a
/// half-loaded list is never visible (docs/ARCHITECTURE.md §3.1).
public final class AppDatabase: Sendable {
    public let db: SQLiteDatabase

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
            }
            db.userVersion = 1
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
            }
            db.userVersion = 2
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
            }
            db.userVersion = 3
        }
        if db.userVersion < 4 {
            // TV number zapping looks a channel up by its number across the whole source (SCREENS §3.7).
            try db.transaction {
                try db.execute("CREATE INDEX IF NOT EXISTS channels_number ON channels (source_id, number);")
            }
            db.userVersion = 4
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
            }
            db.userVersion = 5
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
            }
            db.userVersion = 6
        }
    }

    /// True while titles of pre-v6 content are still being re-indexed (search uses the LIKE path meanwhile).
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

/// Background re-indexing of titles after the v6 search index rebuild. Per table: the highest content rowid
/// that existed at migration time (`…max`) and the last rowid indexed (`…at`); rows created later are
/// indexed by their own refresh. Each chunk inserts its index rows and advances the cursor in ONE
/// transaction, so a kill loses nothing and indexes nothing twice.
enum SearchBackfill {
    static let tables: [(table: String, kind: String)] = [("channels", "live"), ("movies", "movie"), ("series", "series")]
    static let pendingKey = "search.backfill.pending"
    static func maxKey(_ table: String) -> String { "search.backfill.\(table).max" }
    static func atKey(_ table: String) -> String { "search.backfill.\(table).at" }

    /// Same indexed form as `CatalogPeople.indexed` (dotless-i variant after U+2063).
    static let indexedTitle = "name || CASE WHEN instr(name, 'ı') > 0 OR instr(name, 'İ') > 0 THEN ' ' || char(8291) || ' ' "
        + "|| replace(replace(name, 'ı', 'i'), 'İ', 'I') ELSE '' END"

    static func setValue(_ db: SQLiteDatabase, _ value: String?, _ key: String) throws {
        if let value {
            try db.run("INSERT INTO kv (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                       [.text(key), .text(value)])
        } else {
            try db.run("DELETE FROM kv WHERE key = ?", [.text(key)])
        }
    }

    static func value(_ db: SQLiteDatabase, _ key: String) -> Int64? {
        (try? db.queryFirst("SELECT value FROM kv WHERE key = ?", [.text(key)]) { $0.string(0) }).flatMap { $0.flatMap { Int64($0) } }
    }

    /// Nothing to do for an empty catalog (new install): the flag is only set when rows exist.
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

    static func isPending(_ db: SQLiteDatabase) -> Bool { value(db, pendingKey) != nil }

    /// Indexes up to `chunkSize` rows per transaction; stops after `maxChunks` (tests simulate a kill).
    /// Returns true when everything is indexed (flag cleared).
    @discardableResult
    static func run(_ db: SQLiteDatabase, chunkSize: Int, maxChunks: Int) throws -> Bool {
        guard db.hasFTS5, isPending(db) else { return true }
        var chunks = 0
        for (table, kind) in tables {
            let max = value(db, maxKey(table)) ?? 0
            while (value(db, atKey(table)) ?? 0) < max {
                guard chunks < maxChunks else { return false }
                chunks += 1
                try db.transaction {
                    let at = value(db, atKey(table)) ?? 0
                    let last = Int64(try db.scalar("""
                        SELECT COALESCE(MAX(rowid), ?) FROM (SELECT rowid FROM \(table) WHERE rowid > ? AND rowid <= ?
                        ORDER BY rowid LIMIT ?)
                        """, [.int(max), .int(at), .int(max), .int(Int64(chunkSize))]))
                    try db.run("""
                        INSERT INTO search_index (title, people, source_id, kind, item_id)
                        SELECT \(indexedTitle), '', source_id, '\(kind)', id FROM \(table)
                        WHERE rowid > ? AND rowid <= ? AND source_id NOT LIKE '%\(AppDatabase.stagingSuffix)'
                        """, [.int(at), .int(last)])
                    try setValue(db, String(last), atKey(table))
                }
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
}
