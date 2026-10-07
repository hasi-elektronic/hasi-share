import XCTest
@testable import IPTVKit
import IPTVCore

/// Build 14: tvOS purges Application Support (catalog database) – sources and favorites survive through the
/// durable mirror in UserDefaults (ARCHITECTURE §3.3), and opening the database never loses everything.
@MainActor
final class DurableStateMirrorTests: XCTestCase {
    private let urlA = "http://lists.example.com/a.m3u"
    private let urlB = "http://lists.example.com/b.m3u"

    private func config() -> AppConfig {
        AppConfig(displayName: "Test", bundleId: "de.hasielektronik.novaplayer", appVersion: "1.0",
                  backendBaseURL: URL(string: "http://127.0.0.1:9")!, productIDs: ProductIDs(lifetime: "l", trial: "t"),
                  licenseKeysJSON: TestSigner().jwkSetJSON, platform: .tvos, rawDeviceId: "device", deviceName: "Test")
    }

    private func m3uTransport() throws -> FakeTransport {
        let m3u = try Data(contentsOf: vectorURL("m3u/valid_basic.m3u"))
        return FakeTransport { request in
            request.url.path.hasSuffix(".m3u") ? HTTPResponse(statusCode: 200, body: m3u) : HTTPResponse(statusCode: 404, body: Data())
        }
    }

    private func makeEnv(database: AppDatabase, kv: any KeyValueStore, secure: any SecureStore,
                         transport: FakeTransport, defaults: UserDefaults) throws -> AppEnvironment {
        try AppEnvironment(config: config(), database: database, secureStore: secure, kv: kv,
                           settings: AppSettings(defaults: defaults), transport: transport)
    }

    private func freshDefaults() -> UserDefaults {
        let name = "mirror-test-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        addTeardownBlock { d.removePersistentDomain(forName: name) }
        return d
    }

    private func playlistRequests(_ t: FakeTransport, _ url: String) -> Int {
        t.requests.filter { $0.url.absoluteString == url }.count
    }

    // MARK: Source registry

    func testSourceMirrorFollowsAddEditReorderDeleteWithoutSecrets() throws {
        let kv = InMemoryKeyValueStore()
        let mirror = DurableStateMirror(store: kv)
        let repo = SourceRepository(database: try .inMemory(), secureStore: InMemorySecureStore(), mirror: mirror)
        let secretsA = SourceSecrets.xtream(XtreamSecrets(serverUrl: "http://panel.example.com:8080", username: "hamdi", password: "s3cr3tPass"))
        var a = Source.make(name: "Panel", secrets: secretsA, id: "a")
        let b = Source.make(name: "List", secrets: .m3u(M3USecrets(url: "http://lists.example.com/x.m3u?token=abc123")), id: "b")
        try repo.save(a, secrets: secretsA)
        try repo.save(b, secrets: .m3u(M3USecrets(url: "http://lists.example.com/x.m3u?token=abc123")))
        XCTAssertEqual(mirror.mirroredSources.map(\.id), ["a", "b"], "add")

        a.name = "Panel renamed"
        try repo.save(a)
        XCTAssertEqual(mirror.mirroredSources.first?.name, "Panel renamed", "edit")

        try repo.reorder(["b", "a"])
        XCTAssertEqual(try repo.all().map(\.id), ["b", "a"])
        XCTAssertEqual(mirror.mirroredSources.map(\.id), ["b", "a"], "reorder")

        let raw = String(decoding: try XCTUnwrap(kv.data(forKey: DurableStateMirror.sourcesKey)), as: UTF8.self)
        for secret in ["s3cr3tPass", "hamdi", "token=abc123", "x.m3u"] {
            XCTAssertFalse(raw.contains(secret), "no secrets in the mirror (\(secret))")
        }

        try repo.delete(id: "b")
        XCTAssertEqual(mirror.mirroredSources.map(\.id), ["a"], "delete")
        try repo.delete(id: "a")
        XCTAssertEqual(mirror.mirroredSources.map(\.id), [], "empty list mirrored too (nothing to restore)")
    }

    // MARK: Restore

