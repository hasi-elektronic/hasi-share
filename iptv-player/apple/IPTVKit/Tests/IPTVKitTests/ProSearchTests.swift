import Foundation
import IPTVCore
import XCTest
@testable import IPTVKit

/// Build 11 "professional search": descriptions, ranking, snippets, did-you-mean, TV programmes, filters,
/// recent searches, suggestions (SCREENS §3.6, ARCHITECTURE §3.1 search index v7).
final class ProSearchTests: XCTestCase {
    var database: AppDatabase!
    var catalog: CatalogRepository!

    override func setUpWithError() throws {
        database = try AppDatabase.inMemory()
        catalog = CatalogRepository(database: database)
        let session = try catalog.beginRefresh(sourceId: "s")
        try session.write(
            movies: [Movie(sourceId: "s", id: "m1", name: "Hasan Kaçan Film", sort: 0),
                     Movie(sourceId: "s", id: "m2", name: "Gece Yarısı", plot: "Konuk: Hasan Can Kaya ile bir gece.", sort: 1),
                     Movie(sourceId: "s", id: "m3", name: "Dağınık", plot: "Kaya üstünde Hasan ve arkadaşı Can bekler.", sort: 2),
                     Movie(sourceId: "s", id: "m4", name: "Sessiz", sort: 3)],
            series: [Series(sourceId: "s", id: "k", name: "Konuşanlar", sort: 0, cast: "Hasan Can Kaya", director: "Murat Yılmaz"),
                     Series(sourceId: "s", id: "y", name: "Yalı Çapkını",
                            plot: "Gaziantepli zengin ailenin oğlu Ferit ile Seyran'ın zorla evliliği; Kızılcık Şerbeti ekibinden.", sort: 1)])
        try session.commit()
    }

    // MARK: Descriptions, ranking, snippets

    func testDescriptionOnlyMatchWithSnippetAfterTitleAndPeople() throws {
        let hits = try catalog.search("hasan", sourceId: "s")
        XCTAssertEqual(hits.map(\.match), [.title, .person, .description, .description])
        XCTAssertEqual(hits.map(\.itemId).prefix(2), ["m1", "k"])
        XCTAssertEqual(Set(hits.suffix(2).map(\.itemId)), ["m2", "m3"])
        let snippet = try XCTUnwrap(hits.first { $0.itemId == "m2" }?.snippet)
        XCTAssertEqual(snippet.matchedWords, ["Hasan"])
        XCTAssertTrue(snippet.text.contains("Hasan Can Kaya"))
    }

    func testExactPhraseRanksAboveScatteredWords() throws {
        let hits = try catalog.search("hasan can kaya", scope: .descriptions, sourceId: "s")
        XCTAssertEqual(hits.map(\.itemId), ["m2", "m3"], "phrase in m2, scattered words in m3")
        XCTAssertEqual(hits[0].snippet?.matchedWords, ["Hasan", "Can", "Kaya"])
        // Filter chip list of a kind: title ≫ people > description.
        let all = try catalog.search("hasan", scope: .kind(.movie), sourceId: "s")
        XCTAssertEqual(all.first?.itemId, "m1")
        XCTAssertEqual(all.first?.match, .title)
        XCTAssertEqual(all.dropFirst().map(\.match), [.description, .description])
        let series = try catalog.search("hasan", scope: .kind(.series), sourceId: "s")
        XCTAssertEqual(series.map(\.itemId), ["k"])
        XCTAssertEqual(series.first?.matchedPerson, "Hasan Can Kaya")
    }

    func testTurkishFoldingInDescriptionsAndSnippets() throws {
        let hits = try catalog.search("kizilcik serbeti", scope: .descriptions, sourceId: "s")
        XCTAssertEqual(hits.map(\.itemId), ["y"], "ı/ş folded in the description")
        XCTAssertEqual(hits.first?.snippet?.matchedWords, ["Kızılcık", "Şerbeti"])
        XCTAssertEqual(try catalog.search("seyran", sourceId: "s").map(\.itemId), ["y"])
        XCTAssertEqual(try catalog.search("SEYRAN'IN", sourceId: "s").first?.match, .description)
    }

