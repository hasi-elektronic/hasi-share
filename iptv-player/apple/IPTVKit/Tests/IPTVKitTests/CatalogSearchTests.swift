import XCTest
@testable import IPTVKit
import IPTVCore

/// Search must return hits of every content kind (live, movie, series), not only the best-ranked ones
/// overall: on a big Xtream catalog movies used to fill the whole global LIMIT (user report, build 6).
final class CatalogSearchTests: XCTestCase {
    private func makeRepo(movies: Int = 0, channels: [String] = [], series: Int = 0,
                          movieTitle: (Int) -> String = { "Sport \($0)" },
                          seriesTitle: (Int) -> String = { "Sport Serie \($0) Staffel" }) throws -> CatalogRepository {
        let repo = CatalogRepository(database: try AppDatabase.inMemory())
        let session = try repo.beginRefresh(sourceId: "s")
        try session.write(
            channels: channels.enumerated().map { TestData.channel(id: "c\($0.offset)", sourceId: "s", name: $0.element, sort: $0.offset) },
            movies: (0..<movies).map { Movie(sourceId: "s", id: "m\($0)", name: movieTitle($0), sort: $0) },
            series: (0..<series).map { Series(sourceId: "s", id: "t\($0)", name: seriesTitle($0), sort: $0) })
        try session.commit()
        return repo
    }

    private func count(_ hits: [SearchHit], _ kind: ContentKind) -> Int { hits.filter { $0.kind == kind }.count }

    /// Root cause of the report: 2 000 short movie titles outrank every channel/series for a shared token,
    /// so a single global `LIMIT 60` never reached channels or series.
    func testSearchReturnsChannelsMoviesAndSeriesOnLargeMovieCatalog() throws {
        let channels = (0..<50).map { "|DE| TR: TRT Sport HD Kanal \($0)" }
        let repo = try makeRepo(movies: 2_000, channels: channels, series: 30)
        let hits = try repo.search("sport", sourceId: "s")
        XCTAssertEqual(count(hits, .live), 30, "channels must not be crowded out by movies")
        XCTAssertEqual(count(hits, .movie), 30)
        XCTAssertEqual(count(hits, .series), 30)
        XCTAssertEqual(hits.map(\.kind), Array(repeating: .live, count: 30) + Array(repeating: .movie, count: 30)
                       + Array(repeating: .series, count: 30), "grouped live, movies, series")
    }

    func testPerKindLimitIsConfigurable() throws {
        let repo = try makeRepo(movies: 100, channels: (0..<100).map { "Sport Kanal \($0)" }, series: 5)
        let hits = try repo.search("sport", sourceId: "s", perKindLimit: 7)
        XCTAssertEqual([count(hits, .live), count(hits, .movie), count(hits, .series)], [7, 7, 5])
    }

    func testKindWithFewMatchesStillReturned() throws {
        let repo = try makeRepo(movies: 500, channels: ["Zeta Kanal"], series: 0)
        let hits = try repo.search("zeta", sourceId: "s")
        XCTAssertEqual(hits.map(\.kind), [.live])
        XCTAssertTrue(try repo.search("sport", sourceId: "s").allSatisfy { $0.kind == .movie })
    }

    /// Provider prefixes and punctuation ("TR:", "|DE|", "[HD]") are not part of any token.
    func testProviderPrefixesDoNotBlockMatching() throws {
        let repo = try makeRepo(channels: ["TR: TRT 1 HD", "|DE| ARD", "[HD] Das Erste", "FR - Canal+ Sport"])
        XCTAssertEqual(try repo.search("trt").map(\.title), ["TR: TRT 1 HD"])
        XCTAssertEqual(try repo.search("ard").map(\.title), ["|DE| ARD"])
        XCTAssertEqual(try repo.search("erste").map(\.title), ["[HD] Das Erste"])
        XCTAssertEqual(try repo.search("canal sport").map(\.title), ["FR - Canal+ Sport"])
        XCTAssertEqual(try repo.search("  |DE|  ").map(\.title), ["|DE| ARD"], "punctuation in the query is ignored")
        XCTAssertEqual(try repo.search("tr: trt 1").map(\.title), ["TR: TRT 1 HD"], "multi-token AND")
    }

    /// FTS5 `unicode61 remove_diacritics 2` folds case and diacritics: "türk" == "TÜRK" == "turk".
    func testTurkishCharactersAndCaseFolding() throws {
        let repo = try makeRepo(channels: ["TÜRK Müzik", "Güneş TV", "Şişli Haber"])
        XCTAssertEqual(try repo.search("türk").map(\.title), ["TÜRK Müzik"])
        XCTAssertEqual(try repo.search("TÜRK").map(\.title), ["TÜRK Müzik"])
        XCTAssertEqual(try repo.search("turk").map(\.title), ["TÜRK Müzik"], "diacritics folded")
        XCTAssertEqual(try repo.search("gunes").map(\.title), ["Güneş TV"])
        XCTAssertEqual(try repo.search("sisli").map(\.title), ["Şişli Haber"])
    }

    /// The no-FTS5 fallback applies the same per-kind limit (no global prefix cut that drops later kinds).
    func testLikeFallbackIsPerKindToo() throws {
        let channels = (0..<50).map { "TRT Sport HD Kanal \($0)" }
        let repo = try makeRepo(movies: 300, channels: channels, series: 30)
        let hits = try repo.searchLike(tokens: ["sport"], sourceId: "s", perKindLimit: 30)
        XCTAssertEqual([count(hits, .live), count(hits, .movie), count(hits, .series)], [30, 30, 30])
        XCTAssertEqual(hits.first?.kind, .live)
        XCTAssertEqual(hits.last?.kind, .series)
    }

    func testSearchWithoutSourceSkipsStagingRows() throws {
        let repo = try makeRepo(channels: ["Sport Live"])
        let staging = try repo.beginRefresh(sourceId: "s")
        try staging.write(channels: [TestData.channel(id: "x", sourceId: "s", name: "Sport Staged")])
        XCTAssertEqual(try repo.search("sport").map(\.title), ["Sport Live"])
        staging.abort()
    }
}