    func testRestoreAfterDatabaseLostKeepsIdsOrderSelectionAndRefreshesOnce() async throws {
        let kv = InMemoryKeyValueStore(), secure = InMemorySecureStore(), defaults = freshDefaults()
        let env1 = try makeEnv(database: try .inMemory(), kv: kv, secure: secure, transport: try m3uTransport(), defaults: defaults)
        let a = try await env1.addSource(name: "A", secrets: .m3u(M3USecrets(url: urlA))) { _ in }
        let b = try await env1.addSource(name: "B", secrets: .m3u(M3USecrets(url: urlB))) { _ in }
        env1.selectSource(a.id)
        let channel = try XCTUnwrap(env1.catalog.channels(sourceId: b.id, limit: 1).first)
        XCTAssertTrue(env1.toggleFavorite(sourceId: b.id, kind: .live, itemId: channel.id, title: channel.name, posterUrl: nil))
        let favUpdatedAt = try XCTUnwrap(env1.library.favorites().first?.updatedAt)
        env1.mirror.flushUserState()

        // The system deleted the database (new empty file); Keychain + UserDefaults survived.
        let transport = try m3uTransport()
        let env2 = try makeEnv(database: try .inMemory(), kv: kv, secure: secure, transport: transport, defaults: defaults)
        XCTAssertEqual(env2.sources.map(\.id), [a.id, b.id], "same ids, same order")
        XCTAssertEqual(env2.currentSource?.id, a.id, "selected source restored")
        XCTAssertTrue(env2.isRestoringCatalog, "notice while the restored sources reload")
        XCTAssertEqual(env2.restore.refreshIds, [a.id, b.id])
        XCTAssertNotNil(env2.secrets(for: a.id), "secrets read from the secure store")

        await env2.restoreRefresh?.value
        XCTAssertFalse(env2.isRestoringCatalog)
        XCTAssertEqual(playlistRequests(transport, urlA), 1, "refreshed once")
        XCTAssertEqual(playlistRequests(transport, urlB), 1, "refreshed once")
        XCTAssertGreaterThan(try env2.catalog.channels(sourceId: a.id, limit: 5).count, 0, "content back after the refresh")
        await env2.refreshDueSources()   // launch refresh pass (start()): restored sources are not refreshed twice
        XCTAssertEqual(playlistRequests(transport, urlA), 1)
        XCTAssertEqual(playlistRequests(transport, urlB), 1)

        let key = try XCTUnwrap(env2.contentKey(sourceId: b.id, kind: .live, itemId: channel.id))
        XCTAssertTrue(env2.favorites.isFavorite(key), "favorite survived")
        XCTAssertEqual(try env2.library.favorites().first?.updatedAt, favUpdatedAt, "original updatedAt")
        XCTAssertEqual(try env2.database.db.scalar("SELECT COUNT(*) FROM library_push"), 0, "no push markers for restored rows")
    }

    func testRestoreWithoutSecretsKeepsSourceAsNeedingCredentials() async throws {
        let kv = InMemoryKeyValueStore(), defaults = freshDefaults()
        let env1 = try makeEnv(database: try .inMemory(), kv: kv, secure: InMemorySecureStore(), transport: try m3uTransport(), defaults: defaults)
        let a = try await env1.addSource(name: "A", secrets: .m3u(M3USecrets(url: urlA))) { _ in }

        let transport = try m3uTransport()
        let env2 = try makeEnv(database: try .inMemory(), kv: kv, secure: InMemorySecureStore(), transport: transport, defaults: defaults)
        XCTAssertEqual(env2.sources.map(\.id), [a.id], "kept, not dropped")
        XCTAssertEqual(env2.sources.first?.lastRefreshResult?.error, .invalidCredentials, "credentials-needed state")
        XCTAssertTrue(env2.restore.refreshIds.isEmpty)
        XCTAssertFalse(env2.isRestoringCatalog)
        XCTAssertNil(env2.restoreRefresh)
        XCTAssertTrue(transport.requests.isEmpty)
    }

