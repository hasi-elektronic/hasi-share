import Foundation
import XCTest
@testable import IPTVCore

/// CONTRACT §3 – `spec/test-vectors/m3u/*`.
final class M3UVectorTests: XCTestCase {
    private let fixtures = ["valid_basic", "no_header", "partially_broken", "empty", "empty_file", "broken_html"]

    func testEveryFixtureIsCovered() throws {
        let names = try Vectors.files(in: "m3u").filter { $0.hasSuffix(".m3u") }.map { String($0.dropLast(4)) }
        XCTAssertEqual(Set(names), Set(fixtures))
    }

    func testFixturesMatchExpected() throws {
        for name in fixtures {
            for batchSize in [1000, 1, 3] {
                try checkFixture(name, batchSize: batchSize, chunkSize: nil)
            }
            // Arbitrary chunk boundaries (inside lines, inside multi-byte UTF-8 sequences).
            for chunkSize in [1, 7, 64] {
                try checkFixture(name, batchSize: 2, chunkSize: chunkSize)
            }
        }
    }

    private func checkFixture(_ name: String, batchSize: Int, chunkSize: Int?) throws {
        let expected = try Vectors.object("m3u/\(name).expected.json")
        let data = try Vectors.data("m3u/\(name).m3u")
        var entries: [M3UEntry] = []
        var batches: [Int] = []
        let run = { () throws -> M3UParseSummary in
            var driver = M3UStreamParser(batchSize: batchSize)
            let onBatch: ([M3UEntry]) throws -> Void = {
                XCTAssertLessThanOrEqual($0.count, batchSize)
                batches.append($0.count)
                entries.append(contentsOf: $0)
            }
            if let chunkSize {
                var offset = 0
                while offset < data.count {
                    let end = min(offset + chunkSize, data.count)
                    try driver.consume(data.subdata(in: offset..<end), onBatch: onBatch)
                    offset = end
                }
            } else {
                try driver.consume(data, onBatch: onBatch)
            }
            return try driver.finish(onBatch: onBatch)
        }
        if let error = expected.str("error") {
            XCTAssertThrowsError(try run(), "\(name) should fail") { thrown in
                let expectedError: SourceError = error == "InvalidFormat" ? .invalidFormat : .empty
                XCTAssertEqual(thrown as? SourceError, expectedError, name)
            }
            return
        }
        let summary = try run()
        let actual: [String: Any] = [
            "epgUrls": summary.epgUrls,
            "skipped": summary.skipped,
            "entries": entries.map(Self.json),
        ]
        assertJSONEqual(expected, actual, "\(name)[batch=\(batchSize), chunk=\(chunkSize.map(String.init) ?? "-")]")
        XCTAssertEqual(summary.entryCount, entries.count)
        XCTAssertEqual(batches.reduce(0, +), entries.count)
    }

    static func json(_ e: M3UEntry) -> [String: Any] {
        [
            "name": e.name,
            "url": e.url,
            "kind": e.kind.rawValue,
            "tvgId": j(e.tvgId),
            "tvgName": j(e.tvgName),
            "logo": j(e.logo),
            "group": j(e.group),
            "chno": j(e.chno),
            "duration": e.duration,
            "catchup": j(e.catchup.map { ["type": $0.type.rawValue, "days": $0.days, "source": j($0.source)] as [String: Any] }),
            "tvgShiftHours": j(e.tvgShiftHours),
            "userAgent": j(e.userAgent),
            "referrer": j(e.referrer),
            "drm": e.drm,
            "series": j(e.series.map { ["name": $0.name, "season": $0.season, "episode": $0.episode] as [String: Any] }),
        ]
    }

