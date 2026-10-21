import Foundation
import IPTVCore
import XCTest
@testable import IPTVKit

/// Task 7c: "Series: not all categories (e.g. Turkish) are shown". XUI.one-style panels list an item's
/// categories in `category_ids`; `category_id` is null/"" or only the first one. Every category must list
/// all of its items (spec/test-vectors/xtream/category_ids.json, series_categories.json).
final class CategoryMembershipTests: XCTestCase {
    var database: AppDatabase!
    var catalog: CatalogRepository!

    override func setUpWithError() throws {
        database = try AppDatabase.inMemory()
        catalog = CatalogRepository(database: database)
    }

    /// Serves a fake Xtream panel from the shared vectors.
    private func panelTransport() throws -> FakeTransport {
        let auth = try Data(contentsOf: vectorURL("xtream/auth_ok.json"))
        let seriesCats = try Data(contentsOf: vectorURL("xtream/series_categories.json"))
        let lists = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: vectorURL("xtream/category_ids.json"))) as? [String: Any])
        func body(_ key: String) throws -> Data { try JSONSerialization.data(withJSONObject: try XCTUnwrap(lists[key])) }
        let bodies: [String: Data] = [
            "": auth, "get_series_categories": seriesCats,
            "get_live_categories": Data(#"[{"category_id":"1","category_name":"TR | Ulusal"},{"category_id":7,"category_name":"TR | Haber"}]"#.utf8),
            "get_vod_categories": Data(#"[{"category_id":31,"category_name":"TR | Filmler"},{"category_id":"32","category_name":"Yeşilçam"}]"#.utf8),
            "get_live_streams": try body("live"), "get_vod_streams": try body("vod"), "get_series": try body("series"),
        ]
        return FakeTransport { request in
            let action = URLComponents(url: request.url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "action" })?.value ?? ""
            guard let data = bodies[action] else { return HTTPResponse(statusCode: 404) }
            return HTTPResponse(statusCode: 200, body: data)
        }
    }

    private func refreshPanel() async throws -> String {
        let sources = SourceRepository(database: database, secureStore: InMemorySecureStore())
        let refresher = SourceRefresher(database: database, sources: sources, catalog: catalog, epg: EpgRepository(database: database),
                                        transport: try panelTransport(), retryPolicy: .none, sleeper: .immediate)
        let secrets = SourceSecrets.xtream(XtreamSecrets(serverUrl: "http://panel.example.com:8080", username: "demo", password: "demo"))
        let source = Source.make(name: "Panel", secrets: secrets)
        try sources.save(source, secrets: secrets)
        _ = try await refresher.refresh(sourceId: source.id, now: Date(timeIntervalSince1970: 1_759_570_000), includeEpg: false)
        return source.id
    }

    func testXtreamItemsAppearInEveryCategoryTheyBelongTo() async throws {
        let sid = try await refreshPanel()
        // Series: "TR | DİZİLER" (215) and "Türk Dizileri" (216) must not be empty.
        XCTAssertEqual(Set(try catalog.series(sourceId: sid, categoryId: "215").map(\.id)), ["9001", "9004"])
        XCTAssertEqual(Set(try catalog.series(sourceId: sid, categoryId: "216").map(\.id)), ["9001", "9002"])
        XCTAssertEqual(Set(try catalog.series(sourceId: sid, categoryId: "101").map(\.id)), ["9003"])
        XCTAssertEqual(Set(try catalog.series(sourceId: sid, categoryId: "102").map(\.id)), ["9003", "9005"])
        XCTAssertEqual(try catalog.series(sourceId: sid).count, 6, "the unfiltered list has every series once")
        XCTAssertEqual(try catalog.series(sourceId: sid, categoryId: "216", sort: .az).map(\.name), ["Kuruluş Osman", "Yalı Çapkını"])
        // Movies and live channels: same rule.
        XCTAssertEqual(Set(try catalog.movies(sourceId: sid, categoryId: "32").map(\.id)), ["5001", "5002"])
        XCTAssertEqual(try catalog.channels(sourceId: sid, categoryId: "7").map(\.id), ["1001", "1002"])
        XCTAssertEqual(try catalog.channelCount(sourceId: sid, categoryId: "7"), 2)
        XCTAssertEqual(try catalog.channelCount(sourceId: sid), 2)
    }

    func testCategoriesWithContentListsEveryNonEmptyCategoryInProviderOrder() async throws {
        let sid = try await refreshPanel()
        XCTAssertEqual(try catalog.categories(sourceId: sid, kind: .series).map(\.id), ["101", "102", "215", "216", "217"])
        XCTAssertEqual(try catalog.categoriesWithContent(sourceId: sid, kind: .series).map(\.name),
                       ["EN | NETFLIX SERIES", "DE | SERIEN", "TR | DİZİLER", "Türk Dizileri"])
        XCTAssertEqual(try catalog.categoriesWithContent(sourceId: sid, kind: .movie).map(\.id), ["31", "32"])
        XCTAssertEqual(try catalog.categoriesWithContent(sourceId: sid, kind: .live).map(\.id), ["1", "7"])
    }

    /// A refresh replaces memberships atomically; deleting a source removes them.
    func testMembershipsFollowRefreshAndDelete() throws {
        let s1 = try catalog.beginRefresh(sourceId: "s1")
        try s1.write(series: [Series(sourceId: "s1", id: "a", name: "A", categoryId: "x", categoryIds: ["x", "y"])])
        XCTAssertTrue(try catalog.series(sourceId: "s1", categoryId: "y").isEmpty, "staged rows are invisible")
        try s1.commit()
        XCTAssertEqual(try catalog.series(sourceId: "s1", categoryId: "y").map(\.id), ["a"])

        let s2 = try catalog.beginRefresh(sourceId: "s1")
        try s2.write(series: [Series(sourceId: "s1", id: "a", name: "A", categoryId: "x")])
        s2.abort()
        XCTAssertEqual(try catalog.series(sourceId: "s1", categoryId: "y").map(\.id), ["a"], "aborted refresh keeps old memberships")

        let s3 = try catalog.beginRefresh(sourceId: "s1")
        try s3.write(series: [Series(sourceId: "s1", id: "a", name: "A", categoryId: "x")])
        try s3.commit()
        XCTAssertTrue(try catalog.series(sourceId: "s1", categoryId: "y").isEmpty)
        XCTAssertEqual(try catalog.series(sourceId: "s1", categoryId: "x").map(\.id), ["a"])

        try catalog.deleteContent(sourceId: "s1")
        XCTAssertEqual(try database.db.scalar("SELECT COUNT(*) FROM item_categories"), 0)
    }

    /// Payloads encoded before `categoryIds` existed still decode: the field defaults to `[categoryId]`
    /// (or empty without a category); new payloads round-trip it.
    func testOldPayloadsWithoutCategoryIdsDecode() throws {
        let decoder = JSONDecoder()
        let channel = try decoder.decode(Channel.self, from: Data(#"""
            {"sourceId":"s","id":"c1","name":"C","categoryId":"news","catchup":{"type":"none","days":0},"drm":false,"sort":3}
            """#.utf8))
        XCTAssertEqual(channel.categoryIds, ["news"])
        XCTAssertEqual(channel.sort, 3)
        let movie = try decoder.decode(Movie.self, from: Data(#"{"sourceId":"s","id":"m1","name":"M","sort":0}"#.utf8))
        XCTAssertEqual(movie.categoryIds, [])
        let series = try decoder.decode(Series.self, from: Data(#"{"sourceId":"s","id":"d1","name":"D","categoryId":"tr","sort":1}"#.utf8))
        XCTAssertEqual(series.categoryIds, ["tr"])
        let multi = Series(sourceId: "s", id: "d2", name: "D2", categoryId: "x", categoryIds: ["x", "y"])
        XCTAssertEqual(try decoder.decode(Series.self, from: JSONEncoder().encode(multi)), multi)
    }
}