    func testNoRestoreWhileTheDatabaseHasSources() async throws {
        let kv = InMemoryKeyValueStore(), secure = InMemorySecureStore(), defaults = freshDefaults()
        let database = try AppDatabase.inMemory()
        let env1 = try makeEnv(database: database, kv: kv, secure: secure, transport: try m3uTransport(), defaults: defaults)
        _ = try await env1.addSource(name: "A", secrets: .m3u(M3USecrets(url: urlA))) { _ in }
        let env2 = try makeEnv(database: database, kv: kv, secure: secure, transport: try m3uTransport(), defaults: defaults)
        XCTAssertFalse(env2.restore.didRestore)
        XCTAssertNil(env2.restoreRefresh)
    }

    // MARK: User state

    private func favorite(_ i: Int, at ms: Int64) -> SyncItem {
        SyncItem.favorite(contentKey: "fp\(i % 3)0123456789abc:movie:\(100_000 + i)", title: "Film Nummer \(i) – Der Titel",
                          contentKind: .movie, posterUrl: "https://image.tmdb.org/t/p/w600_and_h900_bestv2/\(UUID().uuidString.prefix(22)).jpg",
                          updatedAt: ms)
    }

    private func progress(_ i: Int, at ms: Int64) -> SyncItem {
        SyncItem.progress(contentKey: "fp\(i % 3)0123456789abc:episode:\(200_000 + i)", title: "Serie \(i) S01E0\(i % 9)",
                          contentKind: .episode, positionMs: Int64(i) * 61_000, durationMs: 2_700_000,
                          posterUrl: "http://panel.example.com:8080/images/\(UUID().uuidString.prefix(16)).png",
                          seriesKey: "fp\(i % 3)0123456789abc:series:\(300 + i % 40)", updatedAt: ms)
    }

    func testUserStateRoundTripCapsProgressKeepsUpdatedAtAndOrderWithoutPushMarkers() throws {
        let kv = InMemoryKeyValueStore()
        let mirror = DurableStateMirror(store: kv)
        let favorites = (0..<500).map { favorite($0, at: 1_700_000_000_000 + Int64($0)) }
        let progressItems = (0..<400).map { progress($0, at: 1_700_000_100_000 + Int64($0)) }
        mirror.recordUserState(.init(favorites: favorites, progress: progressItems, recentSearches: ["a": ["ayla", "türk"]],
                                     syncCursor: "42", syncLastPush: "1700000100399"))
        let state = try XCTUnwrap(mirror.mirroredUserState())
        XCTAssertEqual(Set(state.favorites), Set(favorites), "all favorites, exact fields")
        XCTAssertEqual(state.progress.count, 300, "progress capped at 300")
        XCTAssertEqual(Set(state.progress), Set(progressItems.suffix(300)), "the 300 most recent")

        // Restore into a recreated database.
        let database = try AppDatabase.inMemory()
        let secure = InMemorySecureStore()
        let repo = SourceRepository(database: database, secureStore: secure, mirror: mirror)
        let library = LibraryRepository(database: database)
        mirror.recordSources([Source(id: "a", name: "A", type: .m3u, displayHost: "h")])
        try secure.setValue(SourceSecrets.m3u(M3USecrets(url: urlA)), forKey: "source.secrets.a")
        // Device-local favorite order lives in UserDefaults already: survives unchanged.
        let order = favorites.prefix(3).reversed().map(\.contentKey)
        kv.setValue(Array(order), forKey: "fav.order.movie")

        let result = mirror.restoreIfNeeded(sources: repo, library: library, database: database)
        XCTAssertEqual(result.libraryItems, 800)
        let stored = try library.all()
        XCTAssertEqual(Set(stored.filter { $0.kind == .favorite }), Set(favorites), "original updatedAt + data")
        XCTAssertEqual(try database.db.scalar("SELECT COUNT(*) FROM library_push"), 0, "no push markers")
        XCTAssertEqual(database.value(forKey: SyncManager.lastPushKey), "1700000100399", "push cursor back: nothing re-pushed")
        XCTAssertEqual(database.value(forKey: SyncManager.cursorKey), "42")
        XCTAssertEqual(try library.changed(after: 1_700_000_100_399).count, 0, "sync has nothing to push")
        XCTAssertEqual(RecentSearchStore(database: database).recent(sourceId: "a"), ["ayla", "türk"])
        let controller = FavoritesController(library: library, kv: kv, now: { 0 })
        XCTAssertEqual(Array(controller.orderedKeys(kind: .movie).prefix(3)), Array(order), "favorite order kept")
    }