    func testAllDriversAgree() async throws {
        let data = try Vectors.data("m3u/valid_basic.m3u")
        let reference = try M3UPlaylist.parse(data: data)
        XCTAssertEqual(reference.entries.count, 10)
        XCTAssertEqual(reference.skipped, 0)

        // CRLF line endings and no trailing newline give the same result.
        let crlf = String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\n", with: "\r\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(try M3UPlaylist.parse(data: Data(crlf.utf8)).entries, reference.entries)

        // Async chunk sequence.
        let chunks = AsyncThrowingStream<Data, Error> { c in
            var offset = 0
            while offset < data.count {
                let end = min(offset + 13, data.count)
                c.yield(data.subdata(in: offset..<end))
                offset = end
            }
            c.finish()
        }
        var fromChunks: [M3UEntry] = []
        try await M3UPlaylist.parse(chunks: chunks, batchSize: 4) { fromChunks.append(contentsOf: $0) }
        XCTAssertEqual(fromChunks, reference.entries)

        // Async bytes.
        let bytes = AsyncStream<UInt8> { c in
            for b in data { c.yield(b) }
            c.finish()
        }
        var fromBytes: [M3UEntry] = []
        try await M3UPlaylist.parse(bytes: bytes) { fromBytes.append(contentsOf: $0) }
        XCTAssertEqual(fromBytes, reference.entries)

        // Async lines.
        let lines = AsyncStream<String> { c in
            // "\r\n" is one Character in Swift; split on UTF-16 so lines keep their trailing "\r".
            for line in crlf.components(separatedBy: "\n") { c.yield(line) }
            c.finish()
        }
        var fromLines: [M3UEntry] = []
        try await M3UPlaylist.parse(lines: lines) { fromLines.append(contentsOf: $0) }
        XCTAssertEqual(fromLines, reference.entries)

        // File.
        var fromFile: [M3UEntry] = []
        try M3UPlaylist.parse(fileURL: Vectors.url("m3u/valid_basic.m3u")) { fromFile.append(contentsOf: $0) }
        XCTAssertEqual(fromFile, reference.entries)
    }