    func testSnippetWindowAndEllipsis() {
        let text = String(repeating: "Lorem ipsum dolor sit amet. ", count: 10) + "Burada Hasan Can Kaya konuşuyor. " + String(repeating: "Son söz. ", count: 20)
        let snippet = SearchText.snippet(text, tokens: ["hasan", "kaya"], maxLength: 80)
        XCTAssertEqual(snippet.parts.first?.text, "…")
        XCTAssertEqual(snippet.parts.last?.text, "…")
        XCTAssertEqual(snippet.matchedWords, ["Hasan", "Kaya"])
        XCTAssertLessThanOrEqual(snippet.text.count, 84)
        XCTAssertFalse(snippet.text.contains("\u{2063}"))
        let short = SearchText.snippet("İstanbul'da bir gün", tokens: ["istanbul"])
        XCTAssertEqual(short.matchedWords, ["İstanbul"], "dotted İ folded")
        XCTAssertNotEqual(short.parts.first?.text, "…")
    }

    func testDetailPlotSearchableKeptAcrossRefreshAndListPlotWins() throws {
        XCTAssertTrue(try catalog.search("cillian", sourceId: "s").isEmpty)
        try catalog.updateDetails(sourceId: "s", kind: .movie, itemId: "m4", cast: nil, director: nil, plot: "Cillian bir deniz fenerinde.")
        XCTAssertEqual(try catalog.search("fenerinde", sourceId: "s").map(\.itemId), ["m4"], "searchable at once")
        XCTAssertEqual(try catalog.movie(sourceId: "s", id: "m4")?.plot, "Cillian bir deniz fenerinde.", "stored on the row")
        // A list plot is not replaced by the detail plot.
        try catalog.updateDetails(sourceId: "s", kind: .movie, itemId: "m2", cast: nil, director: nil, plot: "Başka metin.")
        XCTAssertTrue(try catalog.search("başka", sourceId: "s").isEmpty)

        // Refresh without plots (get_vod_streams): the detail plot is kept.
        var session = try catalog.beginRefresh(sourceId: "s")
        try session.write(movies: [Movie(sourceId: "s", id: "m4", name: "Sessiz", sort: 0)])
        try session.commit()
        XCTAssertEqual(try catalog.search("fenerinde", sourceId: "s").map(\.itemId), ["m4"])

        // Learned while a refresh runs → merged at commit.
        session = try catalog.beginRefresh(sourceId: "s")
        try session.write(movies: [Movie(sourceId: "s", id: "m4", name: "Sessiz", sort: 0), Movie(sourceId: "s", id: "m5", name: "Yeni", sort: 1)])
        try catalog.updateDetails(sourceId: "s", kind: .movie, itemId: "m5", cast: nil, director: nil, plot: "Uzay istasyonunda geçer.")
        try session.commit()
        XCTAssertEqual(try catalog.search("istasyonunda", sourceId: "s").map(\.itemId), ["m5"])
        XCTAssertEqual(try searchIndexCount(database, itemId: "m5"), 1)
        try catalog.deleteContent(sourceId: "s")
        XCTAssertEqual(try database.db.scalar("SELECT COUNT(*) FROM item_plot") as Int, 0)
        XCTAssertEqual(try database.db.scalar("SELECT COUNT(*) FROM search_terms") as Int, 0)
    }

    // MARK: Did you mean