    func testRestoredRowsLoseAgainstNewerExistingRows() throws {
        let database = try AppDatabase.inMemory()
        let library = LibraryRepository(database: database)
        let newer = favorite(1, at: 2_000)
        try library.put(newer)
        var older = newer
        older.updatedAt = 1_000
        older.data.title = "old"
        XCTAssertEqual(try library.restore([older]), 0)
        XCTAssertEqual(try library.item(key: newer.key)?.data.title, newer.data.title)
    }

    func testSizeBudgetForALargeLibrary() throws {
        let kv = InMemoryKeyValueStore()
        let mirror = DurableStateMirror(store: kv)
        let sources = (0..<5).map { i in
            Source(id: UUID().uuidString, name: "Quelle \(i)", type: .xtream, displayHost: "panel\(i).example.com",
                   lastRefreshAt: Date(), lastRefreshResult: SourceStatus(liveCount: 4000, movieCount: 35_000, seriesCount: 9000, epgProgramCount: 500_000),
                   xtreamAccount: XtreamAccountInfo(status: "Active", expiresAt: Date(), maxConnections: 2, activeConnections: 0,
                                                    allowedOutputFormats: ["m3u8", "ts"], serverTimezone: "Europe/Berlin"))
        }
        mirror.recordSources(sources)
        mirror.recordSelectedSource(sources[0].id)
        let searches = Dictionary(uniqueKeysWithValues: sources.map { ($0.id, (0..<10).map { "suche nummer \($0)" }) })
        mirror.recordUserState(.init(favorites: (0..<500).map { favorite($0, at: Int64($0)) },
                                     progress: (0..<300).map { progress($0, at: Int64($0)) }, recentSearches: searches,
                                     syncCursor: "123456", syncLastPush: "1700000000000"))
        let sourceBytes = try XCTUnwrap(kv.data(forKey: DurableStateMirror.sourcesKey)).count
        let userBytes = try XCTUnwrap(kv.data(forKey: DurableStateMirror.userStateKey)).count
        print("MIRROR SIZE: sources(5)=\(sourceBytes) B, userState(500 fav + 300 progress + 50 searches)=\(userBytes) B, total=\(mirror.storedBytes) B")
        XCTAssertLessThanOrEqual(mirror.storedBytes, DurableStateMirror.budgetBytes)
        XCTAssertEqual(mirror.mirroredUserState()?.favorites.count, 500, "nothing dropped at this size")
        XCTAssertEqual(mirror.mirroredUserState()?.progress.count, 300)

        // Pathological: 5000 favorites with long incompressible titles → caps + budget trimming.
        let noise = { (0..<6).map { _ in UUID().uuidString }.joined() }
        let huge = (0..<5000).map { i in
            SyncItem.favorite(contentKey: "\(UUID().uuidString):movie:\(i)", title: noise(), contentKind: .movie,
                              posterUrl: "https://x/\(noise()).jpg", updatedAt: Int64(i))
        }
        mirror.recordUserState(.init(favorites: huge, progress: (0..<300).map { progress($0, at: Int64($0)) }))
        print("MIRROR SIZE (pathological): total=\(mirror.storedBytes) B, favorites kept=\(mirror.mirroredUserState()?.favorites.count ?? -1)")
        XCTAssertLessThanOrEqual(mirror.storedBytes, DurableStateMirror.budgetBytes)
        let kept = try XCTUnwrap(mirror.mirroredUserState())
        XCTAssertTrue(kept.progress.isEmpty, "progress dropped before favorites")
        XCTAssertEqual(kept.favorites.first?.updatedAt, 4999, "newest favorites kept")
    }

