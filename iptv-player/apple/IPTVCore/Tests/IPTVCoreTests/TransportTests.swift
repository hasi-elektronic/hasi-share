import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import IPTVCore

/// `URLSessionTransport` + loaders/clients against a mock `URLProtocol` (CONTRACT §2 error
/// taxonomy, retries, timeouts; §5 gzip).
final class TransportTests: XCTestCase {
    private func uniqueHost(_ name: String = #function) -> String {
        "\(name.filter(\.isLetter).lowercased()).\(UUID().uuidString.prefix(8).lowercased()).test"
    }

    private func transport(host: String, _ handler: @escaping MockURLProtocol.Handler) -> URLSessionTransport {
        URLSessionTransport(configuration: MockURLProtocol.register(host: host, handler))
    }

    private func xtream(_ transport: HTTPTransport, host: String) throws -> XtreamClient {
        try XCTUnwrap(XtreamClient(sourceId: "s", secrets: XtreamSecrets(serverUrl: "http://\(host)", username: "u", password: "p w"),
                                   transport: transport, sleeper: .immediate))
    }

    private func expect<T>(_ expected: SourceError, _ body: () async throws -> T,
                           file: StaticString = #filePath, line: UInt = #line) async {
        do {
            _ = try await body()
            XCTFail("expected \(expected)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? SourceError, expected, file: file, line: line)
        }
    }

    // MARK: Buffered (Xtream JSON)

    func testJSONSuccessAndRequestShape() async throws {
        let host = uniqueHost()
        let body = try Vectors.data("xtream/live_streams.json")
        let t = transport(host: host) { _, _ in .body(body, headers: ["Content-Type": "application/json"]) }
        let channels = try await xtream(t, host: host).liveStreams()
        XCTAssertEqual(channels.map(\.id), ["1001", "1002", "2001"])
        let request = try XCTUnwrap(MockURLProtocol.requests(host: host).first)
        XCTAssertEqual(request.url?.absoluteString, "http://\(host)/player_api.php?username=u&password=p%20w&action=get_live_streams")
        XCTAssertEqual(request.httpMethod, "GET")
    }

    func testHTTPStatusMapping() async throws {
        for (status, expected) in [(401, SourceError.invalidCredentials), (403, .invalidCredentials), (404, .notFound),
                                   (418, .serverError(httpStatus: 418))] {
            let host = uniqueHost() + "\(status)"
            let t = transport(host: host) { _, _ in .text("<html>nope</html>", status: status) }
            await expect(expected) { try await self.xtream(t, host: host).liveStreams() }
            XCTAssertEqual(MockURLProtocol.requests(host: host).count, 1, "4xx is never retried (\(status))")
        }
    }

    func testServerErrorsAreRetriedTwiceThenReported() async throws {
        let host = uniqueHost()
        let t = transport(host: host) { _, _ in .text("busy", status: 503) }
        await expect(.serverError(httpStatus: 503)) { try await self.xtream(t, host: host).vodStreams() }
        XCTAssertEqual(MockURLProtocol.requests(host: host).count, 3)

        // Recovers on the second retry.
        let host2 = uniqueHost() + "b"
        let ok = try Vectors.data("xtream/vod_streams.json")
        let t2 = transport(host: host2) { _, attempt in attempt < 3 ? .text("", status: 502) : .body(ok) }
        let movies = try await xtream(t2, host: host2).vodStreams()
        XCTAssertEqual(movies.count, 2)
        XCTAssertEqual(MockURLProtocol.requests(host: host2).count, 3)
    }

    func testRetryDelaysFollowContract() async throws {
        let host = uniqueHost()
        let t = transport(host: host) { _, _ in .failure(.timedOut) }
        let delays = LockedArray<TimeInterval>()
        let sleeper = Sleeper { delays.append($0) }
        let client = try XCTUnwrap(XtreamClient(sourceId: "s", secrets: XtreamSecrets(serverUrl: host, username: "u", password: "p"),
                                                transport: t, sleeper: sleeper))
        await expect(.network(.timeout)) { try await client.liveCategories() }
        XCTAssertEqual(delays.values, [2, 4])
    }

    func testHTMLInsteadOfJSONIsInvalidResponse() async throws {
        let host = uniqueHost()
        let t = transport(host: host) { _, _ in .text("<html><body>Access denied</body></html>") }
        await expect(.invalidResponse) { try await self.xtream(t, host: host).series() }
        await expect(.invalidResponse) { try await self.xtream(t, host: host).authenticate() }
        XCTAssertEqual(MockURLProtocol.requests(host: host).count, 2, "invalid bodies are not retried")
    }

    func testTransportErrorsMapToNetworkReasons() async throws {
        let cases: [(URLError.Code, NetworkReason)] = [
            (.timedOut, .timeout), (.cannotFindHost, .dns), (.cannotConnectToHost, .refused),
            (.serverCertificateUntrusted, .tls), (.notConnectedToInternet, .offline), (.badURL, .other),
        ]
        for (code, reason) in cases {
            let host = uniqueHost() + "\(code.rawValue)".filter(\.isNumber)
            let t = transport(host: host) { _, _ in .failure(code) }
            await expect(.network(reason)) { try await self.xtream(t, host: host).liveCategories() }
        }
    }

    func testWholeCallTimeout() async throws {
        let host = uniqueHost()
        let t = transport(host: host) { _, _ in MockReply(status: 200, chunks: [Data("[]".utf8)], delay: 3) }
        let request = HTTPRequest(url: URL(string: "http://\(host)/slow")!, timeouts: HTTPTimeouts(connect: 1, read: 30, total: 0.3))
        let started = Date()
        do {
            _ = try await t.send(request)
            XCTFail("expected a timeout")
        } catch {
            XCTAssertEqual(ErrorClassifier.sourceError(from: error), .network(.timeout))
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 2.5)
    }

    func testCancellationYieldsCancelled() async throws {
        let host = uniqueHost()
        let t = transport(host: host) { _, _ in MockReply(status: 200, chunks: [Data("[]".utf8)], delay: 5) }
        let client = try xtream(t, host: host)
        let task = Task { try await client.liveStreams() }
        try await Task.sleep(nanoseconds: 100_000_000)
        task.cancel()
        let started = Date()
        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch {
            XCTAssertEqual(error as? SourceError, .cancelled)
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
    }

    // MARK: Streaming (playlists, EPG)

    func testM3UStreamsInChunks() async throws {
        let host = uniqueHost()
        let data = try Vectors.data("m3u/valid_basic.m3u")
        let t = transport(host: host) { _, _ in .body(data, headers: ["Content-Type": "audio/x-mpegurl"], chunkSize: 100) }
        let loader = M3USourceLoader(transport: t, sleeper: .immediate)
        var entries: [M3UEntry] = []
        let summary = try await loader.load(M3USecrets(url: "http://\(host)/list.m3u", userAgent: "TestUA/1"), batchSize: 3) {
            entries.append(contentsOf: $0)
        }
        XCTAssertEqual(entries, try M3UPlaylist.parse(data: data).entries)
        XCTAssertEqual(summary.epgUrls.count, 2)
        XCTAssertEqual(MockURLProtocol.requests(host: host).first?.value(forHTTPHeaderField: "User-Agent"), "TestUA/1")
    }

    func testM3UErrors() async throws {
        let html = uniqueHost() + "html"
        let tHTML = transport(host: html) { _, _ in .text("<html><body>Error</body></html>") }
        await expect(.invalidFormat) {
            try await M3USourceLoader(transport: tHTML, sleeper: .immediate).load(M3USecrets(url: "http://\(html)/x.m3u")) { _ in }
        }
        let missing = uniqueHost() + "missing"
        let t404 = transport(host: missing) { _, _ in .text("", status: 404) }
        await expect(.notFound) {
            try await M3USourceLoader(transport: t404, sleeper: .immediate).load(M3USecrets(url: "http://\(missing)/x.m3u")) { _ in }
        }
        let busy = uniqueHost() + "busy"
        let t500 = transport(host: busy) { _, _ in .text("", status: 500) }
        await expect(.serverError(httpStatus: 500)) {
            try await M3USourceLoader(transport: t500, sleeper: .immediate).load(M3USecrets(url: "http://\(busy)/x.m3u")) { _ in }
        }
        XCTAssertEqual(MockURLProtocol.requests(host: busy).count, 3)
        await expect(.invalidFormat) {
            try await M3USourceLoader(transport: t500, sleeper: .immediate).load(M3USecrets(url: "ftp://h/x.m3u")) { _ in }
        }
    }

    func testGzipEPGIsInflatedWhileStreaming() async throws {
        let host = uniqueHost()
        let xml = try Vectors.data("xmltv/epg_basic.xml")
        let gz = try Gzip.compress(xml)
        // Served as a file download (no Content-Encoding), split into small chunks so the
        // magic bytes and the deflate stream cross chunk boundaries.
        let t = transport(host: host) { _, _ in .body(gz, headers: ["Content-Type": "application/gzip"], chunkSize: 1) }
        var programmes: [XMLTVProgramme] = []
        var channels: [XMLTVChannel] = []
        let summary = try await XMLTVLoader(transport: t, sleeper: .immediate)
            .load(url: URL(string: "http://\(host)/guide.xml.gz")!, options: XMLTVParseOptions(preferredLanguage: "tr"),
                  onChannel: { channels.append($0) }, onProgrammes: { programmes.append(contentsOf: $0) })
        XCTAssertEqual(summary.programmeCount, 6)
        XCTAssertEqual(channels.count, 2)
        XCTAssertTrue(programmes.contains { $0.title == "Akşam Haberleri" })

        // Plain XML through the same path.
        let plain = uniqueHost() + "plain"
        let tPlain = transport(host: plain) { _, _ in .body(xml, headers: ["Content-Type": "text/xml"], chunkSize: 500) }
        let plainSummary = try await XMLTVLoader(transport: tPlain, sleeper: .immediate)
            .load(url: URL(string: "http://\(plain)/guide.xml")!, onChannel: { _ in }, onProgrammes: { _ in })
        XCTAssertEqual(plainSummary.programmeCount, 6)
    }

    func testBrokenGzipAndHTMLEPGAreInvalidFormat() async throws {
        let host = uniqueHost()
        let gz = try Gzip.compress(Data(String(repeating: "<tv></tv>", count: 100).utf8))
        let t = transport(host: host) { _, _ in .body(gz.prefix(gz.count / 2), chunkSize: 7) }
        await expect(.invalidFormat) {
            try await XMLTVLoader(transport: t, sleeper: .immediate)
                .load(url: URL(string: "http://\(host)/g.xml.gz")!, onChannel: { _ in }, onProgrammes: { _ in })
        }
        let html = uniqueHost() + "html"
        let tHTML = transport(host: html) { _, _ in .text("<!DOCTYPE html><html><body>403</body></html>") }
        await expect(.invalidFormat) {
            try await XMLTVLoader(transport: tHTML, sleeper: .immediate)
                .load(url: URL(string: "http://\(html)/g.xml")!, onChannel: { _ in }, onProgrammes: { _ in })
        }
    }

    func testStreamCollectAndHeaders() async throws {
        let host = uniqueHost()
        let t = transport(host: host) { _, _ in .body(Data("abcdef".utf8), headers: ["X-Thing": "1"], chunkSize: 2) }
        let response = try await t.stream(HTTPRequest(url: URL(string: "http://\(host)/s")!, timeouts: .playlist))
        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(response.header("x-thing"), "1")
        let collected = try await response.collect()
        XCTAssertEqual(collected, Data("abcdef".utf8))
    }
}

final class LockedArray<Element: Sendable>: @unchecked Sendable {   // guarded by `lock`
    private let lock = NSLock()
    private var storage: [Element] = []
    func append(_ e: Element) { lock.withLock { storage.append(e) } }
    var values: [Element] { lock.withLock { storage } }
}
