import XCTest
@testable import IPTVKit
import IPTVCore

/// Build 12 review: a catalog refresh must not hold the database for seconds (UI freezes while zapping during the
/// launch refresh). Owner-sized catalog (4k live, 35k movies, 9k series, all with descriptions), on-disk WAL.
final class CommitLockTests: XCTestCase {
    #if DEBUG
    let factor = 2.0
    #else
    let factor = 1.0
    #endif

    private func tempPath() -> String {
        FileManager.default.temporaryDirectory.appendingPathComponent("lock-\(UUID().uuidString).sqlite").path
    }

    private func refresh(_ repo: CatalogRepository, commit: Bool) throws -> CatalogRefreshSession {
        let words = CatalogPerformanceTests.vocabulary(20_000, seed: 3)
        func w(_ i: Int) -> String { words[(i &* 7919) % words.count] }
        func plot(_ i: Int) -> String { (0..<25).map { w(i * 31 + $0 * 17) }.joined(separator: " ") + " Kızılcık dizisi." }
        let session = try repo.beginRefresh(sourceId: "o")
        try session.write(categories: (0..<300).map { IPTVCore.Category(sourceId: "o", id: "c\($0)", kind: [.live, .movie, .series][$0 % 3], name: "TR | \(w($0))", sort: $0) })
        try session.write(channels: (0..<4_000).map { TestData.channel(id: "l\($0)", sourceId: "o", name: "\(w($0).capitalized) TV", categoryId: "c\(($0 % 100) * 3)", epgId: "e\($0)", sort: $0) })
        for chunk in stride(from: 0, to: 35_000, by: 1000) {
            try session.write(movies: (chunk..<(chunk + 1000)).map {
                Movie(sourceId: "o", id: "m\($0)", name: "\(w($0 + 5).capitalized) \(w($0 + 9))", categoryId: "c\(($0 % 100) * 3 + 1)", plot: plot($0),
                      sort: $0, cast: "\(w($0 + 2).capitalized) \(w($0 + 3).capitalized)", director: w($0 + 4).capitalized)
            })
        }
        for chunk in stride(from: 0, to: 9_000, by: 1000) {
            try session.write(series: (chunk..<(chunk + 1000)).map {
                Series(sourceId: "o", id: "s\($0)", name: "\(w($0 + 11).capitalized)", categoryId: "c\(($0 % 100) * 3 + 2)", plot: plot($0 + 7), sort: $0,
                       cast: w($0 + 12).capitalized)
            })
        }
        if commit { try session.commit() }
        return session
    }

