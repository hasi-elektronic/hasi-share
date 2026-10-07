import IPTVCore
import XCTest
@testable import IPTVKit

final class NumberZapTests: XCTestCase {
    func testCollectsDigitsAndCommitsAfterTimeout() {
        var z = NumberZap()
        XCTAssertEqual(z.input(1, atMs: 0), "1")
        XCTAssertEqual(z.input(2, atMs: 800), "12")
        XCTAssertNil(z.commitIfDue(atMs: 2000))
        XCTAssertEqual(z.commitIfDue(atMs: 2300), 12)
        XCTAssertNil(z.commitIfDue(atMs: 5000))
    }

    func testMaxFourDigits() {
        var z = NumberZap()
        for (i, d) in [1, 2, 3, 4, 5].enumerated() { _ = z.input(d, atMs: Int64(i * 100)) }
        XCTAssertEqual(z.commitIfDue(atMs: 2000), 1234)
    }
}

/// Number zap target (SCREENS §3.7): the whole source catalog by number (indexed); the 1-based
/// position only for sources without any channel numbers.
final class NumberZapTargetTests: XCTestCase {
    private func catalog(_ channels: [Channel]) throws -> (AppDatabase, CatalogRepository) {
        let db = try AppDatabase.inMemory()
        let repo = CatalogRepository(database: db)
        let session = try repo.beginRefresh(sourceId: "s")
        try session.write(channels: channels)
        try session.commit()
        return (db, repo)
    }

    private let numbered = [
        Channel(sourceId: "s", id: "a", name: "A", number: 101, categoryId: "news", sort: 0),
        Channel(sourceId: "s", id: "b", name: "B", number: 7, categoryId: "news", sort: 1),
        Channel(sourceId: "s", id: "c", name: "C", number: 12, categoryId: "sport", sort: 2),
        Channel(sourceId: "s", id: "d", name: "D", categoryId: "sport", sort: 3),
    ]

    func testNumberedSourceTunesByNumber() throws {
        let (_, repo) = try catalog(numbered)
        XCTAssertEqual(try repo.channelForNumberZap(sourceId: "s", number: 7)?.id, "b")
        XCTAssertEqual(try repo.channelForNumberZap(sourceId: "s", number: 101)?.id, "a")
    }

    func testNumberInAnotherCategoryIsFound() throws {
        let (_, repo) = try catalog(numbered)
        XCTAssertEqual(try repo.channelForNumberZap(sourceId: "s", number: 12)?.id, "c", "not limited to the zap list's category")
    }

    func testMissingNumberInNumberedSourceIsNil() throws {
        let (_, repo) = try catalog(numbered)
        XCTAssertNil(try repo.channelForNumberZap(sourceId: "s", number: 3), "no index fallback when the playlist is numbered")
        XCTAssertNil(try repo.channelForNumberZap(sourceId: "s", number: 1))
    }

    func testUnnumberedSourceUsesPosition() throws {
        let (_, repo) = try catalog((0..<5).map { Channel(sourceId: "s", id: "x\($0)", name: "X\($0)", sort: $0) })
        XCTAssertEqual(try repo.channelForNumberZap(sourceId: "s", number: 1)?.id, "x0")
        XCTAssertEqual(try repo.channelForNumberZap(sourceId: "s", number: 5)?.id, "x4")
        XCTAssertNil(try repo.channelForNumberZap(sourceId: "s", number: 6))
        XCTAssertNil(try repo.channelForNumberZap(sourceId: "s", number: 0))
    }

    func testNumberLookupUsesTheIndex() throws {
        let (db, _) = try catalog(numbered)
        let plan = try db.db.query("EXPLAIN QUERY PLAN SELECT id FROM channels WHERE source_id = ? AND number = ?",
                                   [.text("s"), .int(7)]) { $0.string(3) }.joined()
        XCTAssertTrue(plan.contains("channels_number"), plan)
    }
}

@MainActor
final class PanelZapTests: XCTestCase {
    /// In-player channel panel: zapping to a channel of another category makes that list the zap list.
    func testZapWithNewListReplacesZapList() async throws {
        let first = (0..<3).map { Channel(sourceId: "s", id: "a\($0)", name: "A\($0)", url: "http://a.example.com/a\($0).mkv") }
        let other = (0..<3).map { Channel(sourceId: "s", id: "b\($0)", name: "B\($0)", url: "http://a.example.com/b\($0).mkv") }
        let controller = PlayerController(resolver: StreamResolver(secrets: { _ in nil }, sniffer: nil), library: nil)
        controller.open(PlaybackRequest(item: .channel(first[0]), source: nil, channels: first))
        controller.zap(to: other[1], channels: other)
        XCTAssertEqual(controller.request?.channels.map(\.id), other.map(\.id))
        try await Task.sleep(for: .milliseconds(PlayerController.zapDebounceMs + 250))
        XCTAssertEqual(controller.currentChannel?.id, "b1")
        controller.zap(by: 1)
        XCTAssertEqual(controller.zapTarget?.id, "b2", "▲▼ continue in the panel's list")
    }

