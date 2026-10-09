import Foundation
import IPTVCore

/// A programme search result with its row id (stable identity even for duplicate XMLTV entries).
public struct EpgProgramMatch: Sendable, Hashable {
    public var rowid: Int64
    public var program: EpgProgram
}

/// Now/next programmes of a channel.
public struct NowNext: Sendable, Hashable {
    public var now: EpgProgram?
    public var next: EpgProgram?
    public init(now: EpgProgram?, next: EpgProgram?) {
        self.now = now
        self.next = next
    }
}

/// EPG storage: only the retention window and only channels of the source are written
/// (CONTRACT §5); the `(source_id, lower(channel_epg_id), start)` index (migration v2) serves now/next and grid queries.
public final class EpgRepository: Sendable {
    private let database: AppDatabase
    private var db: SQLiteDatabase { database.db }

    public init(database: AppDatabase) {
        self.database = database
    }

    /// Begins an atomic EPG replacement for a source.
    public func beginRefresh(sourceId: String) throws -> EpgRefreshSession {
        try EpgRefreshSession(db: db, sourceId: sourceId)
    }

    /// End of the last stored programme of a source (nil without EPG).
    public func latestEnd(sourceId: String) throws -> Date? {
        try db.queryFirst("SELECT MAX(end) FROM epg WHERE source_id = ?", [.text(sourceId)]) { $0.optDate(0) } ?? nil
    }

    public func programCount(sourceId: String) throws -> Int {
        try db.scalar("SELECT COUNT(*) FROM epg WHERE source_id = ?", [.text(sourceId)])
    }

    private static func program(_ r: SQLiteRow) -> EpgProgram {
        EpgProgram(sourceId: r.string(0), channelEpgId: r.string(1), start: r.date(2), end: r.date(3),
                   title: r.string(4), description: r.optString(5), category: r.optString(6))
    }

    private static let columns = "source_id, channel_epg_id, start, end, title, description, category"

    /// Single-channel lookup. Both sides go through SQLite's `lower()` (ASCII-only folding) so the
    /// expression index `epg_lookup_lc` serves it and ids with non-ASCII capitals ("ÖRF.at") still match.
    static let programsSQL = """
        SELECT \(columns) FROM epg WHERE source_id = ? AND lower(channel_epg_id) = lower(?)
        AND start < ? AND end > ? ORDER BY start
        """

    static func nowNextSQL(idCount: Int) -> String {
        let placeholders = Array(repeating: "lower(?)", count: idCount).joined(separator: ",")
        return """
            SELECT \(columns) FROM epg WHERE source_id = ? AND lower(channel_epg_id) IN (\(placeholders))
            AND end > ? AND start < ? ORDER BY start
            """
    }

    /// SQLite `lower()` semantics (A-Z only), used to match rows back to the ids that were asked for.
    static func sqliteLower(_ s: String) -> String {
        String(String.UnicodeScalarView(s.unicodeScalars.map { ("A"..."Z").contains($0) ? Unicode.Scalar($0.value + 32)! : $0 }))
    }

    /// Programmes of one channel overlapping `interval`, ordered by start.
    public func programs(sourceId: String, epgId: String, in interval: DateInterval) throws -> [EpgProgram] {
        try db.query(Self.programsSQL, [.text(sourceId), .text(epgId), .from(interval.end), .from(interval.start)],
                     map: Self.program)
    }

    /// Now/next for many channels at once (keyed by the Unicode-lowercased epg id).
    public func nowNext(sourceId: String, epgIds: [String], at date: Date) throws -> [String: NowNext] {
        let ids = Array(Set(epgIds))
        guard !ids.isEmpty else { return [:] }
        var result: [String: NowNext] = [:]
        // Chunk to stay below SQLite's parameter limit.
        for chunk in stride(from: 0, to: ids.count, by: 400).map({ Array(ids[$0..<min($0 + 400, ids.count)]) }) {
            let rows = try db.query(Self.nowNextSQL(idCount: chunk.count),
                                    [.text(sourceId)] + chunk.map(SQLiteValue.text) + [.from(date), .from(date.addingTimeInterval(12 * 3600))],
                                    map: Self.program)
            let grouped = Dictionary(grouping: rows, by: { Self.sqliteLower($0.channelEpgId) })
            for id in chunk {
                guard let programs = grouped[Self.sqliteLower(id)] else { continue }
                let pair = EpgSchedule.nowAndNext(programs, at: date)
                result[id.lowercased()] = NowNext(now: pair.now, next: pair.next)
            }
        }
        return result
    }

