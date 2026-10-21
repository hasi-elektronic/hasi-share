import XCTest
@testable import IPTVKit
import IPTVCore

/// Parental lock filtering (Build 18, SCREENS §3.10): locked categories / channels never leak into lists, search,
/// home rows, continue watching or number zapping while locked; hide vs show-with-lock; unlock shows everything.
@MainActor
final class ContentLockTests: XCTestCase {
    nonisolated static let m3u = """
    #EXTM3U
    #EXTINF:-1 tvg-id="news.1" tvg-chno="1" group-title="News",Atlas News
    http://p.tv/live/news1.m3u8
    #EXTINF:-1 tvg-id="news.2" tvg-chno="2" group-title="News",Rhein News
    http://p.tv/live/news2.m3u8
    #EXTINF:-1 tvg-id="xxx.1" tvg-chno="3" group-title="XXX Adult",Velvet Night
    http://p.tv/live/xxx1.m3u8
    #EXTINF:-1 tvg-id="xxx.2" tvg-chno="4" group-title="XXX Adult",Velvet Two
    http://p.tv/live/xxx2.m3u8
    #EXTINF:-1 tvg-id="kids.1" tvg-chno="5" group-title="Kids",Kids Planet
    http://p.tv/live/kids1.m3u8
    #EXTINF:-1 group-title="Action",Harbor Line (2024)
    http://p.tv/movie/harbor.mp4
    #EXTINF:-1 group-title="Erotik",Velvet Movie (2023)
    http://p.tv/movie/velvet.mp4
    #EXTINF:-1 group-title="Drama",Harbor Lights S01E01 Pilot
    http://p.tv/series/lights101.mp4
    #EXTINF:-1 group-title="Adult Series",Velvet Stories S01E01 First
    http://p.tv/series/velvet101.mp4
    """

    private func makeEnvironment(kv: InMemoryKeyValueStore = InMemoryKeyValueStore()) async throws -> AppEnvironment {
        let config = AppConfig(displayName: "Test", bundleId: "de.hasielektronik.novaplayer", appVersion: "1.0",
                               backendBaseURL: URL(string: "http://127.0.0.1:9")!, productIDs: ProductIDs(lifetime: "l", trial: "t"),
                               licenseKeysJSON: TestSigner().jwkSetJSON, platform: .ios, rawDeviceId: "device", deviceName: "Test")
        let transport = FakeTransport { request in
            request.url.path.hasSuffix(".m3u") ? HTTPResponse(statusCode: 200, body: Data(Self.m3u.utf8)) : HTTPResponse(statusCode: 404)
        }
        let env = try AppEnvironment(config: config, database: AppDatabase.inMemory(), secureStore: InMemorySecureStore(), kv: kv,
                                     transport: transport)
        _ = try await env.addSource(name: "Demo", secrets: .m3u(M3USecrets(url: "http://p.tv/list.m3u"))) { _ in }
        return env
    }

    private func category(_ env: AppEnvironment, _ kind: CategoryKind, _ name: String) throws -> IPTVCore.Category {
        try XCTUnwrap(env.catalog.allCategories(sourceId: env.currentSource!.id, kind: kind).first { $0.name == name })
    }

    /// PIN set, adult categories + one channel locked, session locked again.
    private func lockAdult(_ env: AppEnvironment, hide: Bool = true) throws {
        let sid = try XCTUnwrap(env.currentSource?.id)
        env.parental.setPin("1234")
        env.parental.hideLocked = hide
        env.parental.setCategoryLocked(true, categoryId: try category(env, .live, "XXX Adult").id, kind: .live, sourceId: sid)
        env.parental.setCategoryLocked(true, categoryId: try category(env, .movie, "Erotik").id, kind: .movie, sourceId: sid)
        env.parental.setCategoryLocked(true, categoryId: try category(env, .series, "Adult Series").id, kind: .series, sourceId: sid)
        let kids = try XCTUnwrap(env.catalog.channels(sourceId: sid, limit: 50).first { $0.name == "Kids Planet" })
        env.parental.setChannelLocked(true, channelId: kids.id, sourceId: sid)
        env.parental.relock()
    }

