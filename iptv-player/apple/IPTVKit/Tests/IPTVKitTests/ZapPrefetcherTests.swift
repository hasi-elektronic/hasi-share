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
    func channels(_ n: Int) -> [Channel] { (0..<n).map { TestData.channel(id: "c\($0)", url: "http://live.example.com/c\($0)") } }

    private func hlsResolver(_ container: StreamContainer = .hls) -> @MainActor (PlaybackRequest) async throws -> ResolvedStream {
        { req in
            guard case .channel(let c) = req.item else { throw CancellationError() }
            return ResolvedStream(url: URL(string: "http://h/\(c.id).m3u8")!, container: container, headers: [:])
        }
    }

    private func xtreamSource(maxConnections: Int?) -> Source {
        var s = Source.make(name: "P", secrets: .xtream(XtreamSecrets(serverUrl: "http://panel.example.com", username: "u", password: "p")), id: "s1")
        s.xtreamAccount = XtreamAccountInfo(status: "Active", expiresAt: nil, maxConnections: maxConnections, activeConnections: 0,
                                            allowedOutputFormats: [], serverTimezone: "UTC")
        return s
    }

    /// Prefetches around c1 of 3 with `source`; returns (#fetches, resolved neighbour present).
    private func run(container: StreamContainer = .hls, source: Source?, channels list: [Channel]) async throws -> (Int, Bool) {
        let fetcher = CountingFetcher()
        let p = ZapPrefetcher(resolver: hlsResolver(container), fetcher: fetcher, network: Net(isExpensiveOrConstrained: false))
        p.prefetch(around: list[1], request: PlaybackRequest(item: .channel(list[1]), source: source, channels: list))
        try await Task.sleep(for: .milliseconds(100))
        return (fetcher.urls.count, p.takeResolved(channelId: "c2") != nil)
    }

    func testByteReadOnlyForHLS() async throws {
        let (hls, _) = try await run(source: nil, channels: channels(3))
        XCTAssertEqual(hls, 2)
        for container in [StreamContainer.mpegts, .mp4, .mkv, .unknown] {
            let (fetches, resolved) = try await run(container: container, source: nil, channels: channels(3))
            XCTAssertEqual(fetches, 0, "\(container): resolve-only")
            XCTAssertTrue(resolved, "\(container): still resolved")
        }
    }

    func testXtreamByteReadNeedsMoreThanOneConnection() async throws {
        let xt = (0..<3).map { TestData.channel(id: "c\($0)") }   // Xtream channels have no URL of their own
        for (max, want) in [(nil, 0), (0, 0), (1, 0), (2, 2), (5, 2)] as [(Int?, Int)] {
            let (fetches, resolved) = try await run(source: xtreamSource(maxConnections: max), channels: xt)
            XCTAssertEqual(fetches, want, "max_connections=\(String(describing: max))")
            XCTAssertTrue(resolved)
        }
        // Source unknown + channel without URL = Xtream with unknown account → no read.
        let (unknown, _) = try await run(source: nil, channels: xt)
        XCTAssertEqual(unknown, 0)
        // A neighbour from another source is not described by the request's source: Xtream channel → no read.
        let other = (0..<3).map { Channel(sourceId: "s2", id: "c\($0)", name: "X") }
        let (foreign, _) = try await run(source: xtreamSource(maxConnections: 5), channels: other)
        XCTAssertEqual(foreign, 0)
        // M3U source is not gated.
        let m3u = Source.make(name: "M", secrets: .m3u(M3USecrets(url: "http://x.example.com/l.m3u")), id: "s1")
        let (m3uFetches, _) = try await run(source: m3u, channels: channels(3))
        XCTAssertEqual(m3uFetches, 2)
    }

    private final class Clock: @unchecked Sendable {
        private let lock = NSLock(); private var t = Date(timeIntervalSince1970: 1_000)
        var date: Date { lock.withLock { t } }
        func advance(_ s: TimeInterval) { lock.withLock { t += s } }
    }

    func testCachedResolutionExpiresAfterTTL() async throws {
        let list = channels(3); let clock = Clock()
        let p = ZapPrefetcher(resolver: hlsResolver(), fetcher: CountingFetcher(), network: Net(isExpensiveOrConstrained: false),
                              now: { clock.date })
        let request = PlaybackRequest(item: .channel(list[1]), source: nil, channels: list)
        p.prefetch(around: list[1], request: request)
        try await Task.sleep(for: .milliseconds(80))
        clock.advance(89)
        XCTAssertNotNil(p.takeResolved(channelId: "c0"), "still fresh at 89 s")
        clock.advance(2)
        XCTAssertNil(p.takeResolved(channelId: "c2"), "stale after 90 s → resolve again")
        XCTAssertNil(p.takeResolved(channelId: "c2"))
    }

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

    func testOpeningUncachedChannelCancelsOldPrefetchImmediately() async throws {
        let (c, av, fetcher) = make(CallCounter())
        let channels = list()
        c.open(PlaybackRequest(item: .channel(channels[1]), source: nil, channels: channels))
        try await settle(av.loads.count == 1)
        av.emit(.playing)
        try await settle(fetcher.urls.count == 2)
        c.open(PlaybackRequest(item: .channel(channels[3]), source: nil, channels: channels))   // not warmed
        XCTAssertNil(c.prefetcher?.takeResolved(channelId: "c0"), "old prefetch dropped at open, before the new stream loads")
        XCTAssertNil(c.prefetcher?.takeResolved(channelId: "c2"))
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