    func testTypoCorrectionThroughTrigramDictionary() throws {
        try XCTSkipUnless(database.db.hasTrigram, "trigram tokenizer missing")
        XCTAssertEqual(try catalog.correction(for: "hasn can kya", sourceId: "s"), "hasan can kaya")
        XCTAssertEqual(try catalog.correction(for: "konuşanlr", sourceId: "s"), "konuşanlar")
        XCTAssertEqual(try catalog.correction(for: "Konusnalar", sourceId: "s"), "konuşanlar", "transposition")
        XCTAssertNil(try catalog.correction(for: "konusanlar", sourceId: "s"), "known word (folded)")
        XCTAssertNil(try catalog.correction(for: "kon", sourceId: "s"), "prefix of a known word")
        XCTAssertNil(try catalog.correction(for: "xqzv", sourceId: "s"), "nothing close")
        XCTAssertNil(try catalog.correction(for: "hasan", sourceId: "other"), "per source")

        let engine = SearchEngine(catalog: catalog, epg: EpgRepository(database: database), sourceId: "s")
        let r = try engine.overview("hasn can kya", infos: [])
        XCTAssertEqual(r.correction, "hasan can kaya")
        XCTAssertTrue(r.similar.contains { $0.hit.itemId == "k" }, "Konuşanlar under similar results")
        let typo = try engine.overview("konuşanlr", infos: [])
        XCTAssertEqual(typo.similar.first?.hit.itemId, "k")
        XCTAssertNil(try engine.overview("hasan", infos: []).correction, "enough hits → no suggestion")
    }

    func testDictionaryFollowsRefreshesAndDetails() throws {
        try XCTSkipUnless(database.db.hasTrigram, "trigram tokenizer missing")
        func freq(_ term: String) throws -> Int {
            try database.db.scalar("SELECT COALESCE(SUM(freq), 0) FROM search_terms WHERE source_id = 's' AND term = ?", [.text(term)])
        }
        XCTAssertEqual(try freq("hasan"), 2, "title m1 + people of k")
        let session = try catalog.beginRefresh(sourceId: "s")
        try session.write(series: [Series(sourceId: "s", id: "k", name: "Konuşanlar", sort: 0)])
        try session.commit()
        XCTAssertEqual(try freq("hasan"), 0, "replaced, not appended")
        XCTAssertEqual(try freq("konusanlar"), 1)
        try catalog.updatePeople(sourceId: "s", kind: .series, itemId: "k", cast: "Hasan Can Kaya", director: nil)
        XCTAssertEqual(try freq("hasan"), 1, "detail people added")
        XCTAssertEqual(try catalog.correction(for: "hasn", sourceId: "s"), "hasan")
        // The trigram index follows deletes (external content triggers).
        try catalog.deleteContent(sourceId: "s")
        XCTAssertNil(try catalog.correction(for: "hasn", sourceId: "s"))
    }

    func testDistance() {
        XCTAssertEqual(SearchText.distance("kya", "kaya"), 1)
        XCTAssertEqual(SearchText.distance("konusnalar", "konusanlar"), 1)
        XCTAssertEqual(SearchText.distance("abc", "xyz", limit: 1), 2)
        XCTAssertEqual(SearchText.terms("Kızılcık Şerbeti 2024 HD").map(\.term), ["kizilcik", "serbeti"])
    }

    // MARK: Suggestions

    func testCompletionsTitlesThenPeople() throws {
        let s = try catalog.completions("has", sourceId: "s")
        XCTAssertEqual(s.first, SearchSuggestion(text: "Hasan Kaçan Film", isPerson: false))
        XCTAssertTrue(s.contains(SearchSuggestion(text: "Hasan Can Kaya", isPerson: true)))
        XCTAssertLessThanOrEqual(s.count, 5)
        XCTAssertTrue(try catalog.completions("h", sourceId: "s").isEmpty, "≥ 2 characters")
        XCTAssertEqual(try catalog.completions("yılmaz", sourceId: "s").map(\.text), ["Murat Yılmaz"])
    }
}

