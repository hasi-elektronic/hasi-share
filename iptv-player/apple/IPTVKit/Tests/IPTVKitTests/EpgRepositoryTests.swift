import XCTest
@testable import IPTVKit
import IPTVCore

/// Case-insensitive EPG id matching (SQLite `lower()` folds ASCII only; ids with non-ASCII capitals such as
/// Turkish/Austrian channels must still match when asked for in the same spelling or a different ASCII case).
final class EpgRepositoryTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func makeRepo(ids: [String]) throws -> EpgRepository {
        let db = try AppDatabase.inMemory()
        let epg = EpgRepository(database: db)
        let s = try epg.beginRefresh(sourceId: "s")
        for id in ids {
            try s.write([EpgProgram(sourceId: "s", channelEpgId: id, start: now.addingTimeInterval(-600),
                                    end: now.addingTimeInterval(600), title: "Now \(id)"),
                         EpgProgram(sourceId: "s", channelEpgId: id, start: now.addingTimeInterval(600),
                                    end: now.addingTimeInterval(1800), title: "Next \(id)")])
        }
        try s.commit()
        return epg
    }

    func testProgramsMatchNonASCIIUppercaseIds() throws {
        let epg = try makeRepo(ids: ["ÖRF.at", "TÜRK.tr", "BBC.One"])
        let window = DateInterval(start: now, duration: 3600)
        for id in ["ÖRF.at", "TÜRK.tr", "BBC.One", "bbc.one", "BBC.ONE"] {
            XCTAssertEqual(try epg.programs(sourceId: "s", epgId: id, in: window).count, 2, id)
        }
        XCTAssertEqual(try epg.programs(sourceId: "s", epgId: "ÖRF.AT", in: window).count, 2, "ASCII part may differ in case")
        XCTAssertTrue(try epg.programs(sourceId: "s", epgId: "ORF.at", in: window).isEmpty)
    }

    func testNowNextMatchesNonASCIIUppercaseIds() throws {
        let epg = try makeRepo(ids: ["ÖRF.at", "TÜRK.tr", "BBC.One"])
        let map = try epg.nowNext(sourceId: "s", epgIds: ["ÖRF.at", "TÜRK.tr", "bbc.one"], at: now)
        // keyed by the Unicode-lowercased requested id (what the view models look up)
        XCTAssertEqual(map["ÖRF.at".lowercased()]?.now?.title, "Now ÖRF.at")
        XCTAssertEqual(map["TÜRK.tr".lowercased()]?.next?.title, "Next TÜRK.tr")
        XCTAssertEqual(map["bbc.one"]?.now?.title, "Now BBC.One")
        XCTAssertEqual(map.count, 3)
    }
}
