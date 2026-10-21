import Foundation
import IPTVCore
import XCTest
@testable import IPTVKit

/// CONTRACT §11: TMDB lookups are best effort – nil on 503 / offline / no backend, with a quiet period so a
/// grid never hammers a backend that cannot answer; answers are cached and concurrent lookups shared.
final class MetadataServiceTests: XCTestCase {
    private let base = URL(string: "https://api.example.com")!

    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var value = Date(timeIntervalSince1970: 1_000_000)
        var now: Date { lock.withLock { value } }
        func advance(_ s: TimeInterval) { lock.withLock { value += s } }
    }

    private static func json(_ s: String, status: Int = 200) -> HTTPResponse {
        HTTPResponse(statusCode: status, headers: ["Content-Type": "application/json"], body: Data(s.utf8))
    }

    private static let match = #"{"parsed":{"title":"Inception","year":2010},"match":{"tmdbId":27205,"type":"movie","title":"Inception","posterUrl":"https://image.tmdb.org/t/p/w500/a.jpg","voteCount":1},"confidence":0.9}"#
    private static let details = #"{"tmdbId":27205,"type":"movie","title":"Inception","overview":"Ein Dieb …","voteCount":1,"genres":[],"cast":[]}"#

    private func service(_ transport: FakeTransport, clock: Clock = Clock()) -> MetadataService {
        MetadataService(backend: BackendClient(baseURL: base, transport: transport), now: { clock.now })
    }

    func testMatchThenDetailsAndCache() async {
        let t = FakeTransport { r in r.url.path.hasSuffix("/match") ? Self.json(Self.match) : Self.json(Self.details) }
        let s = service(t)
        let lookup = MetadataService.Lookup(name: "DE | Inception (2010)", type: .movie, year: 2010)
        let first = await s.details(lookup, language: .de)
        XCTAssertEqual(first?.overview, "Ein Dieb …")
        _ = await s.details(lookup, language: .de)
        let poster = await s.match(lookup, language: .de)
        XCTAssertEqual(poster?.posterUrl, "https://image.tmdb.org/t/p/w500/a.jpg")
        XCTAssertEqual(t.requests.count, 2)   // one match + one details, the rest from memory
    }

    func testProviderTmdbIdSkipsMatching() async {
        let t = FakeTransport { _ in Self.json(Self.details) }
        let result = await service(t).details(.init(name: "whatever", type: .movie, tmdbId: 27205), language: .en)
        XCTAssertEqual(result?.tmdbId, 27205)
        XCTAssertEqual(t.requests.map(\.url.path), ["/v1/metadata/27205"])
    }

    func testNoMatchIsCachedToo() async {
        let t = FakeTransport { _ in Self.json(#"{"parsed":{"title":"xyz"},"match":null,"confidence":0.2}"#) }
        let s = service(t)
        let a = await s.details(.init(name: "xyz", type: .tv), language: .en)
        let b = await s.details(.init(name: "xyz", type: .tv), language: .en)
        XCTAssertNil(a)
        XCTAssertNil(b)
        XCTAssertEqual(t.requests.count, 1)
    }

    func testUnavailablePausesForRetryAfter() async {
        let clock = Clock()
        let up = MetadataUpFlag()
        let t = FakeTransport { _ in
            up.value ? Self.json(Self.match)
                     : Self.json(#"{"error":"metadata_unavailable","message":"down","retryAfter":60}"#, status: 503)
        }
        let s = service(t, clock: clock)
        let lookup = MetadataService.Lookup(name: "Inception", type: .movie)
        let failed = await s.match(lookup, language: .en)
        XCTAssertNil(failed)
        let paused = await s.isPaused
        XCTAssertTrue(paused)
        up.value = true
        let quiet = await s.match(lookup, language: .en)
        XCTAssertNil(quiet)                                  // still paused: no request
        XCTAssertEqual(t.requests.count, 1)
        clock.advance(61)
        let back = await s.match(lookup, language: .en)
        XCTAssertEqual(back?.tmdbId, 27205)                  // the failure was not cached
        XCTAssertEqual(t.requests.count, 2)
    }

    func testUnconfiguredBackendPausesLong() async {
        let clock = Clock()
        let t = FakeTransport { _ in Self.json(#"{"error":"metadata_unavailable","message":"not configured"}"#, status: 503) }
        let s = service(t, clock: clock)
        _ = await s.match(.init(name: "a", type: .movie), language: .en)
        clock.advance(MetadataService.unconfiguredBackoff - 1)
        let stillPaused = await s.isPaused
        XCTAssertTrue(stillPaused)
        clock.advance(2)
        let resumed = await s.isPaused
        XCTAssertFalse(resumed)
    }

    func testOfflinePausesShortly() async {
        let clock = Clock()
        let t = FakeTransport { _ in throw URLError(.notConnectedToInternet) }
        let s = service(t, clock: clock)
        let result = await s.details(.init(name: "a", type: .movie), language: .en)
        XCTAssertNil(result)
        let paused = await s.isPaused
        XCTAssertTrue(paused)
        clock.advance(MetadataService.transientBackoff + 1)
        let resumed = await s.isPaused
        XCTAssertFalse(resumed)
    }

    func testWithoutBackendEverythingIsNil() async {
        let s = MetadataService(backend: nil)
        let result = await s.details(.init(name: "Inception", type: .movie, tmdbId: 27205), language: .en)
        XCTAssertNil(result)
    }

    func testConcurrentLookupsShareOneRequest() async {
        let t = FakeTransport { _ in Thread.sleep(forTimeInterval: 0.05); return Self.json(Self.match) }
        let s = service(t)
        let lookup = MetadataService.Lookup(name: "Inception", type: .movie)
        async let a = s.match(lookup, language: .en)
        async let b = s.match(lookup, language: .en)
        let (ra, rb) = await (a, b)
        XCTAssertEqual(ra?.tmdbId, 27205)
        XCTAssertEqual(rb?.tmdbId, 27205)
        XCTAssertEqual(t.requests.count, 1)
    }
}

private final class MetadataUpFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = false
    var value: Bool {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }
}
