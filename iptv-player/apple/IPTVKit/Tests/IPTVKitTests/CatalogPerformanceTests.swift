import XCTest
@testable import IPTVKit
import IPTVCore

/// Spec budgets at 50 000 channels (list page / FTS search ≤ 100 ms, now/next page ≤ 20 ms).
/// Budgets are for release builds; debug builds get 2× (unoptimised SQLite wrapper + Swift).
final class CatalogPerformanceTests: XCTestCase {
    static let n = 50_000
    static let words = ["Sport", "News", "Kids", "Film"]

    #if DEBUG
    let factor = 2.0
    #else
    let factor = 1.0
    #endif

    func makeCatalog() throws -> (AppDatabase, CatalogRepository) {
        let db = try AppDatabase.inMemory()
        let repo = CatalogRepository(database: db)
        let session = try repo.beginRefresh(sourceId: "s")
        let cats = (0..<50).map { IPTVCore.Category(sourceId: "s", id: "k\($0)", kind: .live, name: "Kategorie \($0)", sort: $0) }
        try session.write(categories: cats, channels: (0..<Self.n).map {
            TestData.channel(id: "c\($0)", sourceId: "s", name: "Kanal \($0) \(Self.words[$0 % 4]) HD",
                             categoryId: "k\($0 % 50)", epgId: "e\($0)", sort: $0)
        })
        try session.commit()
        return (db, repo)
    }

    /// Median wall-clock milliseconds of 5 runs (after one warm-up run).
    func median(_ block: () throws -> Void) rethrows -> Double {
        try block()
        var t: [Double] = []
        for _ in 0..<5 {
            let s = DispatchTime.now()
            try block()
            t.append(Double(DispatchTime.now().uptimeNanoseconds - s.uptimeNanoseconds) / 1e6)
        }
        return t.sorted()[2]
    }

    private func report(_ name: String, _ ms: Double, budget: Double) {
        print("PERF \(name): median \(String(format: "%.2f", ms)) ms (budget \(budget) ms, factor \(factor))")
    }

    func testListPageUnderBudget() throws {
        let (_, repo) = try makeCatalog()
        var page: [Channel] = []
        let ms = try median { page = try repo.channels(sourceId: "s", categoryId: "k7", offset: 0, limit: 100) }
        report("list page (category)", ms, budget: 100)
        XCTAssertEqual(page.count, 100)
        XCTAssertLessThan(ms, 100 * factor, "list page \(ms) ms")
    }

    func testAllChannelsDeepPageUnderBudget() throws {
        let (_, repo) = try makeCatalog()
        let ms = try median { _ = try repo.channels(sourceId: "s", offset: 40_000, limit: 100) }
        report("list page (all, offset 40000)", ms, budget: 100)
        XCTAssertLessThan(ms, 100 * factor, "deep page \(ms) ms")
    }

    func testSearchUnderBudget() throws {
        let (_, repo) = try makeCatalog()
        var hits: [SearchHit] = []
        let ms = try median { hits = try repo.search("sport", sourceId: "s", limit: 60) }
        report("search", ms, budget: 100)
        XCTAssertEqual(hits.count, 60)
        XCTAssertLessThan(ms, 100 * factor, "search \(ms) ms")
    }

    /// Realistic retention window: 10 000 EPG channels x 20 programmes = 200 000 rows. Lookups must be
    /// index-driven (cost independent of the table size), not a scan of the whole source.
    func makeEpg(_ db: AppDatabase, now: Date) throws -> EpgRepository {
        let epg = EpgRepository(database: db)
        let session = try epg.beginRefresh(sourceId: "s")
        for chunk in stride(from: 0, to: 10_000, by: 500) {
            var programs: [EpgProgram] = []
            for c in chunk..<(chunk + 500) {
                for p in 0..<20 {
                    let start = now.addingTimeInterval(Double(p - 8) * 3600 + 1800)
                    programs.append(EpgProgram(sourceId: "s", channelEpgId: "e\(c)", start: start,
                                               end: start.addingTimeInterval(3600), title: "P\(c)-\(p)"))
                }
            }
            try session.write(programs)
        }
        try session.commit()
        return epg
    }

    func testNowNextUnderBudget() throws {
        let (db, repo) = try makeCatalog()
        let now = Date()
        let epg = try makeEpg(db, now: now)
        let page = try repo.channels(sourceId: "s", categoryId: nil, offset: 0, limit: 100)
        let ids = page.compactMap(\.epgId)
        XCTAssertEqual(ids.count, 100)
        var map: [String: NowNext] = [:]
        let ms = try median { map = try epg.nowNext(sourceId: "s", epgIds: ids, at: now) }
        report("now/next (100 channels)", ms, budget: 20)
        XCTAssertEqual(map.count, 100)
        XCTAssertNotNil(map["e0"]?.now)
        XCTAssertNotNil(map["e0"]?.next)
        XCTAssertLessThan(ms, 20 * factor, "now/next \(ms) ms")
    }

    /// EPG grid load (`EpgGridViewModel.load`): 200 channels x a 6 h window, one query per channel.
    /// (Budget 100 ms is this task's choice — the spec only budgets now/next and 60 fps scrolling.)
    func testEpgGridLoadUnderBudget() throws {
        let (db, repo) = try makeCatalog()
        let now = Date()
        let epg = try makeEpg(db, now: now)
        let ids = try repo.channels(sourceId: "s", categoryId: nil, offset: 0, limit: 200).compactMap(\.epgId)
        let window = DateInterval(start: now.addingTimeInterval(-1800), duration: 6 * 3600)
        var rows = 0
        let ms = try median { rows = try ids.map { try epg.programs(sourceId: "s", epgId: $0, in: window).count }.reduce(0, +) }
        report("epg grid (200 channels x 6 h)", ms, budget: 100)
        XCTAssertEqual(rows, 200 * 6)
        XCTAssertLessThan(ms, 100 * factor, "epg grid \(ms) ms")
    }

    /// The EPG lookups must be served by an index on (source_id, channel_epg_id, start) — deterministic
    /// guard that does not depend on machine speed.
    func testEpgQueriesUseChannelIndex() throws {
        let db = try AppDatabase.inMemory()
        for sql in ["SELECT * FROM epg WHERE source_id = ? AND lower(channel_epg_id) IN (?,?) AND end > ? AND start < ? ORDER BY start",
                    "SELECT * FROM epg WHERE source_id = ? AND lower(channel_epg_id) = ? AND start < ? AND end > ? ORDER BY start"] {
            let args = Array(repeating: SQLiteValue.text("x"), count: sql.filter { $0 == "?" }.count)
            let plan = try db.db.query("EXPLAIN QUERY PLAN " + sql, args) { $0.string(3) }.joined(separator: " | ")
            // SQLite prints the expression column as `<expr>`; a bare `(source_id=?)` means a source-wide scan.
            XCTAssertTrue(plan.contains("epg_lookup_lc (source_id=? AND <expr>=?"), "plan scans the whole source: \(plan)")
        }
    }
}
