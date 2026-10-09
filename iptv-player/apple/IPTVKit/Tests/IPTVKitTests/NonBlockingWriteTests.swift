import XCTest
@testable import IPTVKit
import IPTVCore

/// Build 13 review: maintenance racing a commit, writes that never block the main actor, all-sources paging.
final class NonBlockingWriteTests: XCTestCase {
    private func tempPath() -> String {
        FileManager.default.temporaryDirectory.appendingPathComponent("nb-\(UUID().uuidString).sqlite").path
    }

    private func cleanup(_ path: String) {
        for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + suffix) }
    }

    final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
        func set() { lock.lock(); value = true; lock.unlock() }
        func wait(timeout: TimeInterval = 5) {
            let end = Date().addingTimeInterval(timeout)
            while !isSet, Date() < end { usleep(2_000) }
        }
    }

    /// Holds the writer on a background thread until `release` is set (a long refresh commit).
    private func holdWriter(_ db: AppDatabase, held: Flag, release: Flag, inside: (@Sendable () -> Void)? = nil) -> Flag {
        let done = Flag()
        DispatchQueue.global().async {
            try? db.db.transaction {
                held.set()
                release.wait()
                inside?()
            }
            done.set()
        }
        held.wait()
        return done
    }

    // MARK: 1. Maintenance racing a commit

    /// Build 12: maintenance read the old kv mapping on the reader while a refresh committed, then dropped the new
    /// index as "unreferenced" → every search failed with "no such table". Now it decides inside the writer.
    func testMaintenanceDuringCatalogCommitKeepsTheNewIndex() throws {
        let path = tempPath()
        defer { cleanup(path) }
        let db = try AppDatabase(db: SQLiteDatabase(path: path))
        let catalog = CatalogRepository(database: db)
        var session = try catalog.beginRefresh(sourceId: "s")
        try session.write(movies: [Movie(sourceId: "s", id: "m1", name: "Ayla", sort: 0)])
        try session.commit()

        session = try catalog.beginRefresh(sourceId: "s")
        try session.write(movies: [Movie(sourceId: "s", id: "m2", name: "Ayla Yeni", sort: 0)])
        let inCommit = Flag(), maintenanceStarted = Flag(), maintenanceDone = Flag()
        CommitTestHook.catalog.set {
            inCommit.set()
            maintenanceStarted.wait()
            usleep(150_000)   // maintenance is now waiting for the writer (Build 12: it had already read kv)
        }
        defer { CommitTestHook.catalog.set(nil) }
        DispatchQueue.global().async {
            inCommit.wait()
            maintenanceStarted.set()
            try? catalog.maintainSearchIndex()
            maintenanceDone.set()
        }
        try session.commit()
        maintenanceDone.wait()
        let table = try XCTUnwrap(SearchIndex.table(db.db, sourceId: "s"))
        XCTAssertEqual(try db.db.scalar("SELECT COUNT(*) FROM sqlite_master WHERE name = ?", [.text(table)]), 1, "live index kept")
        XCTAssertEqual(try catalog.search("ayla", sourceId: "s").map(\.itemId), ["m2"])
        XCTAssertEqual(try catalog.search("ayla yeni", scope: .descriptions, sourceId: "s").count, 0, "≥ 3 letters work")
    }

    func testMaintenanceDuringEpgCommitKeepsTheNewIndex() throws {
        let path = tempPath()
        defer { cleanup(path) }
        let db = try AppDatabase(db: SQLiteDatabase(path: path))
        try db.db.run("INSERT INTO sources (id, sort, json) VALUES ('s', 0, '{}')")
        let catalog = CatalogRepository(database: db)
        let s = try catalog.beginRefresh(sourceId: "s")
        try s.write(channels: [TestData.channel(id: "a", sourceId: "s", name: "A", epgId: "a.tv")])
        try s.commit()
        let epg = EpgRepository(database: db)
        let now = Date()
        func refresh(_ title: String) throws {
            let session = try epg.beginRefresh(sourceId: "s")
            try session.write([EpgProgram(sourceId: "s", channelEpgId: "a.tv", start: now, end: now.addingTimeInterval(3600), title: title)])
            try session.commit()
        }
        try refresh("Derby Eski")
        let inCommit = Flag(), maintenanceStarted = Flag(), maintenanceDone = Flag()
        CommitTestHook.epg.set {
            inCommit.set()
            maintenanceStarted.wait()
            usleep(150_000)
        }
        defer { CommitTestHook.epg.set(nil) }
        DispatchQueue.global().async {
            inCommit.wait()
            maintenanceStarted.set()
            _ = try? epg.maintainSearchIndex(pause: 0)
            maintenanceDone.set()
        }
        try refresh("Derby Yeni")
        maintenanceDone.wait()
        let engine = SearchEngine(catalog: catalog, epg: epg, sourceId: "s")
        XCTAssertEqual(try engine.programmes("derby", offset: 0, limit: 10, now: now).items.map(\.program.title), ["Derby Yeni"])
    }

    /// A query whose index was swapped between reading the name and running is retried with the new one.
    func testSearchRetriesWhenTheIndexWasSwapped() throws {
        let db = try AppDatabase.inMemory()
        let catalog = CatalogRepository(database: db)
        let session = try catalog.beginRefresh(sourceId: "s")
        try session.write(movies: [Movie(sourceId: "s", id: "m", name: "Kara Sevda", sort: 0)])
        try session.commit()
        // Simulate the stale name: point kv at a missing table once, then repair it in the retry window.
        let live = try XCTUnwrap(SearchIndex.table(db.db, sourceId: "s"))
        try db.db.execute("ALTER TABLE \(live) RENAME TO search_fts_aaaaaaaaaaaa;")
        try db.db.run("UPDATE kv SET value = 'search_fts_aaaaaaaaaaaa' WHERE key = 'search.fts.s'")
        XCTAssertEqual(try catalog.search("kara", sourceId: "s").map(\.itemId), ["m"])
    }

    // MARK: 2. Deferred progress

    @MainActor
    func testDeferredProgressIsReadBackLWWAndFlushed() async throws {
        let path = tempPath()
        defer { cleanup(path) }
        let db = try AppDatabase(db: SQLiteDatabase(path: path))
        let library = LibraryRepository(database: db)
        let held = Flag(), release = Flag()
        let done = holdWriter(db, held: held, release: release)
        var written = false
        library.saveProgressWithoutBlocking(contentKey: "k", title: "T", kind: .movie, positionMs: 42_000, durationMs: 100_000,
                                            posterUrl: nil, nowMs: 1_000) { written = true }
        XCTAssertFalse(written)
        XCTAssertEqual(try library.progress(contentKey: "k")?.data.positionMs, 42_000, "pending value read back")
        XCTAssertEqual(try library.progressItems().first?.data.positionMs, 42_000, "lists see it too")
        XCTAssertTrue(library.hasPendingWrites)
        usleep(200_000)
        release.set()
        done.wait()
        XCTAssertTrue(db.deferredWrites.drain(timeout: 5), "flushed (going to the background)")
        let stored = try XCTUnwrap(try library.storedItem(key: SyncItem.progressKey("k")))
        XCTAssertEqual(stored.data.positionMs, 42_000)
        XCTAssertEqual(stored.updatedAt, 1_000, "the action time (LWW across devices)")
        XCTAssertFalse(library.hasPendingWrites)
        // Pushed although the push cursor already passed its action time (late-write marker).
        XCTAssertEqual(try library.changed(after: 5_000).map(\.key), [SyncItem.progressKey("k")])
        try library.clearPushMarkers(try library.changed(after: 5_000))
        XCTAssertTrue(try library.changed(after: 5_000).isEmpty)
    }

    /// Device A favorites at T (queued, written at T+3); device B's change at T+1 is merged meanwhile: B stays.
    @MainActor
    func testDeferredWriteDoesNotOverwriteANewerStoredItem() throws {
        let path = tempPath()
        defer { cleanup(path) }
        let db = try AppDatabase(db: SQLiteDatabase(path: path))
        let library = LibraryRepository(database: db)
        let held = Flag(), release = Flag(), queued = Flag()
        let newer = SyncItem.progress(contentKey: "k", title: "T", contentKind: .movie, positionMs: 99_000, durationMs: 100_000,
                                      posterUrl: nil, seriesKey: nil, updatedAt: 1_001)   // remote, 1 ms after the action
        let done = holdWriter(db, held: held, release: release) {
            queued.wait()
            try? library.put(newer)   // a sync merge landing while the local save waits
        }
        library.putWithoutBlocking(SyncItem.progress(contentKey: "k", title: "T", contentKind: .movie, positionMs: 1_000,
                                                     durationMs: 100_000, posterUrl: nil, seriesKey: nil, updatedAt: 1_000))
        queued.set()
        release.set()
        done.wait()
        XCTAssertTrue(db.deferredWrites.drain(timeout: 5))
        XCTAssertEqual(try library.progress(contentKey: "k")?.data.positionMs, 99_000, "LWW: the newer remote row stays")
        XCTAssertEqual(try library.storedItem(key: SyncItem.progressKey("k"))?.updatedAt, 1_001)
    }

    /// Two queued changes of one key: only the last is written.
    @MainActor
    func testOnlyTheLatestQueuedChangeOfAKeyIsWritten() throws {
        let path = tempPath()
        defer { cleanup(path) }
        let db = try AppDatabase(db: SQLiteDatabase(path: path))
        let library = LibraryRepository(database: db)
        let held = Flag(), release = Flag()
        let done = holdWriter(db, held: held, release: release)
        func favorite(_ on: Bool, _ at: Int64) -> SyncItem {
            SyncItem.favorite(contentKey: "c", title: "C", contentKind: .live, posterUrl: nil, updatedAt: at, deleted: !on)
        }
        library.putWithoutBlocking(favorite(true, 2_000))
        library.putWithoutBlocking(favorite(false, 3_000))
        XCTAssertEqual(try library.item(key: SyncItem.favoriteKey("c"))?.deleted, true, "overlay: the latest")
        release.set()
        done.wait()
        XCTAssertTrue(db.deferredWrites.drain(timeout: 5))
        let stored = try XCTUnwrap(try library.storedItem(key: SyncItem.favoriteKey("c")))
        XCTAssertEqual(stored.updatedAt, 3_000)
        XCTAssertTrue(stored.deleted)
    }

    // MARK: 3. Favorites and recent searches never block

    @MainActor
    func testFavoriteAndRecentSearchDoNotWaitForTheWriter() async throws {
        let path = tempPath()
        defer { cleanup(path) }
        let db = try AppDatabase(db: SQLiteDatabase(path: path))
        let library = LibraryRepository(database: db)
        let favorites = FavoritesController(library: library, kv: InMemoryKeyValueStore(), now: { 5_000 })
        let recent = RecentSearchStore(database: db)
        let held = Flag(), release = Flag()
        let done = holdWriter(db, held: held, release: release)
        let target = FavoriteTarget(contentKey: "ch:a", title: "A", kind: .live, posterUrl: nil)
        let start = DispatchTime.now()
        XCTAssertTrue(favorites.toggle(target))
        recent.add("derby", sourceId: "s")
        let ms = CatalogRefreshSession.ms(since: start)
        XCTAssertLessThan(ms, 50, "main actor not blocked")
        XCTAssertTrue(favorites.isFavorite("ch:a"))
        XCTAssertEqual(try library.favorites().map(\.contentKey), ["ch:a"], "read-your-writes")
        XCTAssertEqual(recent.recent(sourceId: "s"), ["derby"])
        release.set()
        done.wait()
        XCTAssertTrue(db.deferredWrites.drain(timeout: 5))
        XCTAssertEqual(try library.storedItem(key: SyncItem.favoriteKey("ch:a"))?.deleted, false)
        XCTAssertEqual(RecentSearchStore(database: db).recent(sourceId: "s"), ["derby"], "persisted")
    }

    @MainActor
    func testLegacyRecentSearchesMigrateOnce() throws {
        let db = try AppDatabase.inMemory()
        let kv = InMemoryKeyValueStore()
        kv.setValue(["eski", "arama"], forKey: "search.recent.s")
        let store = RecentSearchStore(database: db)
        store.migrateLegacy(from: kv, sourceIds: ["s", "t"])
        XCTAssertEqual(store.recent(sourceId: "s"), ["eski", "arama"])
        XCTAssertNil(kv.data(forKey: "search.recent.s"), "UserDefaults copy deleted")
        XCTAssertEqual(RecentSearchStore(database: db).recent(sourceId: "s"), ["eski", "arama"])
    }

    // MARK: Garbage, paging

    func testReplacedIndexIsDroppedAfterTheSwap() throws {
        let db = try AppDatabase.inMemory()
        let catalog = CatalogRepository(database: db)
        for round in 0..<2 {
            let session = try catalog.beginRefresh(sourceId: "s")
            try session.write(movies: (0..<2_500).map { Movie(sourceId: "s", id: "m\($0)", name: "Film \($0) \(round)", sort: $0) })
            try session.commit()
        }
        // The commit queued the replaced index for a background DROP; collect (idempotent with that) leaves the live one.
        try IndexGarbage.collect(db.db)
        XCTAssertTrue(IndexGarbage.list(db.db).isEmpty)
        XCTAssertEqual(try db.db.scalar("SELECT COUNT(*) FROM sqlite_master WHERE name LIKE 'search_fts_%' AND sql LIKE 'CREATE VIRTUAL%'"), 1)
        // Two garbage tables, stopped after one (kill): the other stays listed and is dropped later.
        let extra = try SearchIndex.create(db.db)
        IndexTablesInFlight.shared.remove(extra)
        try db.db.transaction {
            try IndexGarbage.add(db.db, extra)
            try IndexGarbage.add(db.db, try XCTUnwrap(SearchIndex.table(db.db, sourceId: "s")))
        }
        XCTAssertFalse(try IndexGarbage.collect(db.db, maxTables: 1))
        XCTAssertEqual(IndexGarbage.list(db.db).count, 1)
        XCTAssertTrue(try IndexGarbage.collect(db.db))
        XCTAssertTrue(IndexGarbage.list(db.db).isEmpty)
    }

    /// All-sources search over several per-source tables pages through one merged order (no gaps, no repeats).
    func testAllSourcesPagingMergesTables() throws {
        let db = try AppDatabase.inMemory()
        let catalog = CatalogRepository(database: db)
        for source in ["a", "b", "c"] {
            let session = try catalog.beginRefresh(sourceId: source)
            try session.write(movies: (0..<25).map { Movie(sourceId: source, id: "\(source)\($0)", name: "Zebra \($0)", sort: $0) })
            try session.commit()
        }
        var paged: [String] = []
        for page in 0..<4 {
            paged += try catalog.search("zebra", scope: .titles(.movie), sourceId: nil, offset: page * 20, limit: 20).map(\.id)
        }
        XCTAssertEqual(paged.count, 75)
        XCTAssertEqual(Set(paged).count, 75, "no repeats across pages")
        let overview = try catalog.searchTitles("zebra", perKindLimit: 30)
        XCTAssertEqual(overview.count, 30, "capped per kind across tables")
    }
}