    /// The commit's search-index work is ≤ 100 ms (it used to re-tokenise every index row: 1–3 s on a Mac), and
    /// reads made while the whole commit runs (on another thread, like the launch refresh) never wait for it.
    func testRefreshCommitDoesNotBlockReads() throws {
        let path = tempPath()
        defer { for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + suffix) } }
        let db = try AppDatabase(db: SQLiteDatabase(path: path))
        let repo = CatalogRepository(database: db)
        let first = try refresh(repo, commit: true)
        let second = try refresh(repo, commit: false)   // steady state: replaces a full catalog, drops the previous index

        final class Box: @unchecked Sendable { var done = false; let lock = NSLock()
            var isDone: Bool { lock.lock(); defer { lock.unlock() }; return done } }
        let box = Box()
        DispatchQueue.global().async {
            try? second.commit()
            box.lock.lock(); box.done = true; box.lock.unlock()
        }
        var maxRead = 0.0, reads = 0
        while !box.isDone {
            let start = DispatchTime.now()
            _ = try repo.movies(sourceId: "o", limit: 60)
            _ = try repo.channels(sourceId: "o", categoryId: "c3", limit: 120)
            maxRead = max(maxRead, CatalogRefreshSession.ms(since: start))
            reads += 1
        }
        print("PERF refresh commit (owner size, on disk): swap first \(String(format: "%.1f", first.swapMilliseconds)) ms / second "
              + "\(String(format: "%.1f", second.swapMilliseconds)) ms, of it search index \(String(format: "%.1f", second.indexMilliseconds)) ms; "
              + "dictionary first \(String(format: "%.1f", first.dictionaryMilliseconds)) ms / second \(String(format: "%.1f", second.dictionaryMilliseconds)) ms; "
              + "\(reads) reads during the commit, slowest \(String(format: "%.2f", maxRead)) ms")
        XCTAssertLessThan(second.indexMilliseconds, 100 * factor, "search index part of the commit \(second.indexMilliseconds) ms")
        XCTAssertLessThan(second.dictionaryMilliseconds, 100 * factor, "dictionary diff \(second.dictionaryMilliseconds) ms")
        XCTAssertGreaterThan(reads, 3)
        XCTAssertLessThan(maxRead, 50, "a read waited for the commit")
        XCTAssertEqual(try repo.search("kizilcik", scope: .descriptions, sourceId: "o", limit: 5).count, 5)
        XCTAssertEqual(SearchIndex.owned(db.db).count, 1, "one live index, the previous one dropped")
        XCTAssertEqual(try db.db.scalar("SELECT COUNT(*) FROM sqlite_master WHERE name LIKE 'search_fts_%' AND sql LIKE 'CREATE VIRTUAL%'"), 1)
    }

    /// First launch after the v7 update: the background copy holds the writer only per small chunk.
    func testV7CopyChunksAreShort() throws {
        let path = tempPath()
        defer { for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + suffix) } }
        do {
            let db = try AppDatabase(db: SQLiteDatabase(path: path))
            try db.db.execute("""
            CREATE VIRTUAL TABLE search_index_v6 USING fts5(title, people, source_id UNINDEXED, kind UNINDEXED, item_id UNINDEXED,
              tokenize = 'unicode61 remove_diacritics 2');
            """)
            try db.db.transaction {
                for i in 0..<20_000 {
                    try db.db.run("INSERT INTO movies (source_id, id, name, plot, sort) VALUES ('s', ?, ?, ?, ?)",
                                  [.text("m\(i)"), .text("Film \(i) Kara"), .text("Uzun bir açıklama metni \(i) burada duruyor ve devam ediyor."), .int(Int64(i))])
                    try db.db.run("INSERT INTO search_index_v6 (title, people, source_id, kind, item_id) VALUES (?, 'Hasan Can Kaya, Ali Yılmaz', 's', 'movie', ?)",
                                  [.text("Film \(i) Kara"), .text("m\(i)")])
                }
                try SearchBackfill.scheduleCopy(db.db)
            }
        }
        let db = try AppDatabase(db: SQLiteDatabase(path: path))
        let catalog = CatalogRepository(database: db)
        var times: [Double] = []
        while db.searchBackfillPending, times.count < 200 {
            let start = DispatchTime.now()
            _ = try catalog.backfillSearchIndex(maxChunks: 1, pause: 0)
            times.append(CatalogRefreshSession.ms(since: start))
        }
        let sorted = times.sorted()
        print("PERF v7 copy chunk (300 rows, on disk): median \(String(format: "%.1f", sorted[sorted.count / 2])) ms, max \(String(format: "%.1f", sorted.last ?? 0)) ms, \(times.count) chunks")
        XCTAssertFalse(db.searchBackfillPending)
        XCTAssertLessThan(sorted[sorted.count / 2], 50, "copy chunk")
    }

    /// A read while a writer transaction runs is answered by the read connection without waiting for it.
    func testReadsDoNotWaitForAWriter() throws {
        let path = tempPath()
        defer { for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + suffix) } }
        let db = try AppDatabase(db: SQLiteDatabase(path: path))
        XCTAssertTrue(db.db.hasReadConnection)
        let repo = CatalogRepository(database: db)
        let session = try repo.beginRefresh(sourceId: "o")
        try session.write(movies: (0..<500).map { Movie(sourceId: "o", id: "m\($0)", name: "Film \($0)", sort: $0) })
        try session.commit()

        let inTransaction = expectation(description: "writer holds the lock")
        let release = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            try? db.db.transaction {
                try db.db.run("UPDATE movies SET name = 'changed' WHERE id = 'm1'")
                // Inside: own reads see the uncommitted change (writer connection).
                XCTAssertEqual(try? db.db.queryFirst("SELECT name FROM movies WHERE id = 'm1'") { $0.string(0) }, "changed")
                inTransaction.fulfill()
                _ = release.wait(timeout: .now() + 5)
            }
        }
        wait(for: [inTransaction], timeout: 5)
        let start = DispatchTime.now()
        let page = try repo.movies(sourceId: "o", limit: 60)
        let hits = try repo.search("film", sourceId: "o")
        let ms = CatalogRefreshSession.ms(since: start)
        XCTAssertEqual(try repo.movie(sourceId: "o", id: "m1")?.name, "Film 1", "last committed state (uncommitted change invisible)")
        release.signal()
        print("PERF reads during a writer transaction: \(String(format: "%.2f", ms)) ms")
        XCTAssertEqual(page.count, 60)
        XCTAssertEqual(hits.count, 30)
        XCTAssertLessThan(ms, 100, "reads waited for the writer")
        // After the commit the reader sees it.
        let deadline = Date().addingTimeInterval(3)
        while try repo.movie(sourceId: "o", id: "m1")?.name != "changed", Date() < deadline { usleep(10_000) }
        XCTAssertEqual(try repo.movie(sourceId: "o", id: "m1")?.name, "changed")
    }

    /// A cancelled search task interrupts its running statement (stale queries do not run on).
    func testCancelledTaskInterruptsItsQuery() async throws {
        let db = try AppDatabase.inMemory()
        let task = Task.detached { () -> (Bool, Double) in
            let start = DispatchTime.now()
            let failed = SQLiteDatabase.$interruptsOnCancel.withValue(true) {
                (try? db.db.scalar("WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < 200000000) SELECT COUNT(*) FROM n")) == nil
            }
            return (failed, CatalogRefreshSession.ms(since: start))
        }
        try await Task.sleep(for: .milliseconds(50))
        task.cancel()
        let (interrupted, ms) = await task.value
        XCTAssertTrue(interrupted, "SQLITE_INTERRUPT")
        XCTAssertLessThan(ms, 2000)
        // Without the flag nothing is interrupted.
        XCTAssertEqual(try db.db.scalar("SELECT 1"), 1)
    }
}

