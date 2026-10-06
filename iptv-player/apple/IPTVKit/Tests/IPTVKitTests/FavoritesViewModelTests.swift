import XCTest
@testable import IPTVKit
import IPTVCore

/// Favorites in the live grid (favorites first, favorite categories next) and the Favorites
/// screen's device-local reordering (SCREENS §3.3, §3.6).
@MainActor
final class FavoritesViewModelTests: XCTestCase {
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

    private func favorite(_ env: AppEnvironment, _ channel: Channel) {
        env.toggleFavorite(sourceId: channel.sourceId, kind: .live, itemId: channel.id, title: channel.name, posterUrl: nil)
    }

    func testLiveListShowsFavoritesFirstAndChipCounts() async throws {
        let env = try await makeEnvironment()
        let model = LiveTVViewModel(env: env)
        model.showsFavoriteSections = true
        model.reload()
        XCTAssertTrue(model.favoriteRows.isEmpty)
        XCTAssertEqual(model.favoriteCount, 0)
        XCTAssertEqual(model.allCount, model.totalCount)
        let category = try XCTUnwrap(model.categories.first)
        let inCategory = try env.catalog.channelCount(sourceId: XCTUnwrap(env.currentSource?.id), categoryId: category.id)
        XCTAssertEqual(model.categoryCounts[category.id], inCategory, "chip count = category membership")
        let last = try XCTUnwrap(model.rows.last?.channel)
        let first = try XCTUnwrap(model.rows.first?.channel)

        favorite(env, last)
        favorite(env, first)
        model.reloadFavorites()
        XCTAssertEqual(model.favoriteRows.map(\.channel.id), [first.id, last.id], "newest first")
        XCTAssertEqual(model.favoriteCount, 2)
        XCTAssertEqual(model.rows.count, model.totalCount, "the paged rest stays")

        model.filter = .category(category.id)
        XCTAssertTrue(model.favoriteRows.isEmpty, "favorites section only in All")
        XCTAssertEqual(model.favoriteCount, 2, "chip count stays")
        model.filter = .favorites
        XCTAssertEqual(model.rows.map(\.channel.id), [first.id, last.id], "Favorites filter: the favorites as rows")
    }

    func testFavoritesScreenMoveKeepsOrderOnDevice() async throws {
        let env = try await makeEnvironment()
        let channels = try XCTUnwrap(env.catalog.channels(sourceId: XCTUnwrap(env.currentSource?.id), limit: 3))
        XCTAssertEqual(channels.count, 3)
        for channel in channels { favorite(env, channel) }
        let model = FavoritesViewModel(env: env)
        model.reload()
        XCTAssertEqual(model.channels.map(\.id), channels.reversed().map(\.id), "newest first")

        model.move(from: IndexSet(integer: 2), to: 0)
        let expected = [channels[0].id, channels[2].id, channels[1].id]
        XCTAssertEqual(model.channels.map(\.id), expected, "instant")
        let fresh = FavoritesViewModel(env: env)
        fresh.reload()
        XCTAssertEqual(fresh.channels.map(\.id), expected, "persisted")
    }
}