    func testListsAndLookupsLeaveOutLockedContent() async throws {
        let env = try await makeEnvironment()
        let sid = try XCTUnwrap(env.currentSource?.id)
        let before = env.catalogVersion
        let allBefore = try env.catalog.channels(sourceId: sid, limit: 50)
        XCTAssertEqual(allBefore.count, 5)
        let velvet = try XCTUnwrap(allBefore.first { $0.name == "Velvet Night" })
        let velvetMovie = try XCTUnwrap(env.catalog.movies(sourceId: sid, limit: 10).first { $0.name.hasPrefix("Velvet") })
        try lockAdult(env)
        XCTAssertGreaterThan(env.catalogVersion, before, "screens reload")

        XCTAssertEqual(try env.catalog.channels(sourceId: sid, limit: 50).map(\.name), ["Atlas News", "Rhein News"])
        XCTAssertEqual(try env.catalog.channelCount(sourceId: sid), 2)
        XCTAssertFalse(try env.catalog.categories(sourceId: sid, kind: .live).contains { $0.name == "XXX Adult" }, "hidden category")
        XCTAssertTrue(try env.catalog.channels(sourceId: sid, categoryId: velvet.categoryId, limit: 50).isEmpty)
        XCTAssertEqual(try env.catalog.channelCount(sourceId: sid, categoryId: velvet.categoryId), 0)
        XCTAssertNil(try env.catalog.channel(sourceId: sid, id: velvet.id))
        XCTAssertTrue(try env.catalog.channels(sourceId: sid, ids: [velvet.id]).isEmpty)
        XCTAssertTrue(try env.catalog.channels(sourceId: sid, epgIds: ["xxx.1"]).isEmpty, "programme search resolution")
        XCTAssertNil(try env.catalog.channelForNumberZap(sourceId: sid, number: 3), "number zap")
        XCTAssertNil(try env.catalog.channelForNumberZap(sourceId: sid, number: 5), "individually locked channel (hide mode)")

        XCTAssertEqual(try env.catalog.movies(sourceId: sid, limit: 10).map(\.name), ["Harbor Line (2024)"])
        XCTAssertNil(try env.catalog.movie(sourceId: sid, id: velvetMovie.id))
        XCTAssertTrue(try env.catalog.movies(sourceId: sid, ids: [velvetMovie.id]).isEmpty)
        XCTAssertFalse(try env.catalog.categoryInfos(sourceId: sid, kind: .movie).contains { $0.category.name == "Erotik" })
        XCTAssertEqual(try env.catalog.series(sourceId: sid, limit: 10).map(\.name), ["Harbor Lights"])

        // Unlock: everything is back.
        XCTAssertEqual(env.parental.unlock("1234"), .ok)
        XCTAssertEqual(try env.catalog.channels(sourceId: sid, limit: 50).count, 5)
        XCTAssertNotNil(try env.catalog.movie(sourceId: sid, id: velvetMovie.id))
        env.parental.relock()
        XCTAssertNil(try env.catalog.movie(sourceId: sid, id: velvetMovie.id))
    }

    func testShowModeListsLockedCategoriesAndChannelsButNoContentOfThem() async throws {
        let env = try await makeEnvironment()
        let sid = try XCTUnwrap(env.currentSource?.id)
        try lockAdult(env, hide: false)
        XCTAssertTrue(try env.catalog.categories(sourceId: sid, kind: .live).contains { $0.name == "XXX Adult" }, "listed with a lock")
        XCTAssertTrue(env.parental.needsPin(categoryId: try category(env, .live, "XXX Adult").id, kind: .live, sourceId: sid))
        XCTAssertEqual(try env.catalog.channels(sourceId: sid, limit: 50).map(\.name), ["Atlas News", "Rhein News", "Kids Planet"],
                       "the individually locked channel stays listed (with a lock), the adult category's channels do not")
        let kids = try XCTUnwrap(env.catalog.channels(sourceId: sid, limit: 50).last)
        XCTAssertTrue(env.parental.needsPin(channel: kids), "playing it needs the PIN")
        XCTAssertNil(try env.catalog.channelForNumberZap(sourceId: sid, number: 5), "number zapping never reaches it without the PIN")
        XCTAssertTrue(try env.catalog.channels(sourceId: sid, categoryId: try category(env, .live, "XXX Adult").id, limit: 50).isEmpty,
                      "the locked category opens empty until the PIN is entered")
    }

