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

final class NumberZapTargetTests: XCTestCase {
    private let channels = [
        Channel(sourceId: "s", id: "a", name: "A", number: 101),
        Channel(sourceId: "s", id: "b", name: "B", number: 7),
        Channel(sourceId: "s", id: "c", name: "C"),
    ]

    func testChannelNumberWins() {
        XCTAssertEqual(NumberZap.channel(number: 7, in: channels)?.id, "b")
        XCTAssertEqual(NumberZap.channel(number: 101, in: channels)?.id, "a")
    }

    func testFallsBackToOneBasedIndex() {
        XCTAssertEqual(NumberZap.channel(number: 3, in: channels)?.id, "c")
        XCTAssertEqual(NumberZap.channel(number: 1, in: channels)?.id, "a")
        XCTAssertNil(NumberZap.channel(number: 4, in: channels))
        XCTAssertNil(NumberZap.channel(number: 0, in: channels))
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