/// Search index v7 from a v6 database with data: non-blocking, resumable copy that keeps people.
final class SearchIndexV7MigrationTests: XCTestCase {
    private func makeV6(_ path: String) throws {
        let db = try AppDatabase(db: SQLiteDatabase(path: path))
        try db.db.execute("""
        DROP TABLE search_index;
        DROP TABLE item_plot;
        DROP TABLE search_terms;
        DROP TABLE IF EXISTS search_terms_tri;
        CREATE VIRTUAL TABLE search_index USING fts5(title, people, source_id UNINDEXED, kind UNINDEXED, item_id UNINDEXED,
          tokenize = 'unicode61 remove_diacritics 2');
        INSERT INTO channels (source_id, id, name, sort) VALUES ('s', 'c1', 'TRT 1 HD', 0);
        INSERT INTO movies (source_id, id, name, sort) VALUES ('s', 'm1', 'Ayla', 0);
        INSERT INTO series (source_id, id, name, plot, sort) VALUES ('s', 'k', 'Konuşanlar', 'Gece kuşağı sohbet programı.', 0);
        INSERT INTO series (source_id, id, name, sort) VALUES ('t', 'x', 'Other Show', 0);
        INSERT INTO search_index (title, people, source_id, kind, item_id) VALUES
          ('TRT 1 HD', '', 's', 'live', 'c1'),
          ('Ayla', 'Çetin Tekindor', 's', 'movie', 'm1'),
          ('Konuşanlar', 'Hasan Can Kaya', 's', 'series', 'k'),
          ('Other Show', 'Someone Else', 't', 'series', 'x');
        """)
        db.db.userVersion = 6
    }

    func testV6DatabaseCopiesIndexInBackgroundKeepingPeopleAddingPlots() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("v7-\(UUID().uuidString).sqlite").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        try makeV6(path)
        let db = try AppDatabase(db: SQLiteDatabase(path: path))
        XCTAssertEqual(db.db.userVersion, 9)
        let catalog = CatalogRepository(database: db)
        XCTAssertTrue(db.searchBackfillPending, "migration does not copy (launch stays fast)")
        XCTAssertEqual(try searchIndexCount(db), 0)
        XCTAssertEqual(try catalog.search("trt", sourceId: "s").map(\.itemId), ["c1"], "LIKE fallback meanwhile")
        // Killed after two one-row chunks: resumes, nothing twice.
        XCTAssertFalse(try catalog.backfillSearchIndex(chunkSize: 1, maxChunks: 2))
        XCTAssertEqual(try searchIndexCount(db), 2)
        let reopened = CatalogRepository(database: try AppDatabase(db: SQLiteDatabase(path: path)))
        XCTAssertTrue(try reopened.backfillSearchIndex(chunkSize: 1))
        XCTAssertFalse(db.searchBackfillPending)
        XCTAssertEqual(try searchIndexCount(db), 4, "every row once")
        XCTAssertEqual(try db.db.scalar("SELECT COUNT(*) FROM sqlite_master WHERE name = 'search_index_v6'") as Int, 0, "v6 dropped")
        XCTAssertEqual(try catalog.search("hasan", sourceId: "s").first?.matchedPerson, "Hasan Can Kaya", "v6 people kept")
        XCTAssertEqual(try catalog.search("tekindor", sourceId: "s").map(\.itemId), ["m1"])
        XCTAssertEqual(try catalog.search("sohbet", sourceId: "s").first?.match, .description, "plot indexed from the content row")
        XCTAssertEqual(try catalog.search("konusanlar", sourceId: "s").map(\.itemId), ["k"])
        if db.db.hasTrigram { XCTAssertEqual(try catalog.correction(for: "konuşanlr", sourceId: "s"), "konuşanlar", "dictionary built") }
        XCTAssertEqual(try AppDatabase(db: SQLiteDatabase(path: path)).db.userVersion, 9, "idempotent")
    }

    /// A refresh committed while the copy is pending replaces its source's rows; the copy skips that source.
    func testRefreshDuringCopyIndexesEachRowOnce() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("v7r-\(UUID().uuidString).sqlite").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        try makeV6(path)
        let db = try AppDatabase(db: SQLiteDatabase(path: path))
        let catalog = CatalogRepository(database: db)
        XCTAssertFalse(try catalog.backfillSearchIndex(chunkSize: 1, maxChunks: 1))   // c1 copied
        let session = try catalog.beginRefresh(sourceId: "s")
        try session.write(movies: [Movie(sourceId: "s", id: "m1", name: "Ayla", sort: 0, cast: "Çetin Tekindor")])
        try session.commit()
        // A detail fetch during the pending copy (row of source t not copied yet).
        try catalog.updatePeople(sourceId: "t", kind: .series, itemId: "x", cast: "New Person", director: nil)
        XCTAssertTrue(try catalog.backfillSearchIndex())
        XCTAssertEqual(try searchIndexCount(db, sourceId: "s"), 1, "only the refreshed row")
        XCTAssertEqual(try searchIndexCount(db, sourceId: "t"), 1)
        XCTAssertEqual(try catalog.search("new person", sourceId: "t").first?.matchedPerson, "New Person", "detail people win")
        XCTAssertTrue(try catalog.search("konusanlar", sourceId: "s").isEmpty, "not in the refreshed catalog")
    }

    func testV5DatabaseRunsV6ContentBackfillIntoV7Index() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("v57-\(UUID().uuidString).sqlite").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        do {
            let db = try AppDatabase(db: SQLiteDatabase(path: path))
            try db.db.execute("""
            DROP TABLE search_index; DROP TABLE item_people; DROP TABLE item_plot; DROP TABLE search_terms;
            DROP TABLE IF EXISTS search_terms_tri;
            CREATE VIRTUAL TABLE search_index USING fts5(title, source_id UNINDEXED, kind UNINDEXED, item_id UNINDEXED,
              tokenize = 'unicode61 remove_diacritics 2');
            INSERT INTO series (source_id, id, name, plot, sort) VALUES ('s', 'k', 'Kızılcık Şerbeti', 'Aile dramı.', 0);
            """)
            db.db.userVersion = 5
        }
        let db = try AppDatabase(db: SQLiteDatabase(path: path))
        XCTAssertEqual(db.db.userVersion, 9)
        let catalog = CatalogRepository(database: db)
        XCTAssertTrue(try catalog.backfillSearchIndex())
        XCTAssertEqual(try catalog.search("kizilcik", sourceId: "s").map(\.itemId), ["k"])
        XCTAssertEqual(try catalog.search("dramı", sourceId: "s").first?.match, .description)
    }
}

