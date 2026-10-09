import Foundation
import IPTVCore
import XCTest
@testable import IPTVKit

/// Build 10: search by cast/director ("Hasan" → Hasan Can Kaya's show) and categories in search.
final class PeopleSearchTests: XCTestCase {
    var database: AppDatabase!
    var catalog: CatalogRepository!

    override func setUpWithError() throws {
        database = try AppDatabase.inMemory()
        catalog = CatalogRepository(database: database)
        let session = try catalog.beginRefresh(sourceId: "s")
        try session.write(
            categories: [IPTVCore.Category(sourceId: "s", id: "d", kind: .series, name: "TR | Disney+ Diziler", sort: 0),
                         IPTVCore.Category(sourceId: "s", id: "n", kind: .series, name: "EN | Netflix", sort: 1),
                         IPTVCore.Category(sourceId: "s", id: "d", kind: .movie, name: "Disney Filme", sort: 0),
                         IPTVCore.Category(sourceId: "s", id: "l", kind: .live, name: "DE | Disney Channel", sort: 0)],
            channels: [TestData.channel(id: "c1", sourceId: "s", name: "Disney Channel", categoryId: "l")],
            movies: [Movie(sourceId: "s", id: "m1", name: "Hasan Kaçan Film", categoryId: "d", sort: 0),
                     Movie(sourceId: "s", id: "m2", name: "Inception", categoryId: "d", sort: 1,
                           cast: "Leonardo DiCaprio", director: "Christopher Nolan")],
            series: [Series(sourceId: "s", id: "k", name: "Konuşanlar", categoryId: "d", sort: 0, cast: "Hasan Can Kaya", director: "Ali Yılmaz"),
                     Series(sourceId: "s", id: "x", name: "Stranger Things", categoryId: "n", sort: 1, cast: "Millie Bobby Brown")])
        try session.commit()
    }

    func testTitleHitsFirstThenPeopleWithMatchedPerson() throws {
        let hits = try catalog.search("hasan", sourceId: "s")
        XCTAssertEqual(hits.map(\.itemId), ["m1", "k"], "title match first, then the person match")
        XCTAssertNil(hits[0].matchedPerson)
        XCTAssertEqual(hits[1].matchedPerson, "Hasan Can Kaya")
        XCTAssertEqual(hits[1].kind, .series)

        let full = try catalog.search("hasan can", sourceId: "s")
        XCTAssertEqual(full.filter(\.isPersonMatch).map(\.itemId), ["k"], "every token must match the person")
        XCTAssertEqual(try catalog.search("nolan", sourceId: "s").map(\.matchedPerson), ["Christopher Nolan"], "director")
        XCTAssertEqual(try catalog.search("yilmaz", sourceId: "s").first?.matchedPerson, "Ali Yılmaz", "dotless ı folded")
        XCTAssertEqual(try catalog.search("yılmaz", sourceId: "s").first?.matchedPerson, "Ali Yılmaz")
        XCTAssertTrue(try catalog.search("konusanlar", sourceId: "s").allSatisfy { !$0.isPersonMatch })
        XCTAssertTrue(try catalog.search("hasan kaya inception", sourceId: "s").isEmpty, "all tokens required")
    }

    func testItemWhoseTitleAlsoMatchesIsNotRepeatedAsPerson() throws {
        let session = try catalog.beginRefresh(sourceId: "t")
        try session.write(series: [Series(sourceId: "t", id: "h", name: "Hasan Show", cast: "Hasan Can Kaya")])
        try session.commit()
        let hits = try catalog.search("hasan", sourceId: "t")
        XCTAssertEqual(hits.map(\.itemId), ["h"])
        XCTAssertFalse(hits[0].isPersonMatch)
    }

    func testDetailFetchUpdatesPeopleAndSurvivesRefresh() throws {
        XCTAssertTrue(try catalog.search("cillian", sourceId: "s").isEmpty)
        try catalog.updatePeople(sourceId: "s", kind: .movie, itemId: "m2", cast: "Cillian Murphy, Leonardo DiCaprio", director: "Christopher Nolan")
        XCTAssertEqual(try catalog.search("cillian", sourceId: "s").map(\.itemId), ["m2"], "searchable right away")

        // The next refresh lists the movie without cast (typical get_vod_streams): detail people are kept.
        let session = try catalog.beginRefresh(sourceId: "s")
        try session.write(movies: [Movie(sourceId: "s", id: "m2", name: "Inception", sort: 0)])
        try session.commit()
        XCTAssertEqual(try catalog.search("cillian", sourceId: "s").map(\.matchedPerson), ["Cillian Murphy"])
        try catalog.deleteContent(sourceId: "s")
        XCTAssertEqual(try database.db.scalar("SELECT COUNT(*) FROM item_people WHERE source_id = 's'") as Int, 0)
    }

