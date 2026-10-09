import Foundation
import IPTVCore
import XCTest
@testable import IPTVKit

/// B1: Xtream episodes in "Continue watching" survive catalog refreshes and resolve without a cached episode row
/// (synced progress); B7: series detail error state / revalidation; P2: progress in one query.
@MainActor
final class ContinueWatchingTests: XCTestCase {
    /// Fake Xtream panel from the shared vectors; `get_series_info` can be switched to fail.
    final class Panel: @unchecked Sendable {
        private let lock = NSLock()
        private var _seriesInfoFails = false
        private var _seriesInfoCalls = 0
        var seriesInfoFails: Bool {
            get { lock.withLock { _seriesInfoFails } }
            set { lock.withLock { _seriesInfoFails = newValue } }
        }
        var seriesInfoCalls: Int { lock.withLock { _seriesInfoCalls } }

        func transport() throws -> FakeTransport {
            let bodies: [String: Data] = [
                "": try Data(contentsOf: vectorURL("xtream/auth_ok.json")),
                "get_live_categories": try Data(contentsOf: vectorURL("xtream/live_categories.json")),
                "get_vod_categories": Data("[]".utf8), "get_series_categories": try Data(contentsOf: vectorURL("xtream/series_categories.json")),
                "get_live_streams": try Data(contentsOf: vectorURL("xtream/live_streams.json")),
                "get_vod_streams": Data("[]".utf8), "get_series": try Data(contentsOf: vectorURL("xtream/series.json")),
                "get_series_info": try Data(contentsOf: vectorURL("xtream/series_info.json")),
            ]
            return FakeTransport { [self] request in
                let action = URLComponents(url: request.url, resolvingAgainstBaseURL: false)?
                    .queryItems?.first(where: { $0.name == "action" })?.value ?? ""
                if action == "get_series_info" {
                    let fails = lock.withLock { _seriesInfoCalls += 1; return _seriesInfoFails }
                    if fails { return HTTPResponse(statusCode: 404) }   // not retried (fast test)
                }
                guard let data = bodies[action] else { return HTTPResponse(statusCode: 404) }
                return HTTPResponse(statusCode: 200, body: data)
            }
        }
    }

    private func makeEnvironment(_ panel: Panel) async throws -> AppEnvironment {
        let config = AppConfig(displayName: "Test", bundleId: "de.hasielektronik.novaplayer", appVersion: "1.0",
                               backendBaseURL: URL(string: "http://127.0.0.1:9")!, productIDs: ProductIDs(lifetime: "l", trial: "t"),
                               licenseKeysJSON: TestSigner().jwkSetJSON, platform: .ios, rawDeviceId: "device", deviceName: "Test")
        let env = try AppEnvironment(config: config, database: AppDatabase.inMemory(), secureStore: InMemorySecureStore(),
                                     kv: InMemoryKeyValueStore(), transport: try panel.transport())
        _ = try await env.addSource(name: "Panel", secrets: .xtream(XtreamSecrets(serverUrl: "http://panel.example.com:8080",
                                                                                  username: "demo", password: "demo"))) { _ in }
        return env
    }

    private func source(_ env: AppEnvironment) throws -> Source { try XCTUnwrap(env.currentSource) }

