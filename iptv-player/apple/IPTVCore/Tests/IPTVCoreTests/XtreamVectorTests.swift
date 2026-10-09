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
            "short_epg.expected.json", "url-vectors.json", "series_categories.json", "series_categories.expected.json",
            "category_ids.json", "category_ids.expected.json", "vod_info.expected.json",
        ]
        var referenced = covered
        for c in try XCTUnwrap(Vectors.object("xtream/auth.expected.json").arr("cases")) { referenced.insert(c.str("file") ?? "") }
        for c in try XCTUnwrap(Vectors.object("xtream/series_info.expected.json").arr("cases")) { referenced.insert(c.str("file") ?? "") }
        for c in try XCTUnwrap(Vectors.object("xtream/vod_info.expected.json").arr("cases")) { referenced.insert(c.str("file") ?? "") }
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

    /// `get_series_categories` with numeric/string ids, `parent_id` and Turkish names: nothing valid is dropped.
    func testSeriesCategories() throws {
        let cats = XtreamMapper.categories(try json("series_categories.json"), sourceId: "s", kind: .series)
        assertJSONEqual(try Vectors.json("xtream/series_categories.expected.json"),
                        cats.map { ["id": $0.id, "name": $0.name] as [String: Any] })
        XCTAssertEqual(cats.map(\.sort), Array(0..<cats.count), "provider order")
    }

    /// XUI.one / newer panels: `category_ids` arrays (ints or strings), `category_id` null/""/only the first.
    func testCategoryIds() throws {
        let input = try json("category_ids.json")
        let expected = try Vectors.object("xtream/category_ids.expected.json")
        func row(_ id: String, _ categoryId: String?, _ categoryIds: [String]) -> [String: Any] {
            ["id": id, "categoryId": j(categoryId), "categoryIds": categoryIds]
        }
        assertJSONEqual(try XCTUnwrap(expected["live"]),
                        XtreamMapper.channels(try XCTUnwrap(input["live"]), sourceId: "s").map { row($0.id, $0.categoryId, $0.categoryIds) }, "live")
        assertJSONEqual(try XCTUnwrap(expected["vod"]),
                        XtreamMapper.movies(try XCTUnwrap(input["vod"]), sourceId: "s").map { row($0.id, $0.categoryId, $0.categoryIds) }, "vod")
        assertJSONEqual(try XCTUnwrap(expected["series"]),
                        XtreamMapper.series(try XCTUnwrap(input["series"]), sourceId: "s").map { row($0.id, $0.categoryId, $0.categoryIds) }, "series")
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
             "year": j(m.year), "containerExt": j(m.containerExt), "addedAt": epoch(m.addedAt),
             "cast": j(m.cast), "director": j(m.director), "genre": j(m.genre)]
        }
        assertJSONEqual(try Vectors.json("xtream/vod_streams.expected.json"), actual)
    }

    func testSeries() throws {
        let series = XtreamMapper.series(try json("series.json"), sourceId: "s")
        let actual = series.map { s -> [String: Any] in
            ["id": s.id, "name": s.name, "posterUrl": j(s.posterUrl), "categoryId": j(s.categoryId), "plot": j(s.plot),
             "rating": j(s.rating), "year": j(s.year), "cast": j(s.cast), "director": j(s.director), "genre": j(s.genre)]
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
            let details = XtreamMapper.seriesDetails(try json(file))
            assertJSONEqual(try XCTUnwrap(c["details"]),
                            ["cast": j(details.cast), "director": j(details.director), "genre": j(details.genre)] as [String: Any], "\(file) details")
        }
        let details = XtreamMapper.seriesDetails(try json("series_info.json"))
        XCTAssertEqual(details.name, "Breaking Bad")
        XCTAssertEqual(details.year, 2008)
        XCTAssertEqual(details.rating, 9.5)
        XCTAssertNil(XtreamMapper.seriesDetails(try json("series_info_list_variant.json")).name, "info: [] is an empty object")
    }

    /// `get_vod_info` people fields: strings or arrays, `actors` fallback (CONTRACT §4.3).
    func testVodInfoPeople() throws {
        let cases = try XCTUnwrap(Vectors.object("xtream/vod_info.expected.json").arr("cases"))
        XCTAssertEqual(cases.count, 2)
        for c in cases {
            let file = try XCTUnwrap(c.str("file"))
            let info = XtreamMapper.vodInfo(try json(file))
            let actual: [String: Any] = ["file": file, "name": j(info.name), "cast": j(info.cast), "director": j(info.director),
                                         "genre": j(info.genre), "durationSec": j(info.durationSec), "containerExt": j(info.containerExt)]
            assertJSONEqual(c, actual, file)
        }
    }

    /// IOS-09: `youtube_trailer` (id or URL) is mapped for movies and series; only YouTube URLs are accepted.
    func testTrailerMappingAndURL() throws {
        let vod = try XCTUnwrap(JSONValue.parse(Data(#"{"info":{"youtube_trailer":"dQw4w9WgXcQ","genre":"Komödie, Drama","releasedate":"2001-07-13"},"movie_data":{}}"#.utf8)))
        XCTAssertEqual(XtreamMapper.vodInfo(vod).trailer, "dQw4w9WgXcQ")
        XCTAssertEqual(XtreamMapper.vodInfo(vod).genre, "Komödie, Drama")
        let series = try XCTUnwrap(JSONValue.parse(Data(#"{"info":{"youtube_trailer":" https://youtu.be/abc "}}"#.utf8)))
        XCTAssertEqual(XtreamMapper.seriesDetails(series).trailer, "https://youtu.be/abc")
        XCTAssertNil(XtreamMapper.seriesDetails(try XCTUnwrap(JSONValue.parse(Data(#"{"info":{"youtube_trailer":""}}"#.utf8)))).trailer)
        XCTAssertEqual(XtreamMapper.trailerURL("dQw4w9WgXcQ")?.absoluteString, "https://www.youtube.com/watch?v=dQw4w9WgXcQ")
        XCTAssertEqual(XtreamMapper.trailerURL("https://www.youtube.com/watch?v=x")?.host, "www.youtube.com")
        XCTAssertNil(XtreamMapper.trailerURL("javascript:alert(1)"))
        XCTAssertNil(XtreamMapper.trailerURL("https://evil.example.com/watch"))
        XCTAssertNil(XtreamMapper.trailerURL("short"))
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

    func testLiveExtensionAppleWithVLC() throws {
        let list = try XCTUnwrap(Vectors.object("xtream/url-vectors.json").arr("liveExtAppleVlc"))
        XCTAssertFalse(list.isEmpty)
        for c in list {
            let allowed = try XCTUnwrap(c["allowed"] as? [String])
            XCTAssertEqual(try XtreamURLBuilder.liveExtension(platform: .apple, allowedOutputFormats: allowed, vlcAvailable: true),
                           c.str("expected"), "\(allowed)")
        }
    }

    /// CONTRACT §4.5: an M3U live entry with an Xtream-shaped `.ts` URL has an HLS twin (`.m3u8`).
    func testHLSVariantOfXtreamLiveTS() {
        XCTAssertEqual(XtreamURLBuilder.hlsVariant(ofLiveTS: "http://panel.example.com:8080/live/u/p/42.ts"),
                       "http://panel.example.com:8080/live/u/p/42.m3u8")
        XCTAssertEqual(XtreamURLBuilder.hlsVariant(ofLiveTS: "https://panel.example.com/u/p%40x/7.ts"),
                       "https://panel.example.com/u/p%40x/7.m3u8", "M3U variant without /live/")
        XCTAssertNil(XtreamURLBuilder.hlsVariant(ofLiveTS: "http://h.example.com/live/7.ts"), "too few path segments")
        XCTAssertNil(XtreamURLBuilder.hlsVariant(ofLiveTS: "http://h.example.com/live/u/p/abc.ts"), "non-numeric id")
        XCTAssertNil(XtreamURLBuilder.hlsVariant(ofLiveTS: "http://h.example.com/live/u/p/42.ts?token=1"), "query")
        XCTAssertNil(XtreamURLBuilder.hlsVariant(ofLiveTS: "http://h.example.com/live/u/p/42.m3u8"), "already HLS")
        XCTAssertNil(XtreamURLBuilder.hlsVariant(ofLiveTS: "http://h.example.com/a/b/c/d/42.ts"), "deeper path")
        XCTAssertNil(XtreamURLBuilder.hlsVariant(ofLiveTS: "rtsp://h.example.com/u/p/42.ts"), "http(s) only")
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
        XCTAssertEqual(catalog.series.count, 3)
        XCTAssertEqual(catalog.status.liveCount, 3)
        XCTAssertEqual(client.fingerprint, "d11e55fa87364ff0")

        // A failing list (here `get_series`, e.g. a huge list hitting the 20 s limit) fails the whole refresh –
        // never a silently partial catalog with 0 series.
        let seriesDown = FakeTransport { request in
            let action = URLComponents(url: request.url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "action" })?.value ?? ""
            if action == "get_series" { throw URLError(.timedOut) }
            guard let file = files[action] else { return HTTPResponse(statusCode: 404) }
            return HTTPResponse(statusCode: 200, body: try Vectors.data("xtream/\(file)"))
        }
        let seriesDownClient = try XCTUnwrap(XtreamClient(sourceId: "s", secrets: XtreamSecrets(serverUrl: "h", username: "u", password: "p"),
                                                          transport: seriesDown, sleeper: .immediate))
        do {
            _ = try await seriesDownClient.fetchCatalog(now: Date(timeIntervalSince1970: 1_759_570_000))
            XCTFail("expected a network error")
        } catch {
            XCTAssertEqual(error as? SourceError, .network(.timeout))
        }

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
    /// B3/P3: the list calls get the long list budget (60 s idle, 10 min total) instead of the 20 s JSON
    /// limit, and the three big lists are downloaded one after another (never two bodies in flight).
    func testListCallsUseListTimeoutsAndBigListsAreSequential() async throws {
        let files: [String: String] = [
            "": "auth_ok.json", "get_live_categories": "live_categories.json", "get_vod_categories": "live_categories.json",
            "get_series_categories": "live_categories.json", "get_live_streams": "live_streams.json",
            "get_vod_streams": "vod_streams.json", "get_series": "series.json",
        ]
        let probe = InFlightProbe()
        let transport = SlowTransport(probe: probe) { request in
            let action = URLComponents(url: request.url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "action" })?.value ?? ""
            guard let file = files[action] else { return HTTPResponse(statusCode: 404) }
            return HTTPResponse(statusCode: 200, body: try Vectors.data("xtream/\(file)"))
        }
        let client = try XCTUnwrap(XtreamClient(sourceId: "s", secrets: XtreamSecrets(serverUrl: "http://iptv.example.com:8080", username: "u", password: "p"),
                                                transport: transport, sleeper: .immediate))
        _ = try await client.fetchCatalog(now: Date(timeIntervalSince1970: 1_759_570_000))
        let byAction = Dictionary(transport.requests.map { r in
            (URLComponents(url: r.url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "action" })?.value ?? "", r.timeouts)
        }, uniquingKeysWith: { a, _ in a })
        XCTAssertEqual(byAction[""], .xtreamJSON, "account check keeps the short JSON budget")
        for action in ["get_live_streams", "get_vod_streams", "get_series", "get_live_categories"] {
            XCTAssertEqual(byAction[action], .xtreamList, action)
        }
        XCTAssertEqual(HTTPTimeouts.xtreamList.read, 60)
        XCTAssertEqual(HTTPTimeouts.xtreamList.total, 600)
        XCTAssertEqual(probe.maxBigInFlight, 1, "big lists one at a time")
    }
}

/// Counts concurrent big-list requests.
final class InFlightProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var current = 0
    private(set) var maxBigInFlight = 0
    func enter() { lock.withLock { current += 1; maxBigInFlight = max(maxBigInFlight, current) } }
    func leave() { lock.withLock { current -= 1 } }
}

/// Fake transport whose big-list responses take a moment (so overlapping downloads would be visible).
final class SlowTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [HTTPRequest] = []
    private let probe: InFlightProbe
    private let handler: @Sendable (HTTPRequest) throws -> HTTPResponse

    init(probe: InFlightProbe, _ handler: @escaping @Sendable (HTTPRequest) throws -> HTTPResponse) {
        self.probe = probe
        self.handler = handler
    }

    var requests: [HTTPRequest] { lock.withLock { recorded } }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        lock.withLock { recorded.append(request) }
        let query = request.url.query ?? ""
        let big = ["get_live_streams", "get_vod_streams", "get_series"].contains { query.contains("action=\($0)") && !query.contains("action=\($0)_") }
        if big { probe.enter() }
        defer { if big { probe.leave() } }
        if big { try await Task.sleep(nanoseconds: 30_000_000) }
        return try handler(request)
    }
}
