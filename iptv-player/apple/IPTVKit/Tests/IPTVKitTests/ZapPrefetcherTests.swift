import XCTest
@testable import IPTVKit
import IPTVCore

private final class CountingFetcher: PrefetchFetcher, @unchecked Sendable {
    let lock = NSLock(); var urls: [URL] = []; var maxBytesSeen: [Int] = []; var inFlight = 0; var peak = 0
    func fetch(_ url: URL, headers: [String: String], maxBytes: Int) async throws -> Int {
        lock.withLock { urls.append(url); maxBytesSeen.append(maxBytes); inFlight += 1; peak = max(peak, inFlight) }
        try await Task.sleep(for: .milliseconds(20))
        lock.withLock { inFlight -= 1 }
        return maxBytes
    }
}
private struct Net: NetworkConditions { var isExpensiveOrConstrained: Bool }

@MainActor
final class ZapPrefetcherTests: XCTestCase {
    func channels(_ n: Int) -> [Channel] { (0..<n).map { TestData.channel(id: "c\($0)") } }

    func testNeighboursWrapAround() {
        let list = channels(3)
        XCTAssertEqual(ZapPrefetcher.neighbours(of: list[0], in: list).map(\.id), ["c2", "c1"])
        XCTAssertEqual(ZapPrefetcher.neighbours(of: list[1], in: list).map(\.id), ["c0", "c2"])
        XCTAssertEqual(ZapPrefetcher.neighbours(of: list[0], in: [list[0]]).map(\.id), [])
    }

    func testPrefetchResolvesAndFetchesWithinLimits() async throws {
        let list = channels(5)
        let fetcher = CountingFetcher()
        let p = ZapPrefetcher(resolver: { req in
            guard case .channel(let c) = req.item else { throw CancellationError() }
            return ResolvedStream(url: URL(string: "http://h/\(c.id).m3u8")!, container: .hls, headers: [:])
        }, fetcher: fetcher, network: Net(isExpensiveOrConstrained: false))
        p.prefetch(around: list[2], request: PlaybackRequest(item: .channel(list[2]), source: nil, channels: list))
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(Set(fetcher.urls.map(\.lastPathComponent)), ["c1.m3u8", "c3.m3u8"])
        XCTAssertTrue(fetcher.maxBytesSeen.allSatisfy { $0 <= 262_144 })
        XCTAssertLessThanOrEqual(fetcher.peak, 2)
        XCTAssertEqual(p.takeResolved(channelId: "c3")?.url.lastPathComponent, "c3.m3u8")
        XCTAssertNil(p.takeResolved(channelId: "c3"), "consumed once")
    }

    func testDisabledOnExpensiveNetwork() async throws {
        let list = channels(3); let fetcher = CountingFetcher()
        let p = ZapPrefetcher(resolver: { _ in ResolvedStream(url: URL(string: "http://h/x")!, container: .hls, headers: [:]) },
                              fetcher: fetcher, network: Net(isExpensiveOrConstrained: true))
        p.prefetch(around: list[1], request: PlaybackRequest(item: .channel(list[1]), source: nil, channels: list))
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(fetcher.urls.isEmpty)
        XCTAssertNil(p.takeResolved(channelId: "c2"))
    }

    func testCancelAllDropsResolvedAndInFlightWork() async throws {
        let list = channels(3); let fetcher = CountingFetcher()
        let p = ZapPrefetcher(resolver: { req in
            try await Task.sleep(for: .milliseconds(50))
            guard case .channel(let c) = req.item else { throw CancellationError() }
            return ResolvedStream(url: URL(string: "http://h/\(c.id).m3u8")!, container: .hls, headers: [:])
        }, fetcher: fetcher, network: Net(isExpensiveOrConstrained: false))
        p.prefetch(around: list[1], request: PlaybackRequest(item: .channel(list[1]), source: nil, channels: list))
        p.cancelAll()
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertTrue(fetcher.urls.isEmpty, "cancelled before resolving finished")
        XCTAssertNil(p.takeResolved(channelId: "c0"))
        XCTAssertNil(p.takeResolved(channelId: "c2"))
    }
}

private final class CallCounter: @unchecked Sendable {
    private let lock = NSLock(); private var n = 0
    func hit() { lock.withLock { n += 1 } }
    var count: Int { lock.withLock { n } }
}

