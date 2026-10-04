import Foundation
import IPTVCore
import XCTest
@testable import IPTVKit

final class RepositoryTests: XCTestCase {
    var database: AppDatabase!
    var catalog: CatalogRepository!

    override func setUpWithError() throws {
        database = try AppDatabase.inMemory()
        catalog = CatalogRepository(database: database)
    }

    private func channels(_ n: Int, source: String = "s1", prefix: String = "Kanal") -> [Channel] {
        (0..<n).map { Channel(sourceId: source, id: "c\($0)", name: "\(prefix) \($0)", number: $0 + 1,
                              categoryId: $0 % 2 == 0 ? "even" : "odd", epgId: "ch\($0).tr", sort: $0) }
    }

    func testFTS5Available() {
        XCTAssertTrue(database.db.hasFTS5, "system SQLite must provide FTS5")
    }

    func testAtomicRefreshIsInvisibleUntilCommit() throws {
        let first = try catalog.beginRefresh(sourceId: "s1")
        try first.write(channels: channels(10))
        XCTAssertEqual(try catalog.channelCount(sourceId: "s1"), 0, "staged rows must not be visible")
        try first.commit()
        XCTAssertEqual(try catalog.channelCount(sourceId: "s1"), 10)

        // A failing refresh keeps the old content.
        let second = try catalog.beginRefresh(sourceId: "s1")
        try second.write(channels: channels(3, prefix: "Neu"))
        second.abort()
        XCTAssertEqual(try catalog.channelCount(sourceId: "s1"), 10)
        XCTAssertEqual(try catalog.channels(sourceId: "s1", limit: 1).first?.name, "Kanal 0")

        // A successful refresh replaces everything at once (incl. search index).
        let third = try catalog.beginRefresh(sourceId: "s1")
        try third.write(channels: channels(3, prefix: "Neu"))
        try third.commit()
        XCTAssertEqual(try catalog.channelCount(sourceId: "s1"), 3)
        XCTAssertTrue(try catalog.search("kanal").isEmpty)
        XCTAssertEqual(try catalog.search("neu").count, 3)
    }

    func testPagingAndCategories() throws {
        let session = try catalog.beginRefresh(sourceId: "s1")
        try session.write(categories: [IPTVCore.Category(sourceId: "s1", id: "even", kind: .live, name: "Even", sort: 0),
                                       IPTVCore.Category(sourceId: "s1", id: "odd", kind: .live, name: "Odd", sort: 1)],
                          channels: channels(250))
        try session.commit()
        let page1 = try catalog.channels(sourceId: "s1", offset: 0, limit: 100)
        let page3 = try catalog.channels(sourceId: "s1", offset: 200, limit: 100)
        XCTAssertEqual(page1.count, 100)
        XCTAssertEqual(page3.count, 50)
        XCTAssertEqual(page3.first?.id, "c200")
        XCTAssertEqual(try catalog.channelCount(sourceId: "s1", categoryId: "even"), 125)
        XCTAssertEqual(try catalog.categories(sourceId: "s1", kind: .live).map(\.name), ["Even", "Odd"])
        XCTAssertEqual(try catalog.channels(sourceId: "s1", ids: ["c5", "c1"]).map(\.id), ["c5", "c1"])
    }

    func testMovieSortAndSearchDiacritics() throws {
        let session = try catalog.beginRefresh(sourceId: "s1")
        try session.write(movies: [
            Movie(sourceId: "s1", id: "1", name: "Zeki Müren", rating: 6, addedAt: Date(timeIntervalSince1970: 100), sort: 0),
            Movie(sourceId: "s1", id: "2", name: "Ağaçlar", rating: 9, addedAt: Date(timeIntervalSince1970: 300), sort: 1),
            Movie(sourceId: "s1", id: "3", name: "Bambi", rating: nil, addedAt: Date(timeIntervalSince1970: 200), sort: 2),
        ])
        try session.commit()
        XCTAssertEqual(try catalog.movies(sourceId: "s1", sort: .added).map(\.id), ["2", "3", "1"])
        XCTAssertEqual(try catalog.movies(sourceId: "s1", sort: .rating).map(\.id), ["2", "1", "3"])
        XCTAssertEqual(try catalog.search("muren").map(\.itemId), ["1"], "diacritics are ignored")
        XCTAssertEqual(try catalog.search("ag").map(\.itemId), ["2"], "prefix match")
    }

