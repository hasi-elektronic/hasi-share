import XCTest
@testable import IPTVKit

final class QuickStartTests: XCTestCase {
    let s = LastSession(sourceId: "s", channelId: "c", endedInPlayer: true)
    func testPlaysLastChannelWhenAllowed() {
        XCTAssertEqual(QuickStart.decide(enabled: true, last: s, canPlay: true, channelExists: true), .play(sourceId: "s", channelId: "c"))
    }
    func testNoneCases() {
        XCTAssertEqual(QuickStart.decide(enabled: false, last: s, canPlay: true, channelExists: true), .none)
        XCTAssertEqual(QuickStart.decide(enabled: true, last: nil, canPlay: true, channelExists: true), .none)
        XCTAssertEqual(QuickStart.decide(enabled: true, last: s, canPlay: false, channelExists: true), .none)
        XCTAssertEqual(QuickStart.decide(enabled: true, last: s, canPlay: true, channelExists: false), .none)
        var left = s; left.endedInPlayer = false
        XCTAssertEqual(QuickStart.decide(enabled: true, last: left, canPlay: true, channelExists: true), .none)
    }
}

@MainActor
final class LastSessionRecordingTests: XCTestCase {
    private func make() -> (PlayerController, FakeEngine, () -> [LastSession?]) {
        let av = FakeEngine(kind: .avPlayer)
        let sniffer: StreamResolver.Sniffer = { _, _ in ("application/vnd.apple.mpegurl", nil, 200) }
        let c = PlayerController(resolver: StreamResolver(secrets: { _ in nil }, sniffer: sniffer), library: nil,
                                 engines: PlaybackEngines(avPlayer: { av }, vlc: nil))
        var events: [LastSession?] = []
        c.onLastSessionChange = { events.append($0) }
        return (c, av, { events })
    }

    private func settle(_ cond: @autoclosure () -> Bool) async throws {
        for _ in 0..<200 where !cond() { try await Task.sleep(for: .milliseconds(5)) }
    }

    private let channel = TestData.channel(id: "c1", url: "http://live.example.com/play?id=1")

    func testRecordsLiveChannelWhenPlayingAndKeepsItAcrossRelease() async throws {
        let (c, av, events) = make()
        c.open(PlaybackRequest(item: .channel(channel), source: nil, channels: [channel]))
        try await settle(av.loads.count == 1)
        XCTAssertTrue(events().isEmpty, "nothing recorded before the first frame")
        av.emit(.playing)
        XCTAssertEqual(events(), [LastSession(sourceId: "s1", channelId: "c1", endedInPlayer: true)])
        c.release()                 // app backgrounded / terminated while playing
        av.emit(.playing)           // resumed
        XCTAssertEqual(events().count, 1, "release / resume leave the record untouched (still endedInPlayer)")
    }

    func testClosingThePlayerClearsEndedInPlayer() async throws {
        let (c, av, events) = make()
        c.open(PlaybackRequest(item: .channel(channel), source: nil, channels: [channel]))
        try await settle(av.loads.count == 1)
        av.emit(.playing)
        c.close()
        c.close()
        XCTAssertEqual(events(), [LastSession(sourceId: "s1", channelId: "c1", endedInPlayer: true),
                                  LastSession(sourceId: "s1", channelId: "c1", endedInPlayer: false)])
    }

    func testOpeningVODClearsTheRecord() async throws {
        let (c, av, events) = make()
        c.open(PlaybackRequest(item: .channel(channel), source: nil, channels: [channel]))
        try await settle(av.loads.count == 1)
        av.emit(.playing)
        c.open(PlaybackRequest(item: .url("http://a.example.com/x.m3u8", title: "x"), source: nil))
        XCTAssertEqual(events().count, 2)
        if case .some(.some) = events().last { XCTFail("VOD playback must clear the last live session") }
        XCTAssertNotNil(events().first ?? nil)
    }
}

@MainActor
final class QuickStartSettingsTests: XCTestCase {
    func testDefaultsAndPersistence() {
        let suite = UserDefaults(suiteName: "quickstart-\(UUID().uuidString)")!
        let a = AppSettings(defaults: suite)
        XCTAssertTrue(a.quickStart, "on by default")
        XCTAssertNil(a.lastSession)
        a.quickStart = false
        a.lastSession = LastSession(sourceId: "s", channelId: "c", endedInPlayer: true)
        let b = AppSettings(defaults: suite)
        XCTAssertFalse(b.quickStart)
        XCTAssertEqual(b.lastSession, LastSession(sourceId: "s", channelId: "c", endedInPlayer: true))
        b.lastSession = nil
        XCTAssertNil(AppSettings(defaults: suite).lastSession)
    }
}