@MainActor
final class PlayerControllerPrefetchTests: XCTestCase {
    /// Unknown-container URLs make the resolver call the sniffer, so `sniffed.count` counts resolver runs.
    private func make(_ sniffed: CallCounter, fetcher: CountingFetcher = CountingFetcher(),
                      network: Bool = false) -> (PlayerController, FakeEngine, CountingFetcher) {
        let av = FakeEngine(kind: .avPlayer)
        let sniffer: StreamResolver.Sniffer = { _, _ in sniffed.hit(); return ("application/vnd.apple.mpegurl", nil, 200) }
        let c = PlayerController(resolver: StreamResolver(secrets: { _ in nil }, sniffer: sniffer), library: nil,
                                 engines: PlaybackEngines(avPlayer: { av }, vlc: nil))
        c.prefetcher = ZapPrefetcher(resolver: { req in
            guard case .channel(let ch) = req.item else { throw CancellationError() }
            return ResolvedStream(url: URL(string: "http://prefetched.example.com/\(ch.id).m3u8")!, container: .hls, headers: [:])
        }, fetcher: fetcher, network: Net(isExpensiveOrConstrained: network))
        return (c, av, fetcher)
    }

    private func list() -> [Channel] { (0..<4).map { TestData.channel(id: "c\($0)", url: "http://live.example.com/play?id=\($0)") } }

    private func settle(_ cond: @autoclosure () -> Bool) async throws {
        for _ in 0..<200 where !cond() { try await Task.sleep(for: .milliseconds(5)) }
    }

    func testZapUsesPrefetchedResolutionWithoutResolving() async throws {
        let sniffed = CallCounter()
        let (c, av, fetcher) = make(sniffed)
        let channels = list()
        c.open(PlaybackRequest(item: .channel(channels[1]), source: nil, channels: channels))
        try await settle(av.loads.count == 1)
        XCTAssertEqual(sniffed.count, 1)
        av.emit(.playing)
        try await settle(fetcher.urls.count == 2)
        XCTAssertEqual(Set(fetcher.urls.map(\.lastPathComponent)), ["c0.m3u8", "c2.m3u8"])

        c.open(PlaybackRequest(item: .channel(channels[2]), source: nil, channels: channels))
        try await settle(av.loads.count == 2)
        XCTAssertEqual(av.loads.last?.url.absoluteString, "http://prefetched.example.com/c2.m3u8", "prefetched stream is loaded")
        XCTAssertEqual(sniffed.count, 1, "resolver not called again for the warmed-up neighbour")
        XCTAssertEqual(c.stream?.url.lastPathComponent, "c2.m3u8")

        // Not warmed up (c3 is no neighbour of c1) → normal resolver path.
        c.open(PlaybackRequest(item: .channel(channels[3]), source: nil, channels: channels))
        try await settle(av.loads.count == 3)
        XCTAssertEqual(sniffed.count, 2)
        XCTAssertEqual(av.loads.last?.url.absoluteString, "http://live.example.com/play?id=3")
    }

    func testNoPrefetchBeforeFirstFrameOrOnExpensiveNetwork() async throws {
        let sniffed = CallCounter()
        let (c, av, fetcher) = make(sniffed)
        let channels = list()
        c.open(PlaybackRequest(item: .channel(channels[1]), source: nil, channels: channels))
        try await settle(av.loads.count == 1)
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertTrue(fetcher.urls.isEmpty, "prefetch starts after the first frame")

        let (c2, av2, fetcher2) = make(CallCounter(), network: true)
        c2.open(PlaybackRequest(item: .channel(channels[1]), source: nil, channels: channels))
        try await settle(av2.loads.count == 1)
        av2.emit(.playing)
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertTrue(fetcher2.urls.isEmpty)
    }

    func testReleaseCancelsPrefetch() async throws {
        let (c, av, fetcher) = make(CallCounter())
        let channels = list()
        c.open(PlaybackRequest(item: .channel(channels[1]), source: nil, channels: channels))
        try await settle(av.loads.count == 1)
        av.emit(.playing)
        try await settle(fetcher.urls.count == 2)
        c.release()   // scene left .active
        XCTAssertNil(c.prefetcher?.takeResolved(channelId: "c0"))
        XCTAssertNil(c.prefetcher?.takeResolved(channelId: "c2"))
    }
}