/// TV programme search (SCREENS §3.6 "On TV").
final class ProgrammeSearchTests: XCTestCase {
    var database: AppDatabase!
    var catalog: CatalogRepository!
    var epg: EpgRepository!
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUpWithError() throws {
        database = try AppDatabase.inMemory()
        catalog = CatalogRepository(database: database)
        epg = EpgRepository(database: database)
        try database.db.run("INSERT INTO sources (id, sort, json) VALUES ('s', 0, '{}')")
        let session = try catalog.beginRefresh(sourceId: "s")
        try session.write(channels: [
            Channel(sourceId: "s", id: "a", name: "Atlas", categoryId: "news", epgId: "atlas.tv", catchup: CatchupInfo(type: .xtream, days: 3), sort: 0),
            Channel(sourceId: "s", id: "b", name: "Bosphorus", categoryId: "news", epgId: "BOSPHORUS.tv", sort: 1),
            Channel(sourceId: "s", id: "h", name: "Hidden", categoryId: "news", epgId: "hidden.tv", sort: 2)])
        try session.commit()
        try writeEpg([
            ("atlas.tv", -3 * 3600, "Derby Day Eski"),       // ended > 2 h ago → outside the window
            ("atlas.tv", -90 * 60, "Derby Day Özet"),        // ended 30 min ago, catch-up channel → archive
            ("BOSPHORUS.tv", -90 * 60, "Derby Day Tekrar"),   // ended, no catch-up → left out
            ("bosphorus.tv", -30 * 60, "Derby Day Canlı"),    // running (id case differs)
            ("atlas.tv", 10 * 3600, "Derby Day Gece"),        // upcoming
            ("atlas.tv", 60 * 3600, "Derby Day Uzak"),        // beyond 48 h
            ("hidden.tv", 3600, "Derby Day Gizli"),           // hidden channel
            ("atlas.tv", 2 * 3600, "Haberleri İzle"),
        ])
    }

