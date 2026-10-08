import XCTest
@testable import IPTVKit
import IPTVCore

/// Live list now/next (SCREENS §3.3, QA audit B10): the rows' programmes follow the clock while the screen stays
/// open (Apple TV keeps the Live tab on screen for hours), not only when a page is loaded.
@MainActor
final class LiveNowNextRefreshTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

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

    func testRefreshMovesNowAndNextWithTheClock() async throws {
        let env = try await makeEnvironment()
        let sid = try XCTUnwrap(env.currentSource?.id)
        let session = try env.epg.beginRefresh(sourceId: sid)
        try session.write([
            EpgProgram(sourceId: sid, channelEpgId: "trt1.tr", start: t0.addingTimeInterval(-600), end: t0.addingTimeInterval(600), title: "Morning"),
            EpgProgram(sourceId: sid, channelEpgId: "trt1.tr", start: t0.addingTimeInterval(600), end: t0.addingTimeInterval(1800), title: "News"),
            EpgProgram(sourceId: sid, channelEpgId: "trt1.tr", start: t0.addingTimeInterval(1800), end: t0.addingTimeInterval(3600), title: "Film"),
        ])
        try session.commit()
        let model = LiveTVViewModel(env: env)
        model.showsFavoriteSections = true
        model.reload()
        let trt = { model.rows.first { $0.channel.epgId == "trt1.tr" } }
        XCTAssertNotNil(trt())

        model.refreshNowNext(at: t0)
        XCTAssertEqual(trt()?.nowNext?.now?.title, "Morning")
        XCTAssertEqual(trt()?.nowNext?.next?.title, "News")

        model.refreshNowNext(at: t0.addingTimeInterval(900))
        XCTAssertEqual(trt()?.nowNext?.now?.title, "News", "15 min later the next programme is on air")
        XCTAssertEqual(trt()?.nowNext?.next?.title, "Film")
        XCTAssertEqual(model.rows.count, model.totalCount, "the loaded rows stay")
    }
}
