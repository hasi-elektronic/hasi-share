import XCTest
@testable import IPTVKit
import IPTVCore

/// Series detail "Continue SxEy" (SCREENS §3.5, QA B-03 / IOS-07): the progress of the episodes is read once
/// per load / library change (not per render, audit P2) and follows playback while the detail stays open.
@MainActor
final class SeriesDetailViewModelTests: XCTestCase {
    private func makeEnvironment() async throws -> AppEnvironment {
        let m3u = try Data(contentsOf: vectorURL("m3u/valid_basic.m3u"))
        let transport = FakeTransport { _ in HTTPResponse(statusCode: 200, body: m3u) }
        let config = AppConfig(displayName: "Test", bundleId: "de.hasielektronik.novaplayer", appVersion: "1.0",
                               backendBaseURL: URL(string: "http://127.0.0.1:9")!, productIDs: ProductIDs(lifetime: "l", trial: "t"),
                               licenseKeysJSON: TestSigner().jwkSetJSON, platform: .ios, rawDeviceId: "device", deviceName: "Test")
        let env = try AppEnvironment(config: config, database: AppDatabase.inMemory(), secureStore: InMemorySecureStore(),
                                     kv: InMemoryKeyValueStore(), transport: transport)
        _ = try await env.addSource(name: "Test", secrets: .m3u(M3USecrets(url: "http://lists.example.com/list.m3u"))) { _ in }
        return env
    }

    /// A series of the source with three known episodes (S1E1, S1E2, S2E1).
    private func seriesWithEpisodes(_ env: AppEnvironment) throws -> (Series, [Episode]) {
        let sid = try XCTUnwrap(env.currentSource?.id)
        let series = try XCTUnwrap(env.catalog.series(sourceId: sid, limit: 1).first)
        let episodes = [(1, 1), (1, 2), (2, 1)].map { season, number in
            Episode(sourceId: sid, id: "ep\(season)\(number)", seriesId: series.id, season: season, number: number,
                    title: "Episode \(number)", url: "http://cdn.example.com/\(season)/\(number).mp4")
        }
        try env.catalog.replaceEpisodes(sourceId: sid, seriesId: series.id, episodes: episodes)
        return (series, episodes)
    }

    private func saveProgress(_ env: AppEnvironment, _ episode: Episode, positionMs: Int64, durationMs: Int64, nowMs: Int64) throws {
        let key = try XCTUnwrap(env.contentKey(sourceId: episode.sourceId, kind: .episode, itemId: episode.id))
        try env.library.saveProgress(contentKey: key, title: episode.title, kind: .episode, positionMs: positionMs,
                                     durationMs: durationMs, posterUrl: nil, nowMs: nowMs)
    }

    func testContinueEpisodeFollowsProgressSavedWhileTheDetailIsOpen() async throws {
        let env = try await makeEnvironment()
        let (series, episodes) = try seriesWithEpisodes(env)
        let model = SeriesDetailViewModel(env: env, series: series)
        await model.load()
        XCTAssertNil(model.continueEpisode, "nothing watched yet")
        XCTAssertNil(model.progress(of: episodes[2]))

        // Played S2E1 for 12 s (well under 5 %) while the detail page stayed in the navigation stack.
        try saveProgress(env, episodes[2], positionMs: 12_000, durationMs: 2_400_000, nowMs: 1_000)
        model.reloadProgress()
        XCTAssertEqual(model.continueEpisode?.id, "ep21", "the last watched episode, also under 5 %")
        XCTAssertEqual(model.progress(of: episodes[2])?.data.positionMs, 12_000)

        // Finished S1E1 later: the next one is offered.
        try saveProgress(env, episodes[0], positionMs: 2_390_000, durationMs: 2_400_000, nowMs: 2_000)
        model.reloadProgress()
        XCTAssertEqual(model.continueEpisode?.id, "ep12", "completed → the following episode")
    }

    func testLoadReadsTheProgressOnce() async throws {
        let env = try await makeEnvironment()
        let (series, episodes) = try seriesWithEpisodes(env)
        try saveProgress(env, episodes[1], positionMs: 600_000, durationMs: 2_400_000, nowMs: 1_000)
        let model = SeriesDetailViewModel(env: env, series: series)
        await model.load()
        XCTAssertEqual(model.continueEpisode?.id, "ep12")
        XCTAssertEqual(model.season, 1, "the season of the episode to continue")
        XCTAssertEqual(model.progress(of: episodes[1])?.data.fraction ?? 0, 0.25, accuracy: 0.001)
    }
}