    private func writeEpg(_ rows: [(String, TimeInterval, String)]) throws {
        let session = try epg.beginRefresh(sourceId: "s")
        try session.write(rows.map { EpgProgram(sourceId: "s", channelEpgId: $0.0, start: now.addingTimeInterval($0.1),
                                                end: now.addingTimeInterval($0.1 + 3600), title: $0.2) })
        try session.commit()
    }

    private func engine(canReplay: Bool = true) -> SearchEngine {
        var e = SearchEngine(catalog: catalog, epg: epg, sourceId: "s")
        e.hiddenChannels = ["h"]
        e.canReplay = canReplay
        return e
    }

    func testWindowOrderHiddenAndArchive() throws {
        let page = try engine().programmes("derby", offset: 0, limit: 30, now: now)
        XCTAssertEqual(page.items.map(\.program.title), ["Derby Day Canlı", "Derby Day Gece", "Derby Day Özet"])
        XCTAssertEqual(page.items.map(\.state), [.live, .upcoming, .archive])
        XCTAssertEqual(page.items.map(\.channel.id), ["b", "a", "a"])
        XCTAssertTrue(page.end)
        XCTAssertEqual(try engine(canReplay: false).programmes("derby", offset: 0, limit: 30, now: now).items.map(\.state), [.live, .upcoming],
                       "no archive without timeshift playback")
        XCTAssertEqual(try engine().programmes("haberleri izle", offset: 0, limit: 30, now: now).items.count, 1)
        XCTAssertEqual(try engine().programmes("haberlerı", offset: 0, limit: 30, now: now).items.count, 1, "ı folded")
        // Paging by raw rows.
        let first = try engine().programmes("derby", offset: 0, limit: 1, now: now)
        XCTAssertEqual(first.items.count, 1)
        XCTAssertFalse(first.end)
        let second = try engine().programmes("derby", offset: first.consumed, limit: 1, now: now)
        XCTAssertEqual(second.items.first?.program.title, "Derby Day Gece")
    }

    func testRefreshSwapsIndexAndDropsOldTable() throws {
        let old = try XCTUnwrap(EpgSearchIndex.table(database.db, sourceId: "s"))
        try writeEpg([("atlas.tv", 0, "Yeni Program")])
        try epg.collectIndexGarbage()   // SourceRefresher does this after the EPG swap
        let new = try XCTUnwrap(EpgSearchIndex.table(database.db, sourceId: "s"))
        XCTAssertNotEqual(old, new)
        XCTAssertEqual(try database.db.scalar("SELECT COUNT(*) FROM sqlite_master WHERE name = ?", [.text(old)]) as Int, 0, "old index dropped")
        XCTAssertTrue(try engine().programmes("derby", offset: 0, limit: 30, now: now).items.isEmpty)
        XCTAssertEqual(try engine().programmes("yeni", offset: 0, limit: 30, now: now).items.count, 1)
        // Aborted refresh leaves the live index alone and drops its own.
        let session = try epg.beginRefresh(sourceId: "s")
        try session.write([EpgProgram(sourceId: "s", channelEpgId: "atlas.tv", start: now, end: now.addingTimeInterval(60), title: "Abort")])
        session.abort()
        try epg.collectIndexGarbage()
        XCTAssertEqual(EpgSearchIndex.table(database.db, sourceId: "s"), new)
        XCTAssertEqual(try virtualTables(), [new])
        try catalog.deleteContent(sourceId: "s")
        try catalog.collectIndexGarbage()
        XCTAssertNil(EpgSearchIndex.table(database.db, sourceId: "s"))
        XCTAssertEqual(try virtualTables(), [])
    }

    private func virtualTables() throws -> [String] {
        try database.db.query("SELECT name FROM sqlite_master WHERE name LIKE 'epg_fts_%' AND sql LIKE 'CREATE VIRTUAL%'") { $0.string(0) }
    }