    func testSearchNeverShowsLockedTitles() async throws {
        let env = try await makeEnvironment()
        try lockAdult(env)
        let model = SearchViewModel(env: env)
        let engine = model.makeEngine()
        XCTAssertTrue(engine.suppressSuggestions, "typing suggestions are raw titles")
        let results = try engine.overview("velvet", infos: [])
        XCTAssertTrue(results.channels.isEmpty)
        XCTAssertTrue(results.movies.isEmpty)
        XCTAssertTrue(results.series.isEmpty)
        let harbor = try engine.overview("harbor", infos: [])
        XCTAssertEqual(harbor.movies.count, 1, "unlocked titles still found")
        XCTAssertEqual(harbor.series.count, 1)
    }

    func testHomeRowsAndContinueWatchingRespectLocks() async throws {
        let env = try await makeEnvironment()
        let sid = try XCTUnwrap(env.currentSource?.id)
        let velvetMovie = try XCTUnwrap(env.catalog.movies(sourceId: sid, limit: 10).first { $0.name.hasPrefix("Velvet") })
        let harbor = try XCTUnwrap(env.catalog.movies(sourceId: sid, limit: 10).first { $0.name.hasPrefix("Harbor") })
        let velvetSeries = try XCTUnwrap(env.catalog.series(sourceId: sid, limit: 10).first { $0.name.hasPrefix("Velvet") })
        let episode = try XCTUnwrap(env.catalog.episodes(sourceId: sid, seriesId: velvetSeries.id).first)
        for (i, movie) in [velvetMovie, harbor].enumerated() {
            let key = try XCTUnwrap(env.contentKey(sourceId: sid, kind: .movie, itemId: movie.id))
            try env.library.saveProgress(contentKey: key, title: movie.name, kind: .movie, positionMs: 600_000, durationMs: 5_400_000,
                                         posterUrl: movie.posterUrl, nowMs: Int64(1_000 + i))
        }
        let episodeKey = try XCTUnwrap(env.contentKey(sourceId: sid, kind: .episode, itemId: episode.id))
        try env.library.saveProgress(contentKey: episodeKey, title: "Velvet Stories · S1E1 First", kind: .episode, positionMs: 600_000,
                                     durationMs: 2_400_000, posterUrl: nil,
                                     seriesKey: env.contentKey(sourceId: sid, kind: .series, itemId: velvetSeries.id), nowMs: 2_000)
        let home = HomeViewModel(env: env)
        home.reload()
        XCTAssertEqual(home.continueWatching.count, 3)
        try lockAdult(env)
        home.reload()
        XCTAssertEqual(home.continueWatching.map(\.data.title), ["Harbor Line (2024)"], "locked movie and episode left out")
        XCTAssertEqual(home.newMovies.map(\.name), ["Harbor Line (2024)"])
        XCTAssertFalse(home.newSeries.contains { $0.name.hasPrefix("Velvet") })
    }

    func testLiveViewModelChipsAndRows() async throws {
        let env = try await makeEnvironment()
        try lockAdult(env)
        let model = LiveTVViewModel(env: env)
        model.reload()
        XCTAssertEqual(model.rows.map(\.channel.name), ["Atlas News", "Rhein News"])
        XCTAssertFalse(model.categories.contains { $0.name == "XXX Adult" })
    }

    func testStoredFilterIgnoresTheSessionUnlock() async throws {
        // Top Shelf / anything written for another process must use the stored locks, not the unlocked session.
        let env = try await makeEnvironment()
        let sid = try XCTUnwrap(env.currentSource?.id)
        try lockAdult(env)
        env.parental.unlock("1234")
        XCTAssertNil(env.parental.filter)
        let velvetMovie = try XCTUnwrap(env.catalog.movies(sourceId: sid, limit: 10).first { $0.name.hasPrefix("Velvet") })
        XCTAssertTrue(env.catalog.isLocked(sourceId: sid, kind: .movie, itemId: velvetMovie.id, filter: env.parental.storedFilter))
        XCTAssertFalse(env.catalog.isLocked(sourceId: sid, kind: .movie, itemId: velvetMovie.id), "no active filter")
    }

    func testDeletingTheSourceForgetsItsLocks() async throws {
        let env = try await makeEnvironment()
        let sid = try XCTUnwrap(env.currentSource?.id)
        try lockAdult(env)
        env.deleteSource(id: sid)
        XCTAssertTrue(env.parental.lockedCategoryIds(sourceId: sid, kind: .live).isEmpty)
        XCTAssertTrue(env.parental.lockedChannelIds(sourceId: sid).isEmpty)
    }
}
