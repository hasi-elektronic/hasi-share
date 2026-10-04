import Foundation
import XCTest
@testable import IPTVCore

/// CONTRACT §4 – `spec/test-vectors/xtream/*`.
final class XtreamVectorTests: XCTestCase {
    private func json(_ file: String) throws -> JSONValue {
        try XCTUnwrap(JSONValue.parse(try Vectors.data("xtream/\(file)")), file)
    }

    /// Every input file is referenced by some expectation below.
    func testEveryVectorFileIsCovered() throws {
        let covered: Set<String> = [
            "auth.expected.json", "live_categories.json", "live_categories.expected.json",
            "live_streams.json", "live_streams.expected.json", "vod_streams.json", "vod_streams.expected.json",
            "series.json", "series.expected.json", "series_info.expected.json", "short_epg.json",
            "short_epg.expected.json", "url-vectors.json",
        ]
        var referenced = covered
        for c in try XCTUnwrap(Vectors.object("xtream/auth.expected.json").arr("cases")) { referenced.insert(c.str("file") ?? "") }
        for c in try XCTUnwrap(Vectors.object("xtream/series_info.expected.json").arr("cases")) { referenced.insert(c.str("file") ?? "") }
        XCTAssertEqual(Set(try Vectors.files(in: "xtream")), referenced)
    }

    // MARK: Account classification (§4.4)

    func testAccountClassification() throws {
        let root = try Vectors.object("xtream/auth.expected.json")
        let now = Date(timeIntervalSince1970: TimeInterval(try XCTUnwrap(root.int64("nowEpochSeconds"))))
        let cases = try XCTUnwrap(root.arr("cases"))
        XCTAssertEqual(cases.count, 14)
        for c in cases {
            let file = try XCTUnwrap(c.str("file"))
            let http = try XCTUnwrap(c.num("http")).intValue
            let expected = try XCTUnwrap(c.obj("expected"))
            let result = XtreamAccountClassifier.classify(httpStatus: http, body: try Vectors.data("xtream/\(file)"), now: now)
            assertJSONEqual(expected, Self.json(result), "\(file) http=\(http)")
        }
    }

    static func json(_ result: Result<XtreamAccountInfo, SourceError>) -> [String: Any] {
        switch result {
        case .success(let a):
            return ["result": "OK", "status": a.status, "expiresAt": epoch(a.expiresAt),
                    "maxConnections": j(a.maxConnections), "activeConnections": j(a.activeConnections),
                    "allowedOutputFormats": a.allowedOutputFormats, "serverTimezone": a.serverTimezone]
        case .failure(let e):
            switch e {
            case .invalidCredentials: return ["result": "InvalidCredentials"]
            case .accountExpired(let at): return ["result": "AccountExpired", "expiresAt": epoch(at)]
            case .accountDisabled: return ["result": "AccountDisabled"]
            case .invalidResponse: return ["result": "InvalidResponse"]
            case .notFound: return ["result": "NotFound"]
            case .serverError(let status): return ["result": "ServerError", "httpStatus": status]
            default: return ["result": "\(e)"]
            }
        }
    }

    /// Same classification through `XtreamClient` over a fake transport (+ network failure row).
    func testClientAuthenticateUsesClassification() async throws {
        let ok = try Vectors.data("xtream/auth_ok.json")
        let transport = FakeTransport { _ in HTTPResponse(statusCode: 200, body: ok) }
        let client = try XCTUnwrap(XtreamClient(sourceId: "s", secrets: XtreamSecrets(serverUrl: "iptv.example.com:8080", username: "user1", password: "p@ss/w rd"),
                                                transport: transport, sleeper: .immediate))
        let account = try await client.authenticate(now: Date(timeIntervalSince1970: 1_759_570_000))
        XCTAssertEqual(account.serverTimezone, "Europe/Istanbul")
        XCTAssertEqual(transport.requests.first?.url.absoluteString,
                       "http://iptv.example.com:8080/player_api.php?username=user1&password=p%40ss%2Fw%20rd")

        let offline = FakeTransport { _ in throw URLError(.notConnectedToInternet) }
        let offlineClient = try XCTUnwrap(XtreamClient(sourceId: "s", secrets: XtreamSecrets(serverUrl: "h", username: "u", password: "p"),
                                                       transport: offline, sleeper: .immediate))
        do {
            _ = try await offlineClient.authenticate()
            XCTFail("expected failure")
        } catch {
            XCTAssertEqual(error as? SourceError, .network(.offline))
        }
        XCTAssertEqual(offline.requests.count, 3, "network errors are retried twice")
    }

    // MARK: Lists (§4.3)

    func testCategories() throws {
        let cats = XtreamMapper.categories(try json("live_categories.json"), sourceId: "s", kind: .live)
        assertJSONEqual(try Vectors.json("xtream/live_categories.expected.json"),
                        cats.map { ["id": $0.id, "name": $0.name] as [String: Any] })
    }

