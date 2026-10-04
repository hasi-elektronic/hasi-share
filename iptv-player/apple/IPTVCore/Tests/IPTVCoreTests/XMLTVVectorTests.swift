import Foundation
import XCTest
@testable import IPTVCore

/// CONTRACT §5 – `spec/test-vectors/xmltv/*`.
final class XMLTVVectorTests: XCTestCase {
    func testTimeParsing() throws {
        let cases = try XCTUnwrap(Vectors.object("xmltv/time-parsing.json").arr("cases"))
        XCTAssertEqual(cases.count, 10)
        for c in cases {
            let input = try XCTUnwrap(c.str("input"))
            let expected = c.int64("expected")
            XCTAssertEqual(XMLTVTime.parseEpochSeconds(input), expected, "input '\(input)'")
        }
        XCTAssertNil(XMLTVTime.parse("20251304120000"))
        XCTAssertNil(XMLTVTime.parse("20250230120000"))
        XCTAssertEqual(XMLTVTime.parse("20251004120000 +0200"), XMLTVTime.parse("20251004120000 +02:00"))
    }

    func testNameNormalization() throws {
        let cases = try XCTUnwrap(Vectors.object("xmltv/name-normalization.json").arr("cases"))
        XCTAssertEqual(cases.count, 14)
        for c in cases {
            let input = try XCTUnwrap(c.str("input"))
            XCTAssertEqual(NameNormalizer.normalize(input), c.str("expected"), "input '\(input)'")
        }
    }

    private func xmlData(gzip: Bool) throws -> Data {
        let raw = try Vectors.data("xmltv/epg_basic.xml")
        guard gzip else { return raw }
        let compressed = try Gzip.compress(raw)
        XCTAssertTrue(Gzip.isGzip(compressed))
        return compressed
    }

    func testEpgBasicAllCasesPlainAndGzip() throws {
        let expected = try Vectors.object("xmltv/epg_basic.expected.json")
        let cases = try XCTUnwrap(expected.arr("cases"))
        XCTAssertEqual(cases.count, 3)
        for gzip in [false, true] {
            for c in cases {
                let language = try XCTUnwrap(c.str("language"))
                let shift = try XCTUnwrap(c.num("shiftMinutes")).intValue
                for batchSize in [1000, 1] {
                    let options = XMLTVParseOptions(preferredLanguage: language, shiftMinutes: shift, batchSize: batchSize)
                    let doc = try XMLTVParser.parse(data: try xmlData(gzip: gzip), options: options)
                    XCTAssertEqual(doc.summary.invalidCount, 2, "Zero length + Broken")
                    XCTAssertEqual(doc.summary.programmeCount, doc.programmes.count)
                    let label = "gzip=\(gzip) lang=\(language) shift=\(shift) batch=\(batchSize)"
                    assertJSONEqual(try XCTUnwrap(c["programmes"]), doc.programmes.map(Self.json), label)
                    assertJSONEqual(try XCTUnwrap(expected["channels"]), doc.channels.map(Self.json), label)
                }
            }
        }
    }

    static func json(_ p: XMLTVProgramme) -> [String: Any] {
        ["channel": p.channel, "start": epoch(p.start), "end": epoch(p.end), "title": p.title,
         "description": j(p.description), "category": j(p.category)]
    }

    static func json(_ c: XMLTVChannel) -> [String: Any] {
        ["id": c.id, "displayNames": c.displayNames, "icon": j(c.icon)]
    }

    func testFileParsingPlainAndGzipStreams() throws {
        let tmp = FileManager.default.temporaryDirectory
        for gzip in [false, true] {
            let file = tmp.appendingPathComponent("epg-test-\(UUID().uuidString).xml\(gzip ? ".gz" : "")")
            try xmlData(gzip: gzip).write(to: file)
            defer { try? FileManager.default.removeItem(at: file) }
            var channels: [XMLTVChannel] = []
            var programmes: [XMLTVProgramme] = []
            let summary = try XMLTVParser.parse(fileURL: file, options: XMLTVParseOptions(preferredLanguage: "en", batchSize: 2),
                                                onChannel: { channels.append($0) },
                                                onProgrammes: {
                                                    XCTAssertLessThanOrEqual($0.count, 2)
                                                    programmes.append(contentsOf: $0)
                                                })
            XCTAssertEqual(channels.map(\.id), ["trt1.tr", "ard.de"])
            XCTAssertEqual(programmes.count, 6)
            XCTAssertEqual(summary.programmeCount, 6)
            XCTAssertTrue(programmes.contains { $0.title == "Evening News" })
        }
    }