/// Build 12 review fixes around the v7 index, short queries and the per-source index.
final class SearchReviewFixTests: XCTestCase {
    private func tempPath() -> String {
        FileManager.default.temporaryDirectory.appendingPathComponent("rv-\(UUID().uuidString).sqlite").path
    }

    /// Build 11 wrote `user_version = 7` after the migration transaction: a kill in between left the v7 schema at
    /// version 6. Re-running v7 must keep the renamed v6 table (its people) and the copy state.
    func testV7RerunAfterKillKeepsCopyState() throws {
        let path = tempPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        do {
            let db = try AppDatabase(db: SQLiteDatabase(path: path))
            try db.db.execute("""
            CREATE VIRTUAL TABLE search_index_v6 USING fts5(title, people, source_id UNINDEXED, kind UNINDEXED, item_id UNINDEXED,
              tokenize = 'unicode61 remove_diacritics 2');
            INSERT INTO series (source_id, id, name, sort) VALUES ('s', 'k', 'Konuşanlar', 0);
            INSERT INTO search_index_v6 (title, people, source_id, kind, item_id) VALUES ('Konuşanlar', 'Hasan Can Kaya', 's', 'series', 'k');
            INSERT INTO kv (key, value) VALUES ('search.backfill.copy.max', '1'), ('search.backfill.copy.at', '0'), ('search.backfill.pending', '1');
            """)
            db.db.userVersion = 6   // the kill: schema is v7, version still 6
        }
        let db = try AppDatabase(db: SQLiteDatabase(path: path))
        XCTAssertEqual(db.db.userVersion, 7)
        XCTAssertEqual(try db.db.scalar("SELECT COUNT(*) FROM sqlite_master WHERE name = 'search_index_v6'"), 1, "v6 kept")
        let catalog = CatalogRepository(database: db)
        XCTAssertTrue(try catalog.backfillSearchIndex(pause: 0))
        XCTAssertEqual(try catalog.search("hasan", sourceId: "s").first?.matchedPerson, "Hasan Can Kaya", "people survived")
    }

    /// Copy keys pointing at a dropped v6 table: the copy counts as done (search does not stay on LIKE forever).
    func testCopyStateWithoutV6TableFinishes() throws {
        let db = try AppDatabase.inMemory()
        try db.db.execute("""
        INSERT INTO kv (key, value) VALUES ('search.backfill.copy.max', '50'), ('search.backfill.copy.at', '0'), ('search.backfill.pending', '1');
        """)
        XCTAssertTrue(db.searchBackfillPending)
        XCTAssertTrue(try CatalogRepository(database: db).backfillSearchIndex(pause: 0))
        XCTAssertFalse(db.searchBackfillPending)
        XCTAssertNil(db.value(forKey: "search.backfill.copy.max"))
    }