    /// Review: a detail fetch during a running refresh is not lost at commit; unchanged people are not rewritten.
    func testPeopleLearnedDuringRefreshSurviveCommit() throws {
        let session = try catalog.beginRefresh(sourceId: "s")
        try session.write(movies: [Movie(sourceId: "s", id: "m2", name: "Inception", sort: 0)])
        try catalog.updatePeople(sourceId: "s", kind: .movie, itemId: "m2", cast: "Cillian Murphy", director: nil)
        try session.commit()
        XCTAssertEqual(try catalog.search("cillian", sourceId: "s").map(\.itemId), ["m2"])
        XCTAssertEqual(try searchIndexCount(database, itemId: "m2"), 1, "one index row")
        try catalog.updatePeople(sourceId: "s", kind: .movie, itemId: "m2", cast: "Cillian Murphy", director: nil)   // no-op
        XCTAssertEqual(try catalog.search("cillian", sourceId: "s").map(\.itemId), ["m2"])
    }

    func testCategorySearchAllTokensGroupCodeHiddenAndKinds() throws {
        let disney = try catalog.searchCategories("disney", sourceId: "s")
        XCTAssertEqual(disney.map { "\($0.category.kind.rawValue):\($0.id)" }, ["movie:d", "series:d", "live:l"], "movie, series, live")
        XCTAssertEqual(disney.first(where: { $0.category.kind == .live })?.itemCount, 1)
        XCTAssertEqual(try catalog.searchCategories("tr disney", sourceId: "s").map(\.id), ["d"], "group code searchable")
        XCTAssertEqual(try catalog.searchCategories("DİZİLER", sourceId: "s").map(\.id), ["d"], "folded")
        XCTAssertEqual(try catalog.searchCategories("disney", sourceId: "s", hidden: { $0 == .live ? ["l"] : [] }).count, 2, "hidden left out")
        XCTAssertEqual(try catalog.searchCategories("disney", sourceId: "s", limit: 1).count, 1)
        XCTAssertTrue(try catalog.searchCategories("  ", sourceId: "s").isEmpty)
        // Build 11 review: word-prefix match, ≥ 2 characters, a group code alone does not flood the section.
        XCTAssertEqual(try catalog.searchCategories("dis", sourceId: "s").count, 3, "word prefix")
        XCTAssertTrue(try catalog.searchCategories("isney", sourceId: "s").isEmpty, "no inner substring")
        XCTAssertTrue(try catalog.searchCategories("d", sourceId: "s").isEmpty, "one character")
        XCTAssertTrue(try catalog.searchCategories("tr", sourceId: "s").isEmpty, "group code alone")
        XCTAssertEqual(try catalog.searchCategories("de disney", sourceId: "s").map(\.id), ["l"], "group code next to a name word")
    }

    func testMatchedPersonPicksTheMatchingName() {
        XCTAssertEqual(CatalogPeople.matchedPerson("Ali Yılmaz, Hasan Can Kaya", tokens: ["can", "kaya"]), "Hasan Can Kaya")
        XCTAssertEqual(CatalogPeople.matchedPerson("Hasan Yılmaz, Ali Kaya, Veli Kaya", tokens: ["hasan", "kaya"]), "Hasan Yılmaz, Ali Kaya",
                       "no single person matches all tokens: the matched names, at most two")
        XCTAssertEqual(CatalogPeople.text(cast: " Hasan Can Kaya ", director: ""), "Hasan Can Kaya")
        XCTAssertNil(CatalogPeople.text(cast: nil, director: " "))
    }
}

