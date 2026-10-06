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
    }

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