    func testMigrationVersionIsWrittenInsideTheTransaction() throws {
        let source = try String(contentsOfFile: #filePath.replacingOccurrences(of: "Tests/IPTVKitTests/CommitLockTests.swift",
                                                                               with: "Sources/IPTVKit/Database/AppDatabase.swift"), encoding: .utf8)
        XCTAssertFalse(source.contains("db.userVersion = "), "every migration sets PRAGMA user_version in its transaction")
    }

    func testTrigramIndexCreatedLaterWhenMissing() throws {
        let db = try AppDatabase.inMemory()
        try XCTSkipUnless(db.db.hasTrigram)
        try db.db.execute("DROP TRIGGER search_terms_ai; DROP TRIGGER search_terms_ad; DROP TABLE search_terms_tri;")
        let catalog = CatalogRepository(database: db)
        let session = try catalog.beginRefresh(sourceId: "s")
        try session.write(series: [Series(sourceId: "s", id: "k", name: "Konuşanlar", sort: 0)])
        try session.commit()
        XCTAssertNil(try catalog.correction(for: "konuşanlr", sourceId: "s"), "no index yet → no suggestion, no error")
        try catalog.maintainSearchIndex()
        XCTAssertEqual(try catalog.correction(for: "konuşanlr", sourceId: "s"), "konuşanlar", "rebuilt from the dictionary rows")
    }

    func testDescriptionVariantOnlyForAffectedWords() {
        let text = "Kızılcık ailesinin hikâyesi. Kızılcık şerbeti içilir."
        let indexed = CatalogPeople.indexedWords(text)
        XCTAssertEqual(indexed, text + " \u{2063} Kizilcik", "one variant per affected word, not the whole text again")
        XCTAssertEqual(CatalogPeople.indexedWords("No dotless i here"), "No dotless i here")
    }

    func testLikeFallbackFindsTurkishLettersBothWays() throws {
        let db = try AppDatabase.inMemory()
        try db.db.execute("""
        INSERT INTO series (source_id, id, name, sort) VALUES ('s', 'k', 'Kızılcık Şerbeti', 0);
        INSERT INTO kv (key, value) VALUES ('search.backfill.pending', '1');
        """)
        let catalog = CatalogRepository(database: db)
        XCTAssertEqual(try catalog.search("kızılcık", sourceId: "s").map(\.itemId), ["k"])
        XCTAssertEqual(try catalog.search("kizilcik", sourceId: "s").map(\.itemId), ["k"])
        XCTAssertEqual(try catalog.search("KIZILCIK", sourceId: "s").map(\.itemId), ["k"])
    }

    func testShortQueriesSearchTitlesOnly() throws {
        let db = try AppDatabase.inMemory()
        let catalog = CatalogRepository(database: db)
        let session = try catalog.beginRefresh(sourceId: "s")
        try session.write(movies: [Movie(sourceId: "s", id: "a", name: "Kara Sevda", sort: 0),
                                   Movie(sourceId: "s", id: "b", name: "Other", plot: "Kara bulutlar.", sort: 1, cast: "Kaan Urgancıoğlu")])
        try session.commit()
        let engine = SearchEngine(catalog: catalog, epg: EpgRepository(database: db), sourceId: "s")
        let short = try engine.overview("ka", infos: [])
        XCTAssertEqual(short.movies.map(\.hit.itemId), ["a"])
        XCTAssertTrue(short.people.isEmpty && short.descriptions.isEmpty && short.programmes.isEmpty && short.correction == nil)
        let full = try engine.overview("kara", infos: [])
        XCTAssertEqual(full.descriptions.map(\.hit.itemId), ["b"])
        XCTAssertFalse(SearchEngine.isFullQuery("k a"))
        XCTAssertTrue(SearchEngine.isFullQuery("kar"))
    }

    /// Per-source index: a refresh swaps tables; the shared v7 table and leftovers are cleaned by maintenance.
    func testPerSourceIndexSwapAndMaintenance() throws {
        let db = try AppDatabase.inMemory()
        let catalog = CatalogRepository(database: db)
        try db.db.execute("""
        INSERT INTO search_index (title, people, plot, source_id, kind, item_id) VALUES ('Old Title', '', '', 's', 'movie', 'old');
        """)
        XCTAssertEqual(try catalog.search("old", sourceId: "s").map(\.itemId), ["old"], "not refreshed yet: shared table")
        let session = try catalog.beginRefresh(sourceId: "s")
        try session.write(movies: [Movie(sourceId: "s", id: "new", name: "New Title", sort: 0)])
        try session.commit()
        XCTAssertTrue(try catalog.search("old", sourceId: "s").isEmpty, "own index now")
        XCTAssertEqual(try catalog.search("title").map(\.itemId), ["new"], "all sources: shared rows of owned sources ignored")
        let leftover = try SearchIndex.create(db.db)
        IndexTablesInFlight.shared.remove(leftover)   // as if a refresh was killed
        try catalog.maintainSearchIndex()
        XCTAssertEqual(try db.db.scalar("SELECT COUNT(*) FROM search_index"), 0, "shared table emptied")
        XCTAssertEqual(try db.db.scalar("SELECT COUNT(*) FROM sqlite_master WHERE name = ?", [.text(leftover)]), 0, "leftover dropped")
        XCTAssertEqual(try catalog.search("new", sourceId: "s").map(\.itemId), ["new"])
        let aborted = try catalog.beginRefresh(sourceId: "s")
        let table = try XCTUnwrap(aborted.searchTable)
        aborted.abort()
        try catalog.collectIndexGarbage()
        XCTAssertEqual(try db.db.scalar("SELECT COUNT(*) FROM sqlite_master WHERE name = ?", [.text(table)]), 0)
        try catalog.deleteContent(sourceId: "s")
        XCTAssertTrue(SearchIndex.owned(db.db).isEmpty)
    }

    func testDuplicateXmltvEntriesGetDistinctIds() throws {
        let db = try AppDatabase.inMemory()
        try db.db.run("INSERT INTO sources (id, sort, json) VALUES ('s', 0, '{}')")
        let catalog = CatalogRepository(database: db)
        let session = try catalog.beginRefresh(sourceId: "s")
        try session.write(channels: [TestData.channel(id: "a", sourceId: "s", name: "A", epgId: "a.tv")])
        try session.commit()
        let epg = EpgRepository(database: db)
        let now = Date()
        let p = EpgProgram(sourceId: "s", channelEpgId: "a.tv", start: now.addingTimeInterval(600), end: now.addingTimeInterval(3600), title: "Derby")
        let refresh = try epg.beginRefresh(sourceId: "s")
        try refresh.write([p, p])
        try refresh.commit()
        let hits = try SearchEngine(catalog: catalog, epg: epg, sourceId: "s").programmes("derby", offset: 0, limit: 10, now: now).items
        XCTAssertEqual(hits.count, 2)
        XCTAssertEqual(Set(hits.map(\.id)).count, 2, "unique focus identity")
    }

    /// While a commit holds the writer, the player's progress save does not block the main actor.
    @MainActor
    func testPlayerProgressSaveDoesNotWaitForACommit() async throws {
        let path = tempPath()
        defer { for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + suffix) } }
        let db = try AppDatabase(db: SQLiteDatabase(path: path))
        let library = LibraryRepository(database: db)
        final class Flag: @unchecked Sendable { private let l = NSLock(); private var v = false
            var value: Bool { get { l.lock(); defer { l.unlock() }; return v } set { l.lock(); v = newValue; l.unlock() } } }
        let held = Flag(), release = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            try? db.db.transaction {
                held.value = true
                _ = release.wait(timeout: .now() + 5)
            }
        }
        while !held.value { try await Task.sleep(for: .milliseconds(5)) }
        let start = DispatchTime.now()
        var done = false
        library.saveProgressWithoutBlocking(contentKey: "k", title: "T", kind: .live, positionMs: 0, durationMs: 0,
                                            posterUrl: nil, nowMs: 1) { done = true }
        let ms = CatalogRefreshSession.ms(since: start)
        XCTAssertLessThan(ms, 50, "main actor not blocked")
        XCTAssertFalse(done)
        release.signal()
        let deadline = Date().addingTimeInterval(3)
        while !done, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(done)
        XCTAssertNotNil(try library.progress(contentKey: "k"), "written after the commit")
    }
}