    func testLiveStreams() throws {
        let channels = XtreamMapper.channels(try json("live_streams.json"), sourceId: "s")
        let actual = channels.map { c -> [String: Any] in
            ["id": c.id, "name": c.name, "number": j(c.number), "logoUrl": j(c.logoUrl), "categoryId": j(c.categoryId),
             "epgId": j(c.epgId), "catchup": ["type": c.catchup.type.rawValue, "days": c.catchup.days] as [String: Any]]
        }
        assertJSONEqual(try Vectors.json("xtream/live_streams.expected.json"), actual)
        XCTAssertNil(channels.first?.url, "Xtream URLs are never persisted")
    }

    func testVodStreams() throws {
        let movies = XtreamMapper.movies(try json("vod_streams.json"), sourceId: "s")
        let actual = movies.map { m -> [String: Any] in
            ["id": m.id, "name": m.name, "posterUrl": j(m.posterUrl), "categoryId": j(m.categoryId), "rating": j(m.rating),
             "year": j(m.year), "containerExt": j(m.containerExt), "addedAt": epoch(m.addedAt)]
        }
        assertJSONEqual(try Vectors.json("xtream/vod_streams.expected.json"), actual)
    }

    func testSeries() throws {
        let series = XtreamMapper.series(try json("series.json"), sourceId: "s")
        let actual = series.map { s -> [String: Any] in
            ["id": s.id, "name": s.name, "posterUrl": j(s.posterUrl), "categoryId": j(s.categoryId), "plot": j(s.plot),
             "rating": j(s.rating), "year": j(s.year)]
        }
        assertJSONEqual(try Vectors.json("xtream/series.expected.json"), actual)
    }

    func testSeriesInfoBothShapes() throws {
        let cases = try XCTUnwrap(Vectors.object("xtream/series_info.expected.json").arr("cases"))
        XCTAssertEqual(cases.count, 2)
        for c in cases {
            let file = try XCTUnwrap(c.str("file"))
            let seriesId = try XCTUnwrap(c.str("seriesId"))
            let episodes = XtreamMapper.episodes(try json(file), sourceId: "s", seriesId: seriesId)
            let actual = episodes.map { e -> [String: Any] in
                ["id": e.id, "seriesId": e.seriesId, "season": e.season, "number": e.number, "title": e.title,
                 "containerExt": j(e.containerExt), "durationSec": j(e.durationSec), "plot": j(e.plot), "posterUrl": j(e.posterUrl)]
            }
            assertJSONEqual(try XCTUnwrap(c["episodes"]), actual, file)
        }
        let details = XtreamMapper.seriesDetails(try json("series_info.json"))
        XCTAssertEqual(details.name, "Breaking Bad")
        XCTAssertEqual(details.year, 2008)
        XCTAssertEqual(details.rating, 9.5)
        XCTAssertNil(XtreamMapper.seriesDetails(try json("series_info_list_variant.json")).name, "info: [] is an empty object")
    }

    func testShortEpg() throws {
        let entries = XtreamMapper.shortEpg(try json("short_epg.json"))
        let actual = entries.map { e -> [String: Any] in
            ["start": epoch(e.start), "end": epoch(e.end), "title": j(e.title), "description": j(e.description), "hasArchive": e.hasArchive]
        }
        assertJSONEqual(try Vectors.json("xtream/short_epg.expected.json"), actual)
        XCTAssertEqual(XtreamMapper.decodeBase64Text("!!!not-base64!!!"), "!!!not-base64!!!")
        XCTAssertNil(XtreamMapper.decodeBase64Text(""))
        XCTAssertEqual(XtreamMapper.decodeBase64Text("RGl6aQ=="), "Dizi")
    }

