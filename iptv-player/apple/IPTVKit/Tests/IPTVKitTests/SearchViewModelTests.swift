import XCTest
@testable import IPTVKit
import IPTVCore

/// The search screen shows channels, movies and series for one query even when movies dominate the catalog.
@MainActor
final class SearchViewModelTests: XCTestCase {
    private func makeEnvironment() async throws -> AppEnvironment {
        let m3u = try Data(contentsOf: vectorURL("m3u/valid_basic.m3u"))
        let transport = FakeTransport { _ in HTTPResponse(statusCode: 200, body: m3u) }
        let config = AppConfig(displayName: "Test", bundleId: "de.hasielektronik.novaplayer", appVersion: "1.0",
                               backendBaseURL: URL(string: "http://127.0.0.1:9")!, productIDs: ProductIDs(lifetime: "l", trial: "t"),
                               licenseKeysJSON: TestSigner().jwkSetJSON, platform: .ios, rawDeviceId: "device", deviceName: "Test")
        let env = try AppEnvironment(config: config, database: AppDatabase.inMemory(), secureStore: InMemorySecureStore(),
                                     kv: InMemoryKeyValueStore(), transport: transport)
        _ = try await env.addSource(name: "Test", secrets: .m3u(M3USecrets(url: "http://lists.example.com/list.m3u"))) { _ in }
        return env
    }

    func testHitsContainAllKindsOnMovieHeavyCatalog() async throws {
        let env = try await makeEnvironment()
        let sourceId = try XCTUnwrap(env.currentSource?.id)
        let session = try env.catalog.beginRefresh(sourceId: sourceId)
        try session.write(
            channels: (0..<40).map { TestData.channel(id: "c\($0)", sourceId: sourceId, name: "TR: TRT Zebra HD \($0)", sort: $0) },
            movies: (0..<1_500).map { Movie(sourceId: sourceId, id: "m\($0)", name: "Zebra \($0)", sort: $0) },
            series: (0..<20).map { Series(sourceId: sourceId, id: "t\($0)", name: "Zebra Serie \($0) Staffel", sort: $0) })
        try session.commit()

        let model = SearchViewModel(env: env)
        model.query = "zebra"
        try await Task.sleep(for: .milliseconds(600))   // 250 ms debounce + query
        XCTAssertEqual(model.hits.filter { $0.kind == .live }.count, 30)
        XCTAssertEqual(model.hits.filter { $0.kind == .movie }.count, 30)
        XCTAssertEqual(model.hits.filter { $0.kind == .series }.count, 20)
        XCTAssertEqual(model.hits.first?.kind, .live, "channels group first")
        XCTAssertNotNil(model.channel(try XCTUnwrap(model.hits.first)))

        model.query = "trt"
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(model.hits.map(\.kind), Array(repeating: .live, count: 30), "provider prefix 'TR:' does not block")
        model.query = ""
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertTrue(model.hits.isEmpty)
    }
}