    func testUserStateWritesAreThrottled() throws {
        final class Counter: @unchecked Sendable {
            let lock = NSLock(); var n = 0
            func bump() { lock.lock(); n += 1; lock.unlock() }
            var value: Int { lock.lock(); defer { lock.unlock() }; return n }
        }
        let calls = Counter()
        let mirror = DurableStateMirror(store: InMemoryKeyValueStore(), interval: 0.5)
        mirror.userStateProvider = { calls.bump(); return .init(favorites: [], progress: []) }
        mirror.noteUserStateChanged()
        mirror.waitForPendingWrites()
        XCTAssertEqual(calls.value, 1, "first change written at once (leading edge)")
        for _ in 0..<20 { mirror.noteUserStateChanged() }
        mirror.waitForPendingWrites()
        XCTAssertEqual(calls.value, 1, "changes within the interval wait")
        Thread.sleep(forTimeInterval: 0.8)
        mirror.waitForPendingWrites()
        XCTAssertEqual(calls.value, 2, "coalesced into one trailing write")
        mirror.flushUserState()
        XCTAssertEqual(calls.value, 3, "background flush writes at once")
    }

    func testEmptyDatabaseNeverOverwritesTheMirror() async throws {
        let kv = InMemoryKeyValueStore(), secure = InMemorySecureStore(), defaults = freshDefaults()
        let env1 = try makeEnv(database: try .inMemory(), kv: kv, secure: secure, transport: try m3uTransport(), defaults: defaults)
        let a = try await env1.addSource(name: "A", secrets: .m3u(M3USecrets(url: urlA))) { _ in }
        let channel = try XCTUnwrap(env1.catalog.channels(sourceId: a.id, limit: 1).first)
        env1.toggleFavorite(sourceId: a.id, kind: .live, itemId: channel.id, title: channel.name, posterUrl: nil)
        env1.mirror.flushUserState()
        let before = try XCTUnwrap(kv.data(forKey: DurableStateMirror.userStateKey))

        // A launch whose library restore is skipped (no mirrored sources) must not clear the favorites copy.
        let empty = DurableStateMirror(store: kv)
        empty.userStateProvider = { nil }
        empty.flushUserState()
        XCTAssertEqual(kv.data(forKey: DurableStateMirror.userStateKey), before)
    }

    // MARK: Database open fallback

    private func tempDir() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("dbopen-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testOpenRecreatesACorruptFile() throws {
        let dir = tempDir()
        try Data(repeating: 0x5A, count: 8192).write(to: dir.appendingPathComponent("catalog.sqlite"))
        let opened = AppDatabase.open(primary: dir, caches: tempDir())
        XCTAssertEqual(opened.location, .applicationSupport)
        XCTAssertTrue(opened.recreatedCorruptFile)
        XCTAssertEqual(opened.database.db.userVersion, 8, "fresh schema")
    }

    func testOpenFallsBackToCachesThenMemory() throws {
        let blocker = tempDir().appendingPathComponent("not-a-dir")
        try Data("x".utf8).write(to: blocker)   // a file where the directory should be → cannot open
        let caches = tempDir()
        let opened = AppDatabase.open(primary: blocker, caches: caches)
        XCTAssertEqual(opened.location, .caches)
        XCTAssertFalse(opened.recreatedCorruptFile)
        XCTAssertTrue(FileManager.default.fileExists(atPath: caches.appendingPathComponent("catalog.sqlite").path))

        let blocked2 = tempDir().appendingPathComponent("also-a-file")
        try Data("x".utf8).write(to: blocked2)
        let memory = AppDatabase.open(primary: blocker, caches: blocked2)
        XCTAssertEqual(memory.location, .memory)
        XCTAssertEqual(memory.database.db.path, ":memory:")
        XCTAssertNoThrow(try memory.database.db.scalar("SELECT COUNT(*) FROM sources"))
    }

    func testOpenUsesThePrimaryDirectoryNormally() throws {
        let dir = tempDir()
        let opened = AppDatabase.open(primary: dir, caches: tempDir())
        XCTAssertEqual(opened.location, .applicationSupport)
        XCTAssertFalse(opened.recreatedCorruptFile)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("catalog.sqlite").path))
    }
}