    /// EPG stored before Build 11 has no index: built in the background, resumable; leftovers are dropped.
    func testBackfillOfStoredEpgAndCleanup() throws {
        try database.db.execute("DELETE FROM kv WHERE key LIKE 'epg.fts.%';")
        for name in try virtualTables() { try database.db.execute("DROP TABLE \(name);") }
        let orphan = try EpgSearchIndex.create(database.db)
        EpgSearchIndex.inFlight.remove(orphan)   // as if left by a killed refresh
        XCTAssertTrue(try engine().programmes("derby", offset: 0, limit: 30, now: now).items.isEmpty, "no index yet")
        XCTAssertFalse(try epg.maintainSearchIndex(chunkSize: 3, maxChunks: 1))
        XCTAssertEqual(try virtualTables().filter { $0 == orphan }, [], "leftover dropped")
        XCTAssertTrue(try epg.maintainSearchIndex(chunkSize: 3))
        XCTAssertEqual(try engine().programmes("derby", offset: 0, limit: 30, now: now).items.count, 3)
        XCTAssertEqual(try virtualTables().count, 1)
        XCTAssertTrue(try epg.maintainSearchIndex(), "nothing left to do")
    }
}

/// Filters, paging, recent searches, suggestions in the view model.
@MainActor
final class SearchScreenModelTests: XCTestCase {
    private func makeEnvironment(kv: InMemoryKeyValueStore = InMemoryKeyValueStore()) async throws -> AppEnvironment {
        let m3u = try Data(contentsOf: vectorURL("m3u/valid_basic.m3u"))
        let transport = FakeTransport { _ in HTTPResponse(statusCode: 200, body: m3u) }
        let config = AppConfig(displayName: "Test", bundleId: "de.hasielektronik.novaplayer", appVersion: "1.0",
                               backendBaseURL: URL(string: "http://127.0.0.1:9")!, productIDs: ProductIDs(lifetime: "l", trial: "t"),
                               licenseKeysJSON: TestSigner().jwkSetJSON, platform: .ios, rawDeviceId: "device", deviceName: "Test")
        let env = try AppEnvironment(config: config, database: AppDatabase.inMemory(), secureStore: InMemorySecureStore(),
                                     kv: kv, transport: transport)
        _ = try await env.addSource(name: "Test", secrets: .m3u(M3USecrets(url: "http://lists.example.com/list.m3u"))) { _ in }
        let sourceId = try XCTUnwrap(env.currentSource?.id)
        let session = try env.catalog.beginRefresh(sourceId: sourceId)
        try session.write(
            categories: [IPTVCore.Category(sourceId: sourceId, id: "z", kind: .movie, name: "Zebra Filme", sort: 0)],
            channels: [TestData.channel(id: "c1", sourceId: sourceId, name: "Zebra TV", sort: 0)],
            movies: (0..<130).map { Movie(sourceId: sourceId, id: "m\($0)", name: "Zebra \($0)", categoryId: "z", sort: $0) }
                + [Movie(sourceId: sourceId, id: "p", name: "Ocean", plot: "A zebra crosses the river.", sort: 200)])
        try session.commit()
        return env
    }

    private func waitFor(_ condition: @autoclosure () -> Bool, timeout: TimeInterval = 3) async throws {
        let end = Date().addingTimeInterval(timeout)
        while !condition() && Date() < end { try await Task.sleep(for: .milliseconds(20)) }
    }