    func testLenientDecoding() throws {
        let v = try XCTUnwrap(JSONValue.parse(Data(#"{"a":"12","b":"","c":null,"d":"1","e":true,"f":"x","g":3.0,"h":[]}"#.utf8)))
        XCTAssertEqual(v["a"]?.intValue, 12)
        XCTAssertNil(v["b"]?.intValue)
        XCTAssertNil(v["c"]?.intValue)
        XCTAssertEqual(v["d"]?.boolValue, true)
        XCTAssertEqual(v["e"]?.boolValue, true)
        XCTAssertEqual(v["f"]?.boolValue, false)
        XCTAssertEqual(v["g"]?.intValue, 3)
        XCTAssertEqual(v["h"]?.objectValue, [:])
        XCTAssertNil(JSONValue.parse(Data("<html>".utf8)))
        XCTAssertNotNil(JSONValue.parse(Data("\u{FEFF} [1, 2] ".utf8)))
    }

    // MARK: URLs (§4.1, §4.5)

    func testServerNormalization() throws {
        let list = try XCTUnwrap(Vectors.object("xtream/url-vectors.json").arr("normalize"))
        XCTAssertEqual(list.count, 7)
        for c in list {
            XCTAssertEqual(URLNormalizer.xtreamBase(try XCTUnwrap(c.str("input"))), c.str("expected"), c.str("input") ?? "")
        }
    }

    func testPlaybackAndApiUrls() throws {
        let root = try Vectors.object("xtream/url-vectors.json")
        let creds = try XCTUnwrap(root.obj("credentials"))
        let b = try XCTUnwrap(XtreamURLBuilder(serverUrl: try XCTUnwrap(creds.str("base")), username: try XCTUnwrap(creds.str("username")),
                                               password: try XCTUnwrap(creds.str("password"))))
        let urls = try XCTUnwrap(root.arr("urls"))
        XCTAssertEqual(urls.count, 8)
        for c in urls {
            let kind = try XCTUnwrap(c.str("kind"))
            let url: URL
            switch kind {
            case "api": url = b.apiURL(action: c.str("action"))
            case "xmltv": url = b.xmltvURL()
            case "live": url = b.liveURL(streamId: try XCTUnwrap(c.str("streamId")), ext: try XCTUnwrap(c.str("ext")))
            case "movie": url = b.movieURL(streamId: try XCTUnwrap(c.str("streamId")), containerExt: try XCTUnwrap(c.str("ext")))
            case "episode": url = b.episodeURL(episodeId: try XCTUnwrap(c.str("streamId")), containerExt: try XCTUnwrap(c.str("ext")))
            case "timeshift":
                url = b.timeshiftURL(streamId: try XCTUnwrap(c.str("streamId")),
                                     start: Date(timeIntervalSince1970: TimeInterval(try XCTUnwrap(c.int64("start")))),
                                     end: Date(timeIntervalSince1970: TimeInterval(try XCTUnwrap(c.int64("end")))),
                                     serverTimezone: c.str("serverTimezone"), ext: try XCTUnwrap(c.str("ext")))
            default:
                XCTFail("unknown kind \(kind)")
                continue
            }
            XCTAssertEqual(url.absoluteString, c.str("expected"), kind)
        }
    }

    func testLiveExtension() throws {
        let list = try XCTUnwrap(Vectors.object("xtream/url-vectors.json").arr("liveExt"))
        XCTAssertEqual(list.count, 7)
        for c in list {
            let platform = try XCTUnwrap(StreamPlatform(rawValue: try XCTUnwrap(c.str("platform"))))
            let allowed = try XCTUnwrap(c["allowed"] as? [String])
            let expected = try XCTUnwrap(c.str("expected"))
            let label = "\(platform) \(allowed)"
            if expected == "error:UnsupportedFormat" {
                XCTAssertThrowsError(try XtreamURLBuilder.liveExtension(platform: platform, allowedOutputFormats: allowed), label) {
                    XCTAssertEqual($0 as? PlaybackError, .unsupportedFormat(container: "mpegts"), label)
                }
            } else {
                XCTAssertEqual(try XtreamURLBuilder.liveExtension(platform: platform, allowedOutputFormats: allowed), expected, label)
            }
        }
    }

    func testPercentEncoding() {
        XCTAssertEqual(PercentEncoding.encode("p@ss/w rd"), "p%40ss%2Fw%20rd")
        XCTAssertEqual(PercentEncoding.encode("AZaz09-._~"), "AZaz09-._~")
        XCTAssertEqual(PercentEncoding.encode("çğ+=&"), "%C3%A7%C4%9F%2B%3D%26")
    }

    // MARK: Full refresh

    func testFetchCatalogOverFakeTransport() async throws {
        let files: [String: String] = [
            "": "auth_ok.json", "get_live_categories": "live_categories.json", "get_vod_categories": "live_categories.json",
            "get_series_categories": "live_categories.json", "get_live_streams": "live_streams.json",
            "get_vod_streams": "vod_streams.json", "get_series": "series.json",
        ]
        let transport = FakeTransport { request in
            let action = URLComponents(url: request.url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "action" })?.value ?? ""
            guard let file = files[action] else { return HTTPResponse(statusCode: 404) }
            return HTTPResponse(statusCode: 200, body: try Vectors.data("xtream/\(file)"))
        }
        let client = try XCTUnwrap(XtreamClient(sourceId: "s", secrets: XtreamSecrets(serverUrl: "http://iptv.example.com:8080", username: "user1", password: "pass1"),
                                                transport: transport, sleeper: .immediate))
        let catalog = try await client.fetchCatalog(now: Date(timeIntervalSince1970: 1_759_570_000))
        XCTAssertEqual(catalog.channels.count, 3)
        XCTAssertEqual(catalog.movies.count, 2)
        XCTAssertEqual(catalog.series.count, 2)
        XCTAssertEqual(catalog.status.liveCount, 3)
        XCTAssertEqual(client.fingerprint, "d11e55fa87364ff0")

        // Empty lists → SourceError.empty.
        let empty = FakeTransport { request in
            let isAuth = !(request.url.query ?? "").contains("action=")
            return HTTPResponse(statusCode: 200, body: isAuth ? try Vectors.data("xtream/auth_ok.json") : Data("[]".utf8))
        }
        let emptyClient = try XCTUnwrap(XtreamClient(sourceId: "s", secrets: XtreamSecrets(serverUrl: "h", username: "u", password: "p"),
                                                     transport: empty, sleeper: .immediate))
        do {
            _ = try await emptyClient.fetchCatalog(now: Date(timeIntervalSince1970: 1_759_570_000))
            XCTFail("expected .empty")
        } catch {
            XCTAssertEqual(error as? SourceError, .empty)
        }
    }
}
