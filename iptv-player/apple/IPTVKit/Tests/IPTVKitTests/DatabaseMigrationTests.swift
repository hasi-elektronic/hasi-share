import XCTest
@testable import IPTVKit
import IPTVCore

final class DatabaseMigrationTests: XCTestCase {
    private func tempPath() -> String {
        FileManager.default.temporaryDirectory.appendingPathComponent("migration-\(UUID().uuidString).sqlite").path
    }

    /// A database created by an older build (schema v1: plain `epg_lookup` index, user_version 1) with user
    /// data in it must open, keep its data and gain the v2 EPG index.
    func testSchemaV1DatabaseUpgradesToV2KeepingData() throws {
        let path = tempPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let now = Date()

        // Build a v1 database: current schema, then roll the v2 step back by hand.
        do {
            let db = try AppDatabase(db: SQLiteDatabase(path: path))
            try db.db.execute("""
            DROP INDEX epg_lookup_lc;
            CREATE INDEX epg_lookup ON epg (source_id, channel_epg_id, start);
            """)
            db.db.userVersion = 1
            let epg = EpgRepository(database: db)
            let s = try epg.beginRefresh(sourceId: "s")
            try s.write([EpgProgram(sourceId: "s", channelEpgId: "BBC.One", start: now.addingTimeInterval(-600),
                                    end: now.addingTimeInterval(600), title: "Now"),
                         EpgProgram(sourceId: "s", channelEpgId: "BBC.One", start: now.addingTimeInterval(600),
                                    end: now.addingTimeInterval(1800), title: "Next")])
            try s.commit()
            let catalog = CatalogRepository(database: db)
            let c = try catalog.beginRefresh(sourceId: "s")
            try c.write(channels: [TestData.channel(id: "c1", sourceId: "s", name: "BBC One", epgId: "BBC.One")])
            try c.commit()
            db.setValue("kept", forKey: "k")
            XCTAssertEqual(db.db.userVersion, 1)
        }

        // Reopen with the current code.
        let db = try AppDatabase(db: SQLiteDatabase(path: path))
        XCTAssertEqual(db.db.userVersion, 8)
        XCTAssertEqual(db.value(forKey: "k"), "kept")
        XCTAssertEqual(try CatalogRepository(database: db).channelCount(sourceId: "s"), 1)
        let epg = EpgRepository(database: db)
        XCTAssertEqual(try epg.programCount(sourceId: "s"), 2)
        let nn = try epg.nowNext(sourceId: "s", epgIds: ["bbc.one"], at: now)
        XCTAssertEqual(nn["bbc.one"]?.now?.title, "Now")
        XCTAssertEqual(nn["bbc.one"]?.next?.title, "Next")
        // case-insensitive single-channel lookup still works
        XCTAssertEqual(try epg.programs(sourceId: "s", epgId: "BBC.ONE", in: DateInterval(start: now, duration: 3600)).count, 2)
        let indexes = try db.db.query("SELECT name FROM sqlite_master WHERE type = 'index' AND tbl_name = 'epg'") { $0.string(0) }
        XCTAssertTrue(indexes.contains("epg_lookup_lc"))
        XCTAssertFalse(indexes.contains("epg_lookup"))
        let plan = try db.db.query("EXPLAIN QUERY PLAN SELECT * FROM epg WHERE source_id = ? AND lower(channel_epg_id) = ?",
                                   [.text("s"), .text("x")]) { $0.string(3) }.joined()
        XCTAssertTrue(plan.contains("epg_lookup_lc"), plan)
    }

    func testMigrationIsIdempotent() throws {
        let path = tempPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        _ = try AppDatabase(db: SQLiteDatabase(path: path))
        let again = try AppDatabase(db: SQLiteDatabase(path: path))
        XCTAssertEqual(again.db.userVersion, 8)
    }

    /// A v2 database (no `item_categories`) keeps its category lists: v3 backfills memberships from `category_id`.
    func testSchemaV2DatabaseBackfillsCategoryMemberships() throws {
        let path = tempPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        do {
            let db = try AppDatabase(db: SQLiteDatabase(path: path))
            let catalog = CatalogRepository(database: db)
            let session = try catalog.beginRefresh(sourceId: "s")
            try session.write(channels: [TestData.channel(id: "c1", sourceId: "s", categoryId: "tr", sort: 0),
                                         TestData.channel(id: "c2", sourceId: "s", categoryId: "de", sort: 1)],
                              movies: [Movie(sourceId: "s", id: "m1", name: "Ayla", categoryId: "tr-film")],
                              series: [Series(sourceId: "s", id: "d1", name: "Kuruluş Osman", categoryId: "tr-dizi")])
            try session.commit()
            try db.db.execute("DROP TABLE item_categories")
            db.db.userVersion = 2
        }
        let db = try AppDatabase(db: SQLiteDatabase(path: path))
        XCTAssertEqual(db.db.userVersion, 8)
        let catalog = CatalogRepository(database: db)
        XCTAssertEqual(try catalog.channels(sourceId: "s", categoryId: "tr").map(\.id), ["c1"])
        XCTAssertEqual(try catalog.channelCount(sourceId: "s", categoryId: "de"), 1)
        XCTAssertEqual(try catalog.movies(sourceId: "s", categoryId: "tr-film").map(\.id), ["m1"])
        XCTAssertEqual(try catalog.series(sourceId: "s", categoryId: "tr-dizi").map(\.id), ["d1"])
    }

    /// v5 drops the v1 `*_cat` indexes: category lists read `item_categories` since v3, nothing queries them.
    func testSchemaV4DatabaseDropsUnusedCategoryIndexes() throws {
        let path = tempPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        do {
            let db = try AppDatabase(db: SQLiteDatabase(path: path))
            try db.db.execute("""
            CREATE INDEX IF NOT EXISTS channels_cat ON channels (source_id, category_id, sort);
            CREATE INDEX IF NOT EXISTS movies_cat ON movies (source_id, category_id, sort);
            CREATE INDEX IF NOT EXISTS series_cat ON series (source_id, category_id, sort);
            """)
            let session = try CatalogRepository(database: db).beginRefresh(sourceId: "s")
            try session.write(channels: [TestData.channel(id: "c1", sourceId: "s", categoryId: "tr", sort: 0)])
            try session.commit()
            db.db.userVersion = 4
        }
        let db = try AppDatabase(db: SQLiteDatabase(path: path))
        XCTAssertEqual(db.db.userVersion, 8)
        let indexes = try db.db.query("SELECT name FROM sqlite_master WHERE type = 'index'") { $0.string(0) }
        for name in ["channels_cat", "movies_cat", "series_cat"] { XCTAssertFalse(indexes.contains(name), name) }
        XCTAssertTrue(indexes.contains("item_categories_sort"))
        XCTAssertEqual(try CatalogRepository(database: db).channels(sourceId: "s", categoryId: "tr").map(\.id), ["c1"])
    }
}