    func testXtreamEpisodeStaysInContinueWatchingAcrossRefresh() async throws {
        let panel = Panel()
        let env = try await makeEnvironment(panel)
        let sid = try source(env).id
        let series = try XCTUnwrap(env.catalog.seriesItem(sourceId: sid, id: "7000"))
        let detail = SeriesDetailViewModel(env: env, series: series)
        await detail.load()
        let episode = try XCTUnwrap(detail.episodes.first { $0.id == "70001" })
        let request = env.request(for: .episode(episode, seriesTitle: series.name))
        let key = try XCTUnwrap(request.contentKey)
        try env.library.saveProgress(contentKey: key, title: request.title, kind: .episode, positionMs: 600_000, durationMs: 3_480_000,
                                     posterUrl: episode.posterUrl, seriesKey: env.contentKey(sourceId: sid, kind: .series, itemId: series.id),
                                     nowMs: 1_000)

        let error = await env.refreshSource(id: sid)
        XCTAssertNil(error)
        XCTAssertFalse(try env.catalog.episodes(sourceId: sid, seriesId: series.id).isEmpty, "cached episodes survive the refresh")

        let home = HomeViewModel(env: env)
        home.reload()
        let progress = try XCTUnwrap(home.continueWatching.first)
        guard case .episode(let resolved, let seriesTitle)? = home.item(for: progress) else { return XCTFail("episode expected") }
        XCTAssertEqual(resolved.id, "70001")
        XCTAssertEqual(resolved.containerExt, "mkv")
        XCTAssertEqual(seriesTitle, series.name)
    }

    func testSyncedEpisodeProgressWithoutEpisodeRowResolvesAndPlays() async throws {
        let panel = Panel()
        let env = try await makeEnvironment(panel)
        let sid = try source(env).id
        let fingerprint = try XCTUnwrap(env.fingerprint(sourceId: sid))
        // Progress from another device; this device never opened the series.
        let synced = SyncItem.progress(contentKey: ContentKey.make(fingerprint: fingerprint, kind: .episode, itemId: "70002"),
                                       title: "Breaking Bad · S1E2 Cat's in the Bag...", contentKind: .episode,
                                       positionMs: 300_000, durationMs: 3_000_000, posterUrl: "http://img.example.com/p.jpg",
                                       seriesKey: ContentKey.make(fingerprint: fingerprint, kind: .series, itemId: "7000"), updatedAt: 5_000)
        try env.library.merge([synced])
        XCTAssertTrue(try env.catalog.episodes(sourceId: sid, seriesId: "7000").isEmpty)

        let home = HomeViewModel(env: env)
        home.reload()
        let progress = try XCTUnwrap(home.continueWatching.first)
        guard case .episode(let placeholder, let seriesTitle)? = home.item(for: progress) else { return XCTFail("episode expected") }
        XCTAssertEqual(placeholder.id, "70002")
        XCTAssertEqual(placeholder.seriesId, "7000")
        XCTAssertEqual(placeholder.season, 1)
        XCTAssertEqual(placeholder.number, 2)
        XCTAssertEqual(placeholder.title, "Cat's in the Bag...")
        XCTAssertEqual(seriesTitle, "Breaking Bad")
        XCTAssertNil(placeholder.containerExt)

        let playable = await env.playableEpisode(placeholder)
        XCTAssertEqual(playable.containerExt, "mp4", "completed lazily via get_series_info")
        XCTAssertEqual(panel.seriesInfoCalls, 1)
        let again = await env.playableEpisode(placeholder)
        XCTAssertEqual(again.containerExt, "mp4")
        XCTAssertEqual(panel.seriesInfoCalls, 1, "stored row, no second fetch")
    }

    func testM3UStagedEpisodesReplaceAndRemovedSeriesLoseTheirEpisodes() throws {
        let database = try AppDatabase.inMemory()
        let catalog = CatalogRepository(database: database)
        let first = try catalog.beginRefresh(sourceId: "m")
        try first.write(series: [Series(sourceId: "m", id: "a", name: "A"), Series(sourceId: "m", id: "b", name: "B")],
                        episodes: [Episode(sourceId: "m", id: "a1", seriesId: "a", season: 1, number: 1, title: "x"),
                                   Episode(sourceId: "m", id: "b1", seriesId: "b", season: 1, number: 1, title: "y")])
        try first.commit()
        let second = try catalog.beginRefresh(sourceId: "m")
        try second.write(series: [Series(sourceId: "m", id: "a", name: "A")],
                         episodes: [Episode(sourceId: "m", id: "a2", seriesId: "a", season: 1, number: 2, title: "z")])
        try second.commit()
        XCTAssertEqual(try catalog.episodes(sourceId: "m", seriesId: "a").map(\.id), ["a2"], "staged episodes replace the series' old ones")
        XCTAssertTrue(try catalog.episodes(sourceId: "m", seriesId: "b").isEmpty, "series left the catalog")
    }