/// Re-review of Build 14: push markers of versions not pushed; EPG commit rolled back by an outer transaction.
final class PushMarkerAndEpgAbortTests: XCTestCase {
    func testMarkerOfAVersionWrittenDuringThePushStays() throws {
        let db = try AppDatabase.inMemory()
        let library = LibraryRepository(database: db)
        func item(_ at: Int64, _ position: Int64) -> SyncItem {
            SyncItem.progress(contentKey: "k", title: "T", contentKind: .movie, positionMs: position, durationMs: 100_000,
                              posterUrl: nil, seriesKey: nil, updatedAt: at)
        }
        // A late write (marker) is in the push batch …
        try library.put(item(1_000, 10_000))
        try db.db.run("INSERT INTO library_push (key) VALUES (?)", [.text(SyncItem.progressKey("k"))])
        let batch = try library.changed(after: 5_000)
        XCTAssertEqual(batch.map(\.updatedAt), [1_000])
        // … and during `await backend.syncPush` another queued write of the key lands (older than the cursor).
        try library.put(item(2_000, 20_000))
        try db.db.run("INSERT OR IGNORE INTO library_push (key) VALUES (?)", [.text(SyncItem.progressKey("k"))])
        try library.clearPushMarkers(batch)
        XCTAssertEqual(try library.changed(after: 5_000).map(\.updatedAt), [2_000], "the unpushed version is still pushed")
        try library.clearPushMarkers(try library.changed(after: 5_000))
        XCTAssertTrue(try library.changed(after: 5_000).isEmpty)
    }