    func testLibraryFavoritesAndLWWMerge() throws {
        let library = LibraryRepository(database: database)
        try library.setFavorite(true, contentKey: "fp:live:1", title: "A", kind: .live, posterUrl: nil, nowMs: 100)
        XCTAssertTrue(try library.isFavorite(contentKey: "fp:live:1"))
        // Older remote delete loses, newer wins, tie keeps stored.
        let older = SyncItem.favorite(contentKey: "fp:live:1", title: "A", contentKind: .live, posterUrl: nil, updatedAt: 50, deleted: true)
        let tie = SyncItem.favorite(contentKey: "fp:live:1", title: "A", contentKind: .live, posterUrl: nil, updatedAt: 100, deleted: true)
        XCTAssertTrue(try library.merge([older, tie]).isEmpty)
        XCTAssertTrue(try library.isFavorite(contentKey: "fp:live:1"))
        let newer = SyncItem.favorite(contentKey: "fp:live:1", title: "A", contentKind: .live, posterUrl: nil, updatedAt: 200, deleted: true)
        XCTAssertEqual(try library.merge([newer]).count, 1)
        XCTAssertFalse(try library.isFavorite(contentKey: "fp:live:1"))

        try library.saveProgress(contentKey: "fp:movie:9", title: "M", kind: .movie, positionMs: 30_000, durationMs: 100_000,
                                 posterUrl: nil, nowMs: 300)
        XCTAssertEqual(try library.progress(contentKey: "fp:movie:9")?.data.positionMs, 30_000)
        XCTAssertEqual(try library.changed(after: 150).map(\.key), ["fav:fp:live:1", "prog:fp:movie:9"])
    }

    func testSourceSecretsStayOutOfDatabase() throws {
        let store = InMemorySecureStore()
        let repo = SourceRepository(database: database, secureStore: store)
        let secrets = SourceSecrets.xtream(XtreamSecrets(serverUrl: "http://panel.example.com:8080", username: "user1", password: "s3cr3tPW"))
        let source = Source.make(name: "Panel", secrets: secrets)
        try repo.save(source, secrets: secrets)
        let json = try database.db.query("SELECT json FROM sources") { $0.string(0) }.joined()
        XCTAssertFalse(json.contains("s3cr3tPW"))
        XCTAssertFalse(json.contains("user1"))
        XCTAssertEqual(repo.secrets(id: source.id), secrets)
        XCTAssertEqual(try repo.all().first?.displayHost, "panel.example.com")
        XCTAssertFalse(SafeLog.redacted("GET http://panel.example.com:8080/live/user1/s3cr3tPW/1.m3u8").contains("s3cr3tPW"))
        try repo.delete(id: source.id)
        XCTAssertNil(repo.secrets(id: source.id))
    }