/// Search index v6 (people column) from a v5 database with data.
final class SearchIndexMigrationTests: XCTestCase {
    func testV5DatabaseGetsPeopleColumnKeepingTitleSearch() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("v6-\(UUID().uuidString).sqlite").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        do {
            let db = try AppDatabase(db: SQLiteDatabase(path: path))
            // Roll back to the v5 schema: title-only index, no item_people.
            try db.db.execute("""
            DROP TABLE search_index;
            DROP TABLE item_people;
            CREATE VIRTUAL TABLE search_index USING fts5(title, source_id UNINDEXED, kind UNINDEXED, item_id UNINDEXED,
              tokenize = 'unicode61 remove_diacritics 2');
            INSERT INTO channels (source_id, id, name, sort) VALUES ('s', 'c1', 'TRT 1 HD', 0);
            INSERT INTO movies (source_id, id, name, sort) VALUES ('s', 'm1', 'Ayla', 0);
            INSERT INTO series (source_id, id, name, sort) VALUES ('s', 'k', 'Konuşanlar', 0);
            INSERT INTO series (source_id, id, name, sort) VALUES ('s', 'kc', 'Kızılcık Şerbeti', 1);
            INSERT INTO search_index (title, source_id, kind, item_id) VALUES ('TRT 1 HD', 's', 'live', 'c1');
            """)
            db.db.userVersion = 5
        }
        let db = try AppDatabase(db: SQLiteDatabase(path: path))
        XCTAssertEqual(db.db.userVersion, 9)
        let catalog = CatalogRepository(database: db)
        // The migration does not index titles itself (launch stays fast): pending → LIKE path meanwhile.
        XCTAssertTrue(db.searchBackfillPending)
        XCTAssertEqual(try searchIndexCount(db), 0)
        XCTAssertEqual(try catalog.search("trt", sourceId: "s").map(\.itemId), ["c1"], "LIKE fallback")
        // Killed after two chunks of one row: resumes where it stopped, nothing indexed twice.
        XCTAssertFalse(try catalog.backfillSearchIndex(chunkSize: 1, maxChunks: 2))
        XCTAssertEqual(try searchIndexCount(db), 2)
        let reopened = CatalogRepository(database: try AppDatabase(db: SQLiteDatabase(path: path)))
        XCTAssertTrue(try reopened.backfillSearchIndex(chunkSize: 1))
        XCTAssertFalse(db.searchBackfillPending)
        XCTAssertEqual(try searchIndexCount(db), 4, "every row once")
        XCTAssertEqual(try catalog.search("trt", sourceId: "s").map(\.itemId), ["c1"])
        XCTAssertEqual(try catalog.search("konusanlar", sourceId: "s").map(\.itemId), ["k"], "titles re-indexed from content tables")
        XCTAssertEqual(try catalog.search("ayla", sourceId: "s").map(\.kind), [.movie])
        XCTAssertEqual(try catalog.search("kizilcik", sourceId: "s").map(\.itemId), ["kc"], "dotless ı searchable as i")
        XCTAssertEqual(try catalog.search("kızılcık", sourceId: "s").first?.title, "Kızılcık Şerbeti", "display part only")
        let columns = try db.db.query("SELECT name FROM pragma_table_info('search_index')") { $0.string(0) }
        XCTAssertEqual(columns, ["title", "people", "plot", "source_id", "kind", "item_id"])
        try catalog.updatePeople(sourceId: "s", kind: .series, itemId: "k", cast: "Hasan Can Kaya", director: nil)
        XCTAssertEqual(try catalog.search("hasan", sourceId: "s").first?.matchedPerson, "Hasan Can Kaya")
        // Idempotent.
        XCTAssertEqual(try AppDatabase(db: SQLiteDatabase(path: path)).db.userVersion, 9)
    }

    /// A refresh committed while the backfill is pending indexes its own rows; the backfill then skips them.
    func testRefreshDuringBackfillIndexesEachRowOnce() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("v6r-\(UUID().uuidString).sqlite").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        do {
            let db = try AppDatabase(db: SQLiteDatabase(path: path))
            try db.db.execute("""
            INSERT INTO movies (source_id, id, name, sort) VALUES ('s', 'm1', 'Ayla', 0), ('t', 'x1', 'Other', 0);
            """)
            db.db.userVersion = 5
        }
        let db = try AppDatabase(db: SQLiteDatabase(path: path))
        XCTAssertTrue(db.searchBackfillPending)
        let catalog = CatalogRepository(database: db)
        let session = try catalog.beginRefresh(sourceId: "s")
        try session.write(movies: [Movie(sourceId: "s", id: "m1", name: "Ayla", sort: 0), Movie(sourceId: "s", id: "m2", name: "Ayla 2", sort: 1)])
        try session.commit()
        XCTAssertTrue(try catalog.backfillSearchIndex())
        XCTAssertEqual(try searchIndexCount(db), 3, "m1, m2 (refresh) + x1 (backfill)")
        XCTAssertEqual(Set(try catalog.search("ayla", sourceId: "s").map(\.itemId)), ["m1", "m2"])
    }
}