    func testEpgCommitRolledBackByTheOuterTransactionCanBeAborted() throws {
        let db = try AppDatabase.inMemory()
        try db.db.run("INSERT INTO sources (id, sort, json) VALUES ('s', 0, '{}')")
        let catalog = CatalogRepository(database: db)
        let s = try catalog.beginRefresh(sourceId: "s")
        try s.write(channels: [TestData.channel(id: "a", sourceId: "s", name: "A", epgId: "a.tv")])
        try s.commit()
        let epg = EpgRepository(database: db)
        let now = Date()
        func program(_ title: String) -> EpgProgram {
            EpgProgram(sourceId: "s", channelEpgId: "a.tv", start: now, end: now.addingTimeInterval(3600), title: title)
        }
        let first = try epg.beginRefresh(sourceId: "s")
        try first.write([program("Derby Eski")])
        try first.commit()
        let live = try XCTUnwrap(EpgSearchIndex.table(db.db, sourceId: "s"))

        struct Failure: Error {}
        let second = try epg.beginRefresh(sourceId: "s")
        try second.write([program("Derby Yeni")])
        let newTable = try XCTUnwrap(second.searchTable)
        XCTAssertThrowsError(try db.db.transaction {   // SourceRefresher: commit + channel epg ids, then a failure
            try second.commit()
            throw Failure()
        })
        second.abort()
        XCTAssertEqual(EpgSearchIndex.table(db.db, sourceId: "s"), live, "old index still live")
        XCTAssertEqual(try db.db.scalar("SELECT COUNT(*) FROM epg WHERE source_id = 's~staging'"), 0, "staging cleaned")
        try epg.collectIndexGarbage()
        XCTAssertEqual(try db.db.scalar("SELECT COUNT(*) FROM sqlite_master WHERE name = ?", [.text(newTable)]), 0, "not orphaned")
        let engine = SearchEngine(catalog: catalog, epg: epg, sourceId: "s")
        XCTAssertEqual(try engine.programmes("derby", offset: 0, limit: 5, now: now).items.map(\.program.title), ["Derby Eski"])
        // A successful commit is not undone by a later abort().
        let third = try epg.beginRefresh(sourceId: "s")
        try third.write([program("Derby Son")])
        try third.commit()
        third.abort()
        XCTAssertEqual(try engine.programmes("derby", offset: 0, limit: 5, now: now).items.map(\.program.title), ["Derby Son"])
    }
}
