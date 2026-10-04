import Foundation
import IPTVCore

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
/// (CONTRACT §5); `(source_id, channel_epg_id, start)` index serves now/next and grid queries.
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

    public func programCount(sourceId: String) throws -> Int {
        try db.scalar("SELECT COUNT(*) FROM epg WHERE source_id = ?", [.text(sourceId)])
    }

    private static func program(_ r: SQLiteRow) -> EpgProgram {
        EpgProgram(sourceId: r.string(0), channelEpgId: r.string(1), start: r.date(2), end: r.date(3),
                   title: r.string(4), description: r.optString(5), category: r.optString(6))
    }

    private static let columns = "source_id, channel_epg_id, start, end, title, description, category"

    /// Programmes of one channel overlapping `interval`, ordered by start.
    public func programs(sourceId: String, epgId: String, in interval: DateInterval) throws -> [EpgProgram] {
        try db.query("""
            SELECT \(Self.columns) FROM epg WHERE source_id = ? AND channel_epg_id = ? COLLATE NOCASE
            AND start < ? AND end > ? ORDER BY start
            """, [.text(sourceId), .text(epgId), .from(interval.end), .from(interval.start)], map: Self.program)
    }

    /// Now/next for many channels at once (keyed by lowercased epg id).
    public func nowNext(sourceId: String, epgIds: [String], at date: Date) throws -> [String: NowNext] {
        let ids = Array(Set(epgIds.map { $0.lowercased() }))
        guard !ids.isEmpty else { return [:] }
        var result: [String: NowNext] = [:]
        // Chunk to stay below SQLite's parameter limit.
        for chunk in stride(from: 0, to: ids.count, by: 400).map({ Array(ids[$0..<min($0 + 400, ids.count)]) }) {
            let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ",")
            let rows = try db.query("""
                SELECT \(Self.columns) FROM epg WHERE source_id = ? AND lower(channel_epg_id) IN (\(placeholders))
                AND end > ? AND start < ? ORDER BY start
                """, [.text(sourceId)] + chunk.map(SQLiteValue.text) + [.from(date), .from(date.addingTimeInterval(12 * 3600))],
                map: Self.program)
            let grouped = Dictionary(grouping: rows, by: { $0.channelEpgId.lowercased() })
            for (id, programs) in grouped {
                let pair = EpgSchedule.nowAndNext(programs, at: date)
                result[id] = NowNext(now: pair.now, next: pair.next)
            }
        }
        return result
    }

    public func deleteAll(sourceId: String? = nil) throws {
        if let sourceId {
            try db.run("DELETE FROM epg WHERE source_id = ?", [.text(sourceId)])
        } else {
            try db.run("DELETE FROM epg")
        }
    }
}

/// Atomic EPG replacement (staging rows swapped on commit).
public final class EpgRefreshSession: @unchecked Sendable {
    let db: SQLiteDatabase
    public let sourceId: String
    let stagingId: String
    private var finished = false
    public private(set) var written = 0

    init(db: SQLiteDatabase, sourceId: String) throws {
        self.db = db
        self.sourceId = sourceId
        self.stagingId = sourceId + AppDatabase.stagingSuffix
        try db.run("DELETE FROM epg WHERE source_id = ?", [.text(stagingId)])
    }

    public func write(_ programs: [EpgProgram]) throws {
        let sid = stagingId
        try db.transaction {
            for p in programs {
                try db.run("INSERT INTO epg (source_id, channel_epg_id, start, end, title, description, category) VALUES (?,?,?,?,?,?,?)",
                           [.text(sid), .text(p.channelEpgId), .from(p.start), .from(p.end), .text(p.title),
                            .from(p.description), .from(p.category)])
            }
        }
        written += programs.count
    }

    public func commit() throws {
        guard !finished else { return }
        finished = true
        try db.transaction {
            try db.run("DELETE FROM epg WHERE source_id = ?", [.text(sourceId)])
            try db.run("UPDATE epg SET source_id = ? WHERE source_id = ?", [.text(sourceId), .text(stagingId)])
        }
    }

    public func abort() {
        guard !finished else { return }
        finished = true
        _ = try? db.run("DELETE FROM epg WHERE source_id = ?", [.text(stagingId)])
    }
}