    func testFiltersAndPagedLists() async throws {
        let env = try await makeEnvironment()
        let model = SearchViewModel(env: env)
        model.query = "zebra"
        try await waitFor(!model.results.movies.isEmpty)
        XCTAssertEqual(model.results.filters, [.all, .categories, .live, .movies])
        XCTAssertEqual(model.results.movies.count, 30, "capped in All")
        XCTAssertEqual(model.results.descriptions.map(\.hit.itemId), ["p"])
        let list = try XCTUnwrap(model.list(for: .movies))
        list.loadMore()
        try await waitFor(list.items.count == 60)
        XCTAssertEqual(list.items.count, 60)
        XCTAssertFalse(list.reachedEnd)
        list.loadMoreIfNeeded(list.items[55].id)
        try await waitFor(list.items.count == 120)
        list.loadMore()
        try await waitFor(list.reachedEnd)
        XCTAssertEqual(list.items.count, 131, "130 titles + the description match")
        XCTAssertEqual(list.items.last?.hit.match, .description, "ranked after the titles")
        XCTAssertEqual(Set(list.items.map(\.id)).count, 131, "no duplicates across pages")

        let seeAll = model.listModel(.scope(.titles(.movie)))
        seeAll.loadMore()
        try await waitFor(seeAll.items.count == 60)
        XCTAssertTrue(seeAll.items.allSatisfy { $0.hit.match == .title })
        let categories = try XCTUnwrap(model.list(for: .categories))
        categories.loadMore()
        try await waitFor(!categories.categories.isEmpty)
        XCTAssertEqual(categories.categories.map(\.id), ["z"])

        model.filter = .movies
        model.query = "zebra tv"
        try await waitFor(model.results.query == "zebra tv")
        XCTAssertEqual(model.results.filters, [.all, .live])
        XCTAssertEqual(model.filter, .all, "chip without hits falls back to All")
    }

    func testRecentSearchesPersistPerSource() async throws {
        let kv = InMemoryKeyValueStore()
        let env = try await makeEnvironment(kv: kv)
        let model = SearchViewModel(env: env)
        for q in ["zebra", "ocean", "ZEBRA"] {
            model.query = q
            model.submit()
        }
        XCTAssertEqual(model.recent, ["ZEBRA", "ocean"], "newest first, folded duplicates replaced")
        for i in 0..<12 { model.query = "q\(i)"; model.rememberQuery() }
        XCTAssertEqual(model.recent.count, 10)
        XCTAssertEqual(model.recent.first, "q11")
        model.removeRecent("q11")
        XCTAssertEqual(model.recent.first, "q10")
        let store = RecentSearchStore(database: env.database)
        let sourceId = try XCTUnwrap(env.currentSource?.id)
        XCTAssertEqual(store.recent(sourceId: sourceId), model.recent, "persisted")
        XCTAssertNotNil(env.database.value(forKey: "search.recent.\(sourceId)"), "in the catalog database (no backup)")
        XCTAssertNil(kv.data(forKey: "search.recent.\(sourceId)"), "not in UserDefaults")
        XCTAssertTrue(store.recent(sourceId: "other").isEmpty, "per source")
        model.clearRecent()
        XCTAssertTrue(SearchViewModel(env: env).recent.isEmpty)
        model.query = "zebra"
        model.submit()
        env.deleteSource(id: sourceId)
        XCTAssertTrue(env.recentSearches.recent(sourceId: sourceId).isEmpty, "removed with the source")
        XCTAssertNil(env.database.value(forKey: "search.recent.\(sourceId)"))
    }

    func testSuggestionsFollowTheLatestQuery() async throws {
        let env = try await makeEnvironment()
        let model = SearchViewModel(env: env)
        model.query = "zeb"
        model.query = "oce"   // cancels the first
        try await waitFor(!model.suggestions.isEmpty)
        XCTAssertEqual(model.suggestions.map(\.text), ["Ocean"])
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(model.suggestions.map(\.text), ["Ocean"], "stale suggestions never arrive")
        model.apply(try XCTUnwrap(model.suggestions.first))
        XCTAssertEqual(model.query, "Ocean")
        XCTAssertEqual(model.recent.first, "Ocean")
        try await waitFor(model.results.query == "Ocean")
        XCTAssertEqual(model.results.movies.map(\.hit.itemId), ["p"])
        model.query = ""
        XCTAssertTrue(model.suggestions.isEmpty)
        XCTAssertTrue(model.results.isEmpty)
    }
}