    func testSeriesDetailErrorStateRetryAndRevalidation() async throws {
        let panel = Panel()
        let env = try await makeEnvironment(panel)
        let sid = try source(env).id
        let series = try XCTUnwrap(env.catalog.seriesItem(sourceId: sid, id: "7000"))

        panel.seriesInfoFails = true
        let failing = SeriesDetailViewModel(env: env, series: series)
        await failing.load()
        XCTAssertNotNil(failing.loadError, "no cache + failed fetch = error state (not an empty page)")
        XCTAssertTrue(failing.episodes.isEmpty)
        panel.seriesInfoFails = false
        await failing.retry()
        XCTAssertNil(failing.loadError)
        XCTAssertFalse(failing.episodes.isEmpty)
        XCTAssertEqual(failing.details?.genre, "Drama, Crime")
        XCTAssertEqual(failing.details?.director, "Vince Gilligan")

        // Fresh cache: shown, no request. Stale cache: shown and refetched; a failure then keeps the cache.
        let calls = panel.seriesInfoCalls
        let fresh = SeriesDetailViewModel(env: env, series: series)
        await fresh.load()
        XCTAssertEqual(panel.seriesInfoCalls, calls)
        XCTAssertFalse(fresh.episodes.isEmpty)
        XCTAssertEqual(fresh.details?.genre, "Drama, Crime", "cached details at once")
        panel.seriesInfoFails = true
        let stale = SeriesDetailViewModel(env: env, series: series, now: { Date().addingTimeInterval(ItemDetails.ttl + 60) })
        await stale.load()
        XCTAssertEqual(panel.seriesInfoCalls, calls + 1, "revalidated after the TTL")
        XCTAssertNil(stale.loadError, "a failed revalidation keeps the cached page")
        XCTAssertFalse(stale.episodes.isEmpty)
    }

    func testSeriesDetailProgressInOneQueryAndContinueEpisode() async throws {
        let panel = Panel()
        let env = try await makeEnvironment(panel)
        let sid = try source(env).id
        let series = try XCTUnwrap(env.catalog.seriesItem(sourceId: sid, id: "7000"))
        let model = SeriesDetailViewModel(env: env, series: series)
        await model.load()
        let last = try XCTUnwrap(model.episodes.last)
        let key = try XCTUnwrap(env.contentKey(sourceId: sid, kind: .episode, itemId: last.id))
        try env.library.saveProgress(contentKey: key, title: "t", kind: .episode, positionMs: 60_000, durationMs: 3_000_000,
                                     posterUrl: nil, nowMs: 9_000)
        XCTAssertNil(model.progress(of: last), "cached until reloaded")
        model.reloadProgress()
        XCTAssertEqual(model.progress(of: last)?.data.positionMs, 60_000)
        XCTAssertEqual(model.continueEpisode?.id, last.id, "the last watched episode, also under 5 %")
        let fresh = SeriesDetailViewModel(env: env, series: series)
        await fresh.load()
        XCTAssertEqual(fresh.season, last.season, "opens on the season of the episode to continue")
    }

    func testEpisodeTitleParse() {
        let parsed = EpisodeTitle.parse("Kızılcık Şerbeti · S12E345 Bölüm 345")
        XCTAssertEqual(parsed.seriesTitle, "Kızılcık Şerbeti")
        XCTAssertEqual(parsed.season, 12)
        XCTAssertEqual(parsed.number, 345)
        XCTAssertEqual(parsed.episodeTitle, "Bölüm 345")
        XCTAssertNil(EpisodeTitle.parse("Just a title").season)
    }
}
