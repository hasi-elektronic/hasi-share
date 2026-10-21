import IPTVCore
import IPTVKit
import XCTest
@testable import NovaPlayer

/// Build 17 × 18: a `novaplayer://` link (Top Shelf, reminder) into locked content goes `Router.open` → `Router.play`
/// and asks for the parental PIN – it never plays silently and is not silently ignored; after the PIN it plays.
/// (A UI test cannot keep the PIN across `XCUIApplication.open`, which relaunches the in-memory UI-test app.)
@MainActor
final class DeepLinkParentalTests: XCTestCase {
    private struct StaticTransport: HTTPTransport {
        let body: Data
        func send(_ request: HTTPRequest) async throws -> HTTPResponse { HTTPResponse(statusCode: 200, body: body) }
    }

    private static let m3u = """
    #EXTM3U
    #EXTINF:-1 tvg-id="a" group-title="News",Atlas News HD
    http://stream.example.com/live/u/p/1.m3u8
    #EXTINF:-1 tvg-id="c" group-title="Kids",Kids Planet
    http://stream.example.com/live/u/p/3.m3u8
    #EXTINF:-1 group-title="Action",Red Horizon (2024) HD
    http://stream.example.com/movie/u/p/10.mp4
    """

    private var suiteName = ""

    override func tearDown() async throws {
        UserDefaults().removePersistentDomain(forName: suiteName)
    }

    private func makeEnv() async throws -> AppEnvironment {
        suiteName = "deeplink-parental-\(UUID().uuidString)"
        let config = AppConfig(displayName: "Test", bundleId: "de.hasielektronik.novaplayer", appVersion: "1.0",
                               backendBaseURL: URL(string: "http://127.0.0.1:9")!, productIDs: ProductIDs(lifetime: "l", trial: "t"),
                               licenseKeysJSON: Data("{}".utf8), platform: .ios, rawDeviceId: "device", deviceName: "Test")
        let env = try AppEnvironment(config: config, database: AppDatabase.inMemory(), secureStore: InMemorySecureStore(),
                                     kv: InMemoryKeyValueStore(), settings: AppSettings(defaults: UserDefaults(suiteName: suiteName)!),
                                     transport: StaticTransport(body: Data(Self.m3u.utf8)))
        _ = try await env.addSource(name: "Demo", secrets: .m3u(M3USecrets(url: "http://lists.example.com/u/p/list.m3u"))) { _ in }
        // An active trial: playback itself is allowed (the paywall is not what stops the link).
        env.license.update(store: StoreSnapshot(trialStartMs: env.license.nowMs() - 2 * 86_400_000, trialTransactionId: nil))
        return env
    }

    func testDeepLinkIntoLockedContentAsksForThePin() async throws {
        let env = try await makeEnv()
        let router = Router(env: env)
        let sid = try XCTUnwrap(env.currentSource?.id)
        let channels = try env.catalog.channels(sourceId: sid, limit: 10)
        let kids = try XCTUnwrap(channels.first { $0.name == "Kids Planet" })
        let atlas = try XCTUnwrap(channels.first { $0.name == "Atlas News HD" })
        let movie = try XCTUnwrap(env.catalog.movies(sourceId: sid, limit: 5).first)
        let kidsCategory = try XCTUnwrap(env.catalog.allCategories(sourceId: sid, kind: .live).first { $0.name == "Kids" }?.id)
        let action = try XCTUnwrap(env.catalog.allCategories(sourceId: sid, kind: .movie).first { $0.name == "Action" }?.id)
        XCTAssertTrue(env.parental.setPin("1234"))
        env.parental.setCategoryLocked(true, categoryId: kidsCategory, kind: .live, sourceId: sid)
        env.parental.setCategoryLocked(true, categoryId: action, kind: .movie, sourceId: sid)
        env.parental.relock()

        for link in [DeepLink.channel(sourceId: sid, channelId: kids.id), .movie(sourceId: sid, movieId: movie.id)] {
            XCTAssertTrue(router.open(link.url), "\(link) is handled, not ignored")
            XCTAssertNotNil(env.parental.prompt, "\(link) asks for the PIN")
            XCTAssertFalse(router.playerPresented, "\(link) does not play before the PIN")
            XCTAssertNil(env.player.request)
            env.parental.cancelPrompt()
        }

        // A wrong PIN keeps it closed; the right one plays the linked channel.
        XCTAssertTrue(router.open(DeepLink.channel(sourceId: sid, channelId: kids.id).url))
        XCTAssertEqual(env.parental.answerPrompt("0000"), .wrong(remaining: 4))
        XCTAssertNotNil(env.parental.prompt)
        XCTAssertFalse(router.playerPresented)
        XCTAssertEqual(env.parental.answerPrompt("1234"), .ok)
        env.parental.promptDismissed()   // the pad finished dismissing
        XCTAssertTrue(router.playerPresented, "plays after the PIN")
        guard case .channel(let playing)? = env.player.request?.item else { return XCTFail("channel request") }
        XCTAssertEqual(playing.id, kids.id)
        router.closePlayer()

        // An unlocked channel plays at once (no prompt) once the session is locked again.
        env.parental.relock()
        XCTAssertTrue(router.open(DeepLink.channel(sourceId: sid, channelId: atlas.id).url))
        XCTAssertNil(env.parental.prompt)
        XCTAssertTrue(router.playerPresented)
        router.closePlayer()
    }
}