    func testTitleSplittingAndAttributes() throws {
        func parse(_ extinf: String) throws -> M3UEntry {
            try XCTUnwrap(M3UPlaylist.parse(data: Data("#EXTM3U\n\(extinf)\nhttp://h/x/1.ts\n".utf8)).entries.first)
        }
        // A comma inside a quoted value does not split the title.
        let a = try parse("#EXTINF:-1 group-title='A, B',Title, with comma")
        XCTAssertEqual(a.group, "A, B")
        XCTAssertEqual(a.name, "Title, with comma")
        // Unbalanced quotes: split at the last comma; unterminated value runs to the end of head.
        let b = try parse(#"#EXTINF:-1 tvg-name="Unclosed quote,Weird"#)
        XCTAssertEqual(b.name, "Weird")
        XCTAssertEqual(b.tvgName, "Unclosed quote")
        // No title → tvg-name; neither → last path segment.
        XCTAssertEqual(try parse(#"#EXTINF:-1 x="a,b""#).name, "1.ts")
        XCTAssertEqual(try parse(#"#EXTINF:-1 tvg-name="TV",  "#).name, "TV")
        XCTAssertEqual(try parse("#EXTINF:-1").name, "1.ts")
        // A quote not directly after '=' does not open a quoted section.
        XCTAssertEqual(try parse(#"#EXTINF:-1 a=b "c,d"#).name, "d")
        // Keys are case-insensitive, empty values are null, first occurrence wins? (last write wins in both cores)
        let c = try parse(#"#EXTINF:5.5 TVG-ID="x" tvg-logo="" group-title=Unquoted tvg-chno=" 7 ",T"#)
        XCTAssertEqual(c.tvgId, "x")
        XCTAssertNil(c.logo)
        XCTAssertEqual(c.group, "Unquoted")
        XCTAssertEqual(c.chno, 7)
        XCTAssertEqual(c.duration, 5.5)
        XCTAssertEqual(try parse("#EXTINF:abc,T").duration, -1)
        // Catch-up defaults.
        let d = try parse(#"#EXTINF:-1 timeshift="3",T"#)
        XCTAssertEqual(d.catchup, CatchupInfo(type: .default, days: 3, source: nil))
    }

    func testClassificationAndSeries() throws {
        func kind(_ url: String, _ title: String) throws -> M3UEntryKind {
            try XCTUnwrap(M3UPlaylist.parse(data: Data("#EXTINF:-1,\(title)\n\(url)\n".utf8)).entries.first).kind
        }
        XCTAssertEqual(try kind("http://h/movie/u/p/1.ts", "X S01E01"), .movie)
        XCTAssertEqual(try kind("http://h/series/u/p/1.ts", "X"), .episode)
        XCTAssertEqual(try kind("http://h/a/b.MP4?x=1", "Film"), .movie)
        XCTAssertEqual(try kind("http://h/a/b.mkv", "Show s1e10"), .episode)
        XCTAssertEqual(try kind("http://h/a/b.ts", "Show S01E01"), .live)
        XCTAssertEqual(try kind("RTP://239.1.1.1:5000", "Multicast"), .live)
        XCTAssertEqual(SeriesTitleMatcher.match("Dark - S02 E103 [720p]"), M3USeriesInfo(name: "Dark", season: 2, episode: 103))
        XCTAssertEqual(SeriesTitleMatcher.match("The Office.S03E05.720p"), M3USeriesInfo(name: "The Office", season: 3, episode: 5))
        XCTAssertNil(SeriesTitleMatcher.match("Season 1 Episode 2"))
        XCTAssertNil(SeriesTitleMatcher.match("Show S01E1234"))
        XCTAssertNil(SeriesTitleMatcher.match("Show S01E12x"))
    }

    func testCatalogBuilderBuildsDomainObjects() throws {
        let entries = try M3UPlaylist.parse(data: Vectors.data("m3u/valid_basic.m3u")).entries
        var builder = M3UCatalogBuilder(sourceId: "src1")
        let first = builder.add(Array(entries.prefix(5)))
        let second = builder.add(Array(entries.dropFirst(5)))
        XCTAssertEqual(first.channels.count, 5)
        XCTAssertEqual(first.channels[0].id, ContentKey.m3uItemId(entryUrl: entries[0].url))
        XCTAssertEqual(first.channels[0].catchup.type, .default)
        XCTAssertEqual(first.channels[0].catchup.days, 7)
        XCTAssertEqual(first.channels[0].epgId, "trt1.tr")
        XCTAssertTrue(first.channels[4].drm)
        XCTAssertEqual(first.channels.map(\.sort), [0, 1, 2, 3, 4])
        XCTAssertEqual(second.movies.map(\.name), ["Inception (2010)", "Local Movie.Night"])
        XCTAssertEqual(second.movies.first?.containerExt, "mkv")
        XCTAssertEqual(second.series.map(\.name), ["Breaking Bad", "The Office"])
        XCTAssertEqual(second.episodes.map { [$0.season, $0.number] }, [[1, 2], [3, 5]])
        XCTAssertEqual(second.episodes.first?.seriesId, second.series.first?.id)
        XCTAssertEqual(second.channels.count, 1)
        XCTAssertEqual(second.channels.first?.sort, 5)
        XCTAssertEqual(builder.liveCount, 6)
    }

    func testOverlongLinesAreTruncatedNotBuffered() throws {
        let big = "#EXTINF:-1 tvg-logo=\"" + String(repeating: "x", count: 3_000_000) + "\",Huge\nhttp://h/1.ts\n"
        let text = "#EXTM3U\n" + big + "#EXTINF:-1,Ok\nhttp://h/2.ts\n"
        let entries = try M3UPlaylist.parse(data: Data(text.utf8)).entries
        // The truncated EXTINF lost its title (comma beyond the limit) → name from the URL.
        XCTAssertEqual(entries.map(\.name), ["1.ts", "Ok"])
    }
}
