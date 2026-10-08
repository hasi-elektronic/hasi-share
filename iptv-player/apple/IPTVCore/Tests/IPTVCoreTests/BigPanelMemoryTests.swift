import Foundation
import XCTest
@testable import IPTVCore

/// Manual measurement (P3): peak memory of a full Xtream refresh against a big fake panel
/// (35 000 movies / 9 000 series / 4 000 channels). Skipped unless `NOVA_BIG_PANEL` is set, e.g.
/// `NOVA_BIG_PANEL=http://127.0.0.1:8781 swift test --filter BigPanelMemoryTests` (run alone: the
/// peak RSS (`ru_maxrss`) covers the whole test process).
final class BigPanelMemoryTests: XCTestCase {
    func testFullRefreshPeakMemory() async throws {
        guard let base = ProcessInfo.processInfo.environment["NOVA_BIG_PANEL"] else {
            throw XCTSkip("NOVA_BIG_PANEL not set")
        }
        let before = Self.peakResidentMB()
        let client = try XCTUnwrap(XtreamClient(sourceId: "big", secrets: XtreamSecrets(serverUrl: base, username: "big", password: "big")))
        let started = Date()
        let catalog = try await client.fetchCatalog()
        let seconds = Date().timeIntervalSince(started)
        let after = Self.peakResidentMB()
        print("BIGPANEL live=\(catalog.channels.count) movies=\(catalog.movies.count) series=\(catalog.series.count) "
              + "peakRSS_before=\(before)MB peakRSS_after=\(after)MB time=\(String(format: "%.1f", seconds))s")
        XCTAssertEqual(catalog.movies.count, 35_000)
    }

    static func peakResidentMB() -> Int {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        #if os(Linux)
        return Int(usage.ru_maxrss) / 1024
        #else
        return Int(usage.ru_maxrss) / (1024 * 1024)
        #endif
    }
}