    public func deleteAll(sourceId: String? = nil) throws {
        try db.transaction {
            if let sourceId {
                try db.run("DELETE FROM epg WHERE source_id = ?", [.text(sourceId)])
                try EpgSearchIndex.drop(db, sourceId: sourceId)
            } else {
                let tables = EpgSearchIndex.referenced(db)
                try db.run("DELETE FROM epg")
                try db.run("DELETE FROM kv WHERE key LIKE 'epg.fts.%'")
                for table in tables where EpgSearchIndex.isValidName(table) { try IndexGarbage.add(db, table) }
            }
        }
    }

    // MARK: Programme search (SCREENS §3.6 "On TV")

    /// Programmes of `sourceId` whose title contains every token (word prefix, case/diacritics folded, ı = i)
    /// and that overlap `[from, to)`: running ones first, then upcoming by start, then ended ones (newest first).
    /// Served by the source's programme title index (`EpgSearchIndex`); empty until the source has one.
    public func searchProgrammes(_ text: String, sourceId: String, now: Date, from: Date, to: Date,
                                 offset: Int = 0, limit: Int = 60) throws -> [EpgProgramMatch] {
        do {
            return try searchProgrammesOnce(text, sourceId: sourceId, now: now, from: from, to: to, offset: offset, limit: limit)
        } catch let error as SQLiteError where error.message.contains("no such table") {
            // The index was swapped between reading its name and the query: once more with the new one.
            return try searchProgrammesOnce(text, sourceId: sourceId, now: now, from: from, to: to, offset: offset, limit: limit)
        }
    }

    private func searchProgrammesOnce(_ text: String, sourceId: String, now: Date, from: Date, to: Date,
                                      offset: Int, limit: Int) throws -> [EpgProgramMatch] {
        let tokens = SearchText.tokens(text)
        guard !tokens.isEmpty, limit > 0, let table = EpgSearchIndex.table(db, sourceId: sourceId) else { return [] }
        let nowMs = SQLiteValue.from(now)
        let sql = """
            SELECT e.source_id, e.channel_epg_id, e.start, e.end, e.title, e.description, e.category, e.rowid
            FROM \(table) f JOIN epg e ON e.rowid = f.rowid
            WHERE \(table) MATCH ? AND e.source_id = ? AND e.end > ? AND e.start < ?
            ORDER BY CASE WHEN e.start <= ? AND e.end > ? THEN 0 WHEN e.start > ? THEN 1 ELSE 2 END,
                     CASE WHEN e.end <= ? THEN -e.start ELSE e.start END, e.channel_epg_id
            LIMIT ? OFFSET ?
            """
        return try db.query(sql, [.text(CatalogRepository.ftsExpression(tokens)), .text(sourceId), .from(from), .from(to),
                                  nowMs, nowMs, nowMs, nowMs, .int(Int64(limit)), .int(Int64(offset))]) {
            EpgProgramMatch(rowid: $0.int64(7), program: Self.program($0))
        }
    }

    /// Builds missing programme title indexes (EPG stored before Build 11) in chunks and drops leftovers of
    /// killed refreshes. Call off the main thread; resumable. Returns true when every source with EPG has one.
    /// Empties and drops replaced programme indexes in small steps (after an EPG refresh; off the main thread).
    public func collectIndexGarbage() throws {
        try IndexGarbage.collect(db)
    }

    /// `collectIndexGarbage` without waiting (after an EPG refresh).
    public func collectIndexGarbageInBackground() {
        IndexGarbage.collectInBackground(db)
    }

    @discardableResult
    public func maintainSearchIndex(chunkSize: Int = 2000, maxChunks: Int = .max, pause: TimeInterval = 0.015) throws -> Bool {
        try EpgSearchIndex.backfill(db, chunkSize: chunkSize, maxChunks: maxChunks, pause: pause)
    }
}

/// Per-source FTS5 index of programme titles (`epg_fts_<random>`, its name in kv `epg.fts.<sourceId>`, rowid =
/// `epg.rowid`). Each EPG refresh builds a new one next to its staging rows and swaps it in on commit; the old
/// table is dropped as a whole – no per-row FTS deletes of ~500k programmes. Titles get the dotless-i variant
/// (`CatalogPeople.indexed`). `detail=none`: prefix/AND queries only, about half the index size.
enum EpgSearchIndex {
    static func key(_ sourceId: String) -> String { "epg.fts.\(sourceId)" }
    static func backfillKey(_ sourceId: String) -> String { "epg.fts.backfill.\(sourceId)" }

    /// Same indexed form as `CatalogPeople.indexed`, in SQL.
    static let indexedTitle = "title || CASE WHEN instr(title, 'ı') > 0 OR instr(title, 'İ') > 0 THEN ' ' || char(8291) || ' ' "
        + "|| replace(replace(title, 'ı', 'i'), 'İ', 'I') ELSE '' END"

