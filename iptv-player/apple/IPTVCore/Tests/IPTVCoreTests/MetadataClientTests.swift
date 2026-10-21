import Foundation
import XCTest
@testable import IPTVCore

/// CONTRACT §11 / BACKEND_API.md "Metadata": request shapes, lenient decoding, 404 / 503 mapping,
/// and the panel's TMDB id.
final class MetadataClientTests: XCTestCase {
    private let base = URL(string: "https://api.example.com")!

    private static func json(_ s: String, status: Int = 200, headers: [String: String] = [:]) -> HTTPResponse {
        HTTPResponse(statusCode: status, headers: ["Content-Type": "application/json"].merging(headers) { $1 }, body: Data(s.utf8))
    }

    func testMatchRequestAndDecoding() async throws {
        let t = FakeTransport { _ in
            Self.json(#"""
            {"parsed":{"title":"Inception","year":2010,"yearInBrackets":true,"season":null,"episode":null},
             "match":{"tmdbId":27205,"type":"movie","title":"Inception","originalTitle":"Inception","overview":null,
                      "posterUrl":"https://image.tmdb.org/t/p/w500/a.jpg","backdropUrl":null,"rating":8.4,
                      "voteCount":35000,"releaseDate":"2010-07-15","extra":"ignored"},
             "confidence":0.98}
            """#)
        }
        let result = try await BackendClient(baseURL: base, transport: t)
            .metadataMatch(name: "DE | Inception (2010) 4K", type: .movie, year: 2010, language: .de)
        XCTAssertEqual(result.parsed?.title, "Inception")
        XCTAssertEqual(result.parsed?.yearInBrackets, true)
        XCTAssertEqual(result.match?.tmdbId, 27205)
        XCTAssertEqual(result.match?.year, 2010)
        XCTAssertEqual(result.confidence, 0.98)
        let url = try XCTUnwrap(t.requests.first?.url)
        let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(url.path, "/v1/metadata/match")
        XCTAssertEqual(items.first { $0.name == "name" }?.value, "DE | Inception (2010) 4K")
        XCTAssertEqual(items.first { $0.name == "type" }?.value, "movie")
        XCTAssertEqual(items.first { $0.name == "year" }?.value, "2010")
        XCTAssertEqual(items.first { $0.name == "language" }?.value, "de")
    }

    func testNoMatchAndOutOfRangeYear() async throws {
        let t = FakeTransport { _ in Self.json(#"{"parsed":{"title":"xyz"},"match":null,"confidence":0.31}"#) }
        let result = try await BackendClient(baseURL: base, transport: t).metadataMatch(name: "xyz", type: .tv, year: 0, language: .en)
        XCTAssertNil(result.match)
        XCTAssertFalse(try XCTUnwrap(t.requests.first?.url.query).contains("year="))
    }

    func testDetailsLenientDecoding() async throws {
        let t = FakeTransport { _ in
            Self.json(#"""
            {"tmdbId":1399,"type":"tv","title":"Game of Thrones","originalTitle":null,"overview":"Sieben Königreiche …",
             "posterUrl":"https://image.tmdb.org/t/p/w500/p.jpg","backdropUrl":"https://image.tmdb.org/t/p/w1280/b.jpg",
             "rating":"not a number","voteCount":24000,"releaseDate":"2011-04-17","genres":["Drama","Sci-Fi & Fantasy"],
             "cast":[{"name":"Emilia Clarke","character":"Daenerys Targaryen","profileUrl":null},{"character":"broken"}],
             "trailerUrl":"https://www.youtube.com/watch?v=KPLWWIOCOOQ","runtimeMinutes":null,"seasons":8,"language":"de"}
            """#)
        }
        let fetched = try await BackendClient(baseURL: base, transport: t).metadata(tmdbId: 1399, type: .tv, language: .de)
        let m = try XCTUnwrap(fetched)
        XCTAssertEqual(m.title, "Game of Thrones")
        XCTAssertNil(m.rating)                       // wrong type → nil, not a decoding failure
        XCTAssertEqual(m.year, 2011)
        XCTAssertEqual(m.genres, ["Drama", "Sci-Fi & Fantasy"])
        XCTAssertEqual(m.cast.map(\.name), ["Emilia Clarke"])   // malformed entry skipped
        XCTAssertEqual(m.seasons, 8)
        XCTAssertEqual(m.trailerURL?.host, "www.youtube.com")
        XCTAssertEqual(t.requests.first?.url.absoluteString, "https://api.example.com/v1/metadata/1399?type=tv&language=de")
    }

    func testDetailsNotFoundIsNil() async throws {
        let t = FakeTransport { _ in Self.json(#"{"error":"not_found","message":"No such title."}"#, status: 404) }
        let m = try await BackendClient(baseURL: base, transport: t).metadata(tmdbId: 1, type: .movie, language: .en)
        XCTAssertNil(m)
    }

    func testUnavailableCarriesRetryAfter() async throws {
        let down = FakeTransport { _ in
            Self.json(#"{"error":"metadata_unavailable","message":"temporarily unavailable","retryAfter":60}"#, status: 503,
                      headers: ["Retry-After": "60"])
        }
        do {
            _ = try await BackendClient(baseURL: base, transport: down).metadata(tmdbId: 1, type: .movie, language: .en)
            XCTFail("expected MetadataUnavailable")
        } catch {
            XCTAssertEqual(error as? MetadataUnavailable, MetadataUnavailable(retryAfter: 60))
        }
        let unconfigured = FakeTransport { _ in
            Self.json(#"{"error":"metadata_unavailable","message":"Metadata service is not configured."}"#, status: 503)
        }
        do {
            _ = try await BackendClient(baseURL: base, transport: unconfigured).metadataMatch(name: "x", type: .movie, language: .en)
            XCTFail("expected MetadataUnavailable")
        } catch {
            XCTAssertEqual(error as? MetadataUnavailable, MetadataUnavailable(retryAfter: nil))
        }
    }

    func testOtherErrorsStayBackendErrors() async {
        let t = FakeTransport { _ in Self.json(#"{"error":"rate_limited","retryAfter":3}"#, status: 429) }
        do {
            _ = try await BackendClient(baseURL: base, transport: t).metadataMatch(name: "x", type: .movie, language: .en)
            XCTFail("expected BackendError")
        } catch {
            XCTAssertEqual((error as? BackendError)?.httpStatus, 429)
        }
    }

    func testLanguageFromUICode() {
        XCTAssertEqual(MetadataLanguage(code: "de"), .de)
        XCTAssertEqual(MetadataLanguage(code: "tr-TR"), .tr)
        XCTAssertEqual(MetadataLanguage(code: "fr"), .en)
    }

    func testXtreamTmdbId() throws {
        func vod(_ info: String) throws -> XtreamVodInfo {
            XtreamMapper.vodInfo(try JSONDecoder().decode(JSONValue.self, from: Data(#"{"info":\#(info),"movie_data":{}}"#.utf8)))
        }
        XCTAssertEqual(try vod(#"{"tmdb_id":"27205"}"#).tmdbId, 27205)
        XCTAssertEqual(try vod(#"{"tmdb_id":27205}"#).tmdbId, 27205)
        XCTAssertNil(try vod(#"{"tmdb_id":""}"#).tmdbId)
        XCTAssertNil(try vod(#"{"tmdb_id":"0"}"#).tmdbId)
        XCTAssertNil(try vod(#"{"tmdb_id":true}"#).tmdbId)
        let series = XtreamMapper.seriesDetails(try JSONDecoder().decode(JSONValue.self, from: Data(#"{"info":{"tmdb":"1399"}}"#.utf8)))
        XCTAssertEqual(series.tmdbId, 1399)
    }
}
