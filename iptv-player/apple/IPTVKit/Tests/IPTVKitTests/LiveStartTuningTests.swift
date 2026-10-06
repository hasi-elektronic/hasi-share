import XCTest
@testable import IPTVKit

final class LiveStartTuningTests: XCTestCase {
    func testLiveDefaults() {
        let t = LiveStartTuning.make(isLive: true, largeBuffer: false)
        XCTAssertEqual(t.forwardBufferSeconds, 1)
        XCTAssertEqual(t.waitToMinimizeStallingAfter, 3)
        XCTAssertEqual(t.initialPeakBitRate, 2_500_000)
        XCTAssertEqual(t.peakBitRateReleaseAfter, 4)
        XCTAssertEqual(t.vlcNetworkCachingMs, 1000)
    }
    func testLargeBufferAndVOD() {
        XCTAssertEqual(LiveStartTuning.make(isLive: true, largeBuffer: true).vlcNetworkCachingMs, 3000)
        XCTAssertNil(LiveStartTuning.make(isLive: true, largeBuffer: true).initialPeakBitRate)
        let vod = LiveStartTuning.make(isLive: false, largeBuffer: false)
        XCTAssertEqual(vod.forwardBufferSeconds, 0)
        XCTAssertNil(vod.initialPeakBitRate)
        XCTAssertEqual(vod.vlcNetworkCachingMs, 2000)
    }
}