    func testRetentionWindowFiltersProgrammes() throws {
        let window = DateInterval(start: Date(timeIntervalSince1970: 1_759_591_800), end: Date(timeIntervalSince1970: 1_759_600_000))
        let doc = try XMLTVParser.parse(data: try xmlData(gzip: false),
                                        options: XMLTVParseOptions(preferredLanguage: "tr", window: window))
        XCTAssertTrue(doc.programmes.allSatisfy { EpgRetention.isRetained(start: $0.start, end: $0.end, in: window) })
        XCTAssertEqual(doc.summary.outsideWindowCount, 6 - doc.programmes.count)
        let now = Date(timeIntervalSince1970: 1_000_000_000)
        let w = EpgRetention.window(now: now, catchupDays: 0)
        XCTAssertEqual(w.start, now.addingTimeInterval(-86_400))
        XCTAssertEqual(w.end, now.addingTimeInterval(7 * 86_400))
        XCTAssertEqual(EpgRetention.window(now: now, catchupDays: 3).start, now.addingTimeInterval(-3 * 86_400))
    }

    func testInvalidDocumentsAreInvalidFormat() {
        for text in ["<!DOCTYPE html><html><body>403</body></html>", "not xml at all", "", #"<?xml version="1.0"?><rss/>"#] {
            XCTAssertThrowsError(try XMLTVParser.parse(data: Data(text.utf8)), text) {
                XCTAssertEqual($0 as? SourceError, .invalidFormat, text)
            }
        }
        // Corrupt gzip.
        XCTAssertThrowsError(try XMLTVParser.parse(data: Data([0x1F, 0x8B, 0x08, 0x00, 0xFF, 0xFF]))) {
            XCTAssertEqual($0 as? SourceError, .invalidFormat)
        }
    }

    func testTruncatedDocumentKeepsWhatWasParsed() throws {
        let xml = #"<tv><programme start="20251004120000" stop="20251004130000" channel="A"><title>T</title></programme><programme"#
        let doc = try XMLTVParser.parse(data: Data(xml.utf8))
        XCTAssertEqual(doc.programmes.map(\.title), ["T"])
        XCTAssertTrue(doc.summary.truncated)
    }

    func testNestedMarkupInDescription() throws {
        let xml = """
        <?xml version="1.0"?><tv><programme start="20251004120000" stop="20251004130000" channel="A">
        <title>Tom &amp; Jerry</title><desc><b>bold</b> text</desc></programme></tv>
        """
        let doc = try XMLTVParser.parse(data: Data(xml.utf8))
        XCTAssertEqual(doc.programmes.first?.title, "Tom & Jerry")
        XCTAssertEqual(doc.programmes.first?.description, "bold text")
    }

    func testEpgMatcher() throws {
        let doc = try XMLTVParser.parse(data: try xmlData(gzip: false))
        var m = EpgMatcher(channels: doc.channels)
        m.addId("orphan.id")
        XCTAssertEqual(m.match(epgId: "TRT1.TR", name: "whatever"), "trt1.tr")
        XCTAssertEqual(m.match(epgId: nil, name: "TRT 1 FHD"), "trt1.tr")
        XCTAssertEqual(m.match(epgId: "unknown", name: "TR: TRT 1"), "trt1.tr")
        XCTAssertEqual(m.match(epgId: "", name: "Das Erste (DE)"), "ard.de")
        XCTAssertEqual(m.match(epgId: "Orphan.ID", name: ""), "orphan.id")
        XCTAssertNil(m.match(epgId: "x", name: "ZDF"))
    }

    func testGzipRoundTripMultiMemberAndTruncation() throws {
        let a = Data(String(repeating: "hello gzip ", count: 10_000).utf8)
        let b = Data("second member".utf8)
        let ca = try Gzip.compress(a)
        XCTAssertEqual(try Gzip.decompress(ca), a)
        XCTAssertEqual(try Gzip.decompress(ca + (try Gzip.compress(b))), a + b)
        // Chunked inflation (1-byte chunks).
        let inflater = try GzipInflater()
        var out = Data()
        for byte in ca { try inflater.process(Data([byte])) { out.append($0) } }
        try inflater.finish()
        XCTAssertEqual(out, a)
        XCTAssertThrowsError(try Gzip.decompress(ca.prefix(ca.count / 2)))
    }
}