    func testRefresherLoadsM3UAndEpgAtomically() async throws {
        let m3u = try Data(contentsOf: vectorURL("m3u/valid_basic.m3u"))
        let epgXML = try Data(contentsOf: vectorURL("xmltv/epg_basic.xml"))
        let fail = LockedFlag()
        let transport = FakeTransport { request in
            if fail.value { return HTTPResponse(statusCode: 500) }
            if request.url.path.hasSuffix(".xml") { return HTTPResponse(statusCode: 200, body: epgXML) }
            return HTTPResponse(statusCode: 200, body: m3u)
        }
        let sources = SourceRepository(database: database, secureStore: InMemorySecureStore())
        let epg = EpgRepository(database: database)
        let refresher = SourceRefresher(database: database, sources: sources, catalog: catalog, epg: epg,
                                        transport: transport, retryPolicy: .none, sleeper: .immediate)
        let secrets = SourceSecrets.m3u(M3USecrets(url: "http://lists.example.com/list.m3u", epgUrl: "http://lists.example.com/epg.xml"))
        let source = Source.make(name: "Test", secrets: secrets)
        try sources.save(source, secrets: secrets)
        let now = ISO8601DateFormatter().date(from: "2025-10-04T16:00:00Z")!
        let refreshed = try await refresher.refresh(sourceId: source.id, now: now)
        let counts = try catalog.counts(sourceId: source.id)
        XCTAssertGreaterThan(counts.channels, 0)
        XCTAssertEqual(refreshed.lastRefreshResult?.liveCount, counts.channels)
        XCTAssertGreaterThan(try epg.programCount(sourceId: source.id), 0)
        XCTAssertNotNil(refreshed.lastRefreshResult?.epgProgramCount)

        // A failing refresh keeps the content and records the error.
        fail.value = true
        do {
            _ = try await refresher.refresh(sourceId: source.id, now: now)
            XCTFail("expected error")
        } catch let error as SourceError {
            XCTAssertEqual(error, .serverError(httpStatus: 500))
        }
        XCTAssertEqual(try catalog.counts(sourceId: source.id), counts)
        XCTAssertEqual(try sources.source(id: source.id)?.lastRefreshResult?.error, .serverError(httpStatus: 500))
    }

    func testEpgCanLoadSeparatelyInBackground() async throws {
        let m3u = try Data(contentsOf: vectorURL("m3u/valid_basic.m3u"))
        let epgXML = try Data(contentsOf: vectorURL("xmltv/epg_basic.xml"))
        let transport = FakeTransport { request in
            HTTPResponse(statusCode: 200, body: request.url.path.hasSuffix(".xml") ? epgXML : m3u)
        }
        let sources = SourceRepository(database: database, secureStore: InMemorySecureStore())
        let epg = EpgRepository(database: database)
        let refresher = SourceRefresher(database: database, sources: sources, catalog: catalog, epg: epg,
                                        transport: transport, retryPolicy: .none, sleeper: .immediate)
        let secrets = SourceSecrets.m3u(M3USecrets(url: "http://lists.example.com/list.m3u", epgUrl: "http://lists.example.com/epg.xml"))
        let source = Source.make(name: "Test", secrets: secrets)
        try sources.save(source, secrets: secrets)
        let now = ISO8601DateFormatter().date(from: "2025-10-04T16:00:00Z")!
        _ = try await refresher.refresh(sourceId: source.id, now: now, includeEpg: false)
        XCTAssertEqual(try epg.programCount(sourceId: source.id), 0)
        XCTAssertFalse(transport.requests.contains { $0.url.path.hasSuffix(".xml") })
        let count = await refresher.refreshEpg(sourceId: source.id, now: now)
        XCTAssertGreaterThan(count ?? 0, 0)
        XCTAssertEqual(try sources.source(id: source.id)?.lastRefreshResult?.epgProgramCount, count)
    }

    func testRefresherReportsInvalidFormat() async throws {
        let transport = FakeTransport { _ in HTTPResponse(statusCode: 200, body: Data("<html><body>Not found</body></html>".utf8)) }
        let sources = SourceRepository(database: database, secureStore: InMemorySecureStore())
        let refresher = SourceRefresher(database: database, sources: sources, catalog: catalog, epg: EpgRepository(database: database),
                                        transport: transport, retryPolicy: .none, sleeper: .immediate)
        let secrets = SourceSecrets.m3u(M3USecrets(url: "http://x.example.com/a.m3u"))
        let source = Source.make(name: "X", secrets: secrets)
        try sources.save(source, secrets: secrets)
        do {
            _ = try await refresher.refresh(sourceId: source.id)
            XCTFail("expected error")
        } catch let error as SourceError {
            XCTAssertEqual(error, .invalidFormat)
        }
    }
}

final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = false
    var value: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _value }
        set { lock.lock(); _value = newValue; lock.unlock() }
    }
}