    static var inFlight: IndexTablesInFlight { IndexTablesInFlight.shared }

    static func isValidName(_ name: String) -> Bool {
        name.hasPrefix("epg_fts_") && name.count == 20 && name.dropFirst(8).allSatisfy { $0.isHexDigit }
    }

    static func string(_ db: SQLiteDatabase, _ key: String) -> String? {
        (try? db.queryFirst("SELECT value FROM kv WHERE key = ?", [.text(key)]) { $0.string(0) }) ?? nil
    }

    /// The live index of a source (nil: none yet).
    static func table(_ db: SQLiteDatabase, sourceId: String) -> String? {
        guard db.hasFTS5, let name = string(db, key(sourceId)), isValidName(name) else { return nil }
        return name
    }

    /// Creates an empty index (registered in-flight before it exists, so a concurrent cleanup keeps it).
    static func create(_ db: SQLiteDatabase) throws -> String {
        let name = "epg_fts_" + String(format: "%012llx", UInt64.random(in: 0...0xFFFF_FFFF_FFFF))
        inFlight.insert(name)
        try db.execute("CREATE VIRTUAL TABLE \(name) USING fts5(title, tokenize = 'unicode61 remove_diacritics 2', detail = none);")
        return name
    }

    /// Indexes the programmes inserted after `rowid` for `sourceId` (staging id while refreshing).
    static func add(_ db: SQLiteDatabase, table: String, sourceId: String, after rowid: Int64) throws {
        try db.run("INSERT INTO \(table) (rowid, title) SELECT rowid, \(indexedTitle) FROM epg WHERE rowid > ? AND source_id = ?",
                   [.int(rowid), .text(sourceId)])
    }

    /// Makes `table` the live index of the source (inside the commit transaction); the previous one goes to
    /// `IndexGarbage`. The session removes `table` from the in-flight set after its transaction.
    static func register(_ db: SQLiteDatabase, sourceId: String, table: String) throws {
        let old = string(db, key(sourceId))
        try db.run("INSERT INTO kv (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                   [.text(key(sourceId)), .text(table)])
        if let old, old != table, isValidName(old) { try IndexGarbage.add(db, old) }
    }

    static func discard(_ db: SQLiteDatabase, table: String) {
        if isValidName(table) { try? db.transaction { try IndexGarbage.add(db, table) } }
        inFlight.remove(table)
    }

    /// Source content deleted: its index goes too (garbage, emptied in the background).
    static func drop(_ db: SQLiteDatabase, sourceId: String) throws {
        guard db.hasFTS5 else { return }
        for k in [key(sourceId), backfillKey(sourceId)] {
            if let value = string(db, k), let name = value.split(separator: "|").first.map(String.init), isValidName(name) {
                try IndexGarbage.add(db, name)
            }
            try db.run("DELETE FROM kv WHERE key = ?", [.text(k)])
        }
    }

    /// Index tables referenced by kv (live + backfills in progress).
    static func referenced(_ db: SQLiteDatabase) -> Set<String> {
        Set(((try? db.query("SELECT value FROM kv WHERE key LIKE 'epg.fts.%'") { $0.string(0) }) ?? [])
            .compactMap { $0.split(separator: "|").first.map(String.init) })
    }

    /// Indexes stored EPG of sources without an index, `chunkSize` programmes per transaction. A refresh that
    /// registers its own index meanwhile wins (the partial one is dropped). Progress in kv `epg.fts.backfill.<id>`
    /// ("table|last rowid").
    static func backfill(_ db: SQLiteDatabase, chunkSize: Int, maxChunks: Int, pause: TimeInterval = 0) throws -> Bool {
        guard db.hasFTS5 else { return true }
        try SearchIndex.maintain(db)   // leftovers of killed refreshes → garbage (decided on the writer)
        try IndexGarbage.collect(db)
        var chunks = 0
        let sources = try db.query("SELECT id FROM sources ORDER BY sort") { $0.string(0) }
        for sourceId in sources where table(db, sourceId: sourceId) == nil {
            var state = string(db, backfillKey(sourceId)).map { $0.split(separator: "|").map(String.init) }
            if state == nil {
                guard try db.scalar("SELECT EXISTS (SELECT 1 FROM epg WHERE source_id = ?)", [.text(sourceId)]) != 0 else { continue }
                let name = try create(db)
                try db.run("INSERT OR REPLACE INTO kv (key, value) VALUES (?, ?)", [.text(backfillKey(sourceId)), .text("\(name)|0")])
                state = [name, "0"]
            }
            guard let state, state.count == 2, isValidName(state[0]), var at = Int64(state[1]) else {
                try db.run("DELETE FROM kv WHERE key = ?", [.text(backfillKey(sourceId))])
                continue
            }
            let name = state[0]
            inFlight.insert(name)
            defer { inFlight.remove(name) }
            var done = false
            while !done {
                guard chunks < maxChunks else { return false }
                chunks += 1
                try db.transaction {
                    if table(db, sourceId: sourceId) != nil {   // a refresh registered its own index meanwhile
                        try IndexGarbage.add(db, name)
                        try db.run("DELETE FROM kv WHERE key = ?", [.text(backfillKey(sourceId))])
                        done = true
                        return
                    }
                    let last = try db.queryFirst("""
                        SELECT MAX(rowid) FROM (SELECT rowid FROM epg WHERE source_id = ? AND rowid > ? ORDER BY rowid LIMIT ?)
                        """, [.text(sourceId), .int(at), .int(Int64(chunkSize))]) { $0.optInt64(0) } ?? nil
                    if let last {
                        try db.run("INSERT INTO \(name) (rowid, title) SELECT rowid, \(indexedTitle) FROM epg WHERE source_id = ? AND rowid > ? AND rowid <= ?",
                                   [.text(sourceId), .int(at), .int(last)])
                        at = last
                        try db.run("UPDATE kv SET value = ? WHERE key = ?", [.text("\(name)|\(last)"), .text(backfillKey(sourceId))])
                    } else {
                        try db.run("INSERT OR REPLACE INTO kv (key, value) VALUES (?, ?)", [.text(key(sourceId)), .text(name)])
                        try db.run("DELETE FROM kv WHERE key = ?", [.text(backfillKey(sourceId))])
                        done = true
                    }
                }
                if pause > 0, !done { Thread.sleep(forTimeInterval: pause) }
            }
        }
        return true
    }
}

/// Atomic EPG replacement (staging rows swapped on commit).
public final class EpgRefreshSession: @unchecked Sendable {
    let db: SQLiteDatabase
    public let sourceId: String
    let stagingId: String
    private var finished = false
    public private(set) var written = 0
    /// Programme title index built alongside the staging rows (`EpgSearchIndex`), swapped in on commit.
    let searchTable: String?