    /// Choosing the playing channel in another category of the panel: no reopen, that list becomes the zap list.
    func testSetZapListKeepsTheStream() async throws {
        let list = (0..<3).map { Channel(sourceId: "s", id: "a\($0)", name: "A\($0)", url: "http://a.example.com/a\($0).mkv") }
        let other = [Channel(sourceId: "s", id: "z", name: "Z", url: "http://a.example.com/z.mkv"), list[0]]
        let controller = PlayerController(resolver: StreamResolver(secrets: { _ in nil }, sniffer: nil), library: nil)
        controller.open(PlaybackRequest(item: .channel(list[0]), source: nil, channels: list))
        controller.setZapList(other)
        XCTAssertEqual(controller.request?.channels.map(\.id), ["z", "a0"])
        XCTAssertEqual(controller.currentChannel?.id, "a0")
        XCTAssertNil(controller.zapTarget, "no zap")
        controller.zap(by: -1)
        XCTAssertEqual(controller.zapTarget?.id, "z")
    }
}

/// "Recently watched channels" (Home, SCREENS §3.2): a live channel that started playing is a progress
/// item with positionMs 0 (CONTRACT §8), once per opening, newest first.
@MainActor
final class LiveHistoryTests: XCTestCase {
    func testPlayingLiveChannelIsRecordedOnce() async throws {
        let library = LibraryRepository(database: try AppDatabase.inMemory())
        let engine = FakeEngine(kind: .avPlayer)
        let c = PlayerController(resolver: StreamResolver(secrets: { _ in nil }, sniffer: nil, vlcAvailable: true),
                                 library: library, engines: PlaybackEngines(avPlayer: { engine }, vlc: nil))
        var changes = 0
        c.onLibraryChange = { changes += 1 }
        let channel = Channel(sourceId: "s1", id: "c9", name: "News", url: "http://h.example.com/news.m3u8")
        var request = PlaybackRequest(item: .channel(channel), source: nil, channels: [channel])
        request.sourceFingerprint = "fp"
        c.open(request)
        for _ in 0..<200 where engine.loads.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        engine.emit(.playing)
        engine.emit(.buffering)
        engine.emit(.playing)
        let key = ContentKey.make(fingerprint: "fp", kind: .live, itemId: "c9")
        let saved = try XCTUnwrap(try library.progress(contentKey: key))
        XCTAssertEqual(saved.data.contentKind, .live)
        XCTAssertEqual(saved.data.positionMs, 0)
        XCTAssertEqual(saved.data.title, "News")
        XCTAssertEqual(changes, 1, "recorded once per opening, not on every resume")
        let recent = WatchHistory.recentlyWatched(try library.progressItems(), kind: .live)
        XCTAssertEqual(recent.map(\.contentKey), [key])
    }
}

/// In-player channel panel data load (SCREENS §3.7, budget ≤ 100 ms) on a 50 000-channel source:
/// no chip counts, the playing channel's category, the channel paged in.
@MainActor
final class PanelLoadPerformanceTests: XCTestCase {
    #if DEBUG
    let factor = 2.0
    #else
    let factor = 1.0
    #endif

    func testPanelOpenUnderBudget() async throws {
        var m3u = "#EXTM3U\n"
        for i in 0..<CatalogPerformanceTests.n {
            m3u += "#EXTINF:-1 tvg-id=\"e\(i)\" tvg-chno=\"\(i + 1)\" group-title=\"Group \(i % 50)\",Kanal \(i)\nhttp://h.example.com/\(i).ts\n"
        }
        let body = Data(m3u.utf8)
        let transport = FakeTransport { _ in HTTPResponse(statusCode: 200, body: body) }
        let config = AppConfig(displayName: "Test", bundleId: "de.hasielektronik.novaplayer", appVersion: "1.0",
                               backendBaseURL: URL(string: "http://127.0.0.1:9")!, productIDs: ProductIDs(lifetime: "l", trial: "t"),
                               licenseKeysJSON: TestSigner().jwkSetJSON, platform: .ios, rawDeviceId: "device", deviceName: "Test")
        let env = try AppEnvironment(config: config, database: AppDatabase.inMemory(), secureStore: InMemorySecureStore(),
                                     kv: InMemoryKeyValueStore(), transport: transport)
        _ = try await env.addSource(name: "Big", secrets: .m3u(M3USecrets(url: "http://lists.example.com/big.m3u"))) { _ in }
        let sid = try XCTUnwrap(env.currentSource?.id)
        // Deep in its category (row ~500 of 1000).
        let playing = try XCTUnwrap(env.catalog.channelForNumberZap(sourceId: sid, number: 25_008))
        XCTAssertNotNil(playing.categoryId)

        var times: [Double] = []
        var model = LiveTVViewModel(env: env)
        for _ in 0..<6 {
            model = LiveTVViewModel(env: env)
            model.showsFavoriteSections = true
            model.loadsCategoryCounts = false
            let start = DispatchTime.now()
            let found = model.open(on: playing)
            times.append(Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1e6)
            XCTAssertTrue(found, "playing channel paged in")
        }
        let median = times.dropFirst().sorted()[2]
        print("PERF panel open (50k, category, reveal): median \(String(format: "%.2f", median)) ms (budget 100, factor \(factor))")
        XCTAssertEqual(model.filter, .category(try XCTUnwrap(playing.categoryId)))
        XCTAssertTrue(model.categoryCounts.isEmpty, "no chip counts in the panel")
        XCTAssertLessThan(median, 100 * factor)
    }
}