    init(db: SQLiteDatabase, sourceId: String) throws {
        self.db = db
        self.sourceId = sourceId
        self.stagingId = sourceId + AppDatabase.stagingSuffix
        try db.run("DELETE FROM epg WHERE source_id = ?", [.text(stagingId)])
        searchTable = db.hasFTS5 ? try EpgSearchIndex.create(db) : nil
    }

    public func write(_ programs: [EpgProgram]) throws {
        let sid = stagingId
        try db.transaction {
            let before = Int64(try db.scalar("SELECT COALESCE(MAX(rowid), 0) FROM epg"))
            for p in programs {
                try db.run("INSERT INTO epg (source_id, channel_epg_id, start, end, title, description, category) VALUES (?,?,?,?,?,?,?)",
                           [.text(sid), .text(p.channelEpgId), .from(p.start), .from(p.end), .text(p.title),
                            .from(p.description), .from(p.category)])
            }
            if let searchTable { try EpgSearchIndex.add(db, table: searchTable, sourceId: sid, after: before) }
        }
        written += programs.count
    }

    public func commit() throws {
        guard !finished else { return }
        try db.transaction {
            try db.run("DELETE FROM epg WHERE source_id = ?", [.text(sourceId)])
            try db.run("UPDATE epg SET source_id = ? WHERE source_id = ?", [.text(sourceId), .text(stagingId)])
            if let searchTable {
                try EpgSearchIndex.register(db, sourceId: sourceId, table: searchTable)
                CommitTestHook.epg.run()
                try db.run("DELETE FROM kv WHERE key = ?", [.text(EpgSearchIndex.backfillKey(sourceId))])
            }
        }
        finished = true   // only after success: a failed commit can still be aborted (cleanup)
        if let searchTable { EpgSearchIndex.inFlight.remove(searchTable) }
    }

    /// Discards the staged rows and the new index. Also after `commit()` when an **outer** transaction
    /// (SourceRefresher: commit + channel epg ids) rolled the swap back – the staging rows are back then, or the
    /// source's index is not this session's.
    public func abort() {
        if finished, !swapRolledBack() { return }
        finished = true
        _ = try? db.run("DELETE FROM epg WHERE source_id = ?", [.text(stagingId)])
        if let searchTable { EpgSearchIndex.discard(db, table: searchTable) }
    }

    private func swapRolledBack() -> Bool {
        let staged = ((try? db.scalar("SELECT EXISTS (SELECT 1 FROM epg WHERE source_id = ?)", [.text(stagingId)])) ?? 0) != 0
        if staged { return true }
        guard let searchTable else { return false }
        return EpgSearchIndex.table(db, sourceId: sourceId) != searchTable
    }
}
