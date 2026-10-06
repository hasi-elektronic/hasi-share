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
        let live = LiveStartTuning.make(isLive: true, largeBuffer: true)
        XCTAssertEqual(live.forwardBufferSeconds, 6)
        XCTAssertEqual(live.waitToMinimizeStallingAfter, 0)
        XCTAssertEqual(live.peakBitRateReleaseAfter, 0)
        XCTAssertEqual(LiveStartTuning.make(isLive: false, largeBuffer: true).vlcNetworkCachingMs, 4000)
    }
}

#if canImport(AVFoundation)
/// A `.paused` AVPlayer status is a user pause only when stall-waiting is on or the user did not ask to play.
final class AVPlayerEnginePausedStatusTests: XCTestCase {
    func testStallWithWaitingDisabledBecomesBuffering() {
        XCTAssertEqual(AVPlayerEngine.eventForPausedStatus(wantsToPlay: true, stallWaitEnabled: false), .buffering)
    }
    func testUserPauseStaysPaused() {
        XCTAssertEqual(AVPlayerEngine.eventForPausedStatus(wantsToPlay: false, stallWaitEnabled: false), .paused)
        XCTAssertEqual(AVPlayerEngine.eventForPausedStatus(wantsToPlay: false, stallWaitEnabled: true), .paused)
    }
    func testPauseWithWaitingEnabledStaysPaused() {
        XCTAssertEqual(AVPlayerEngine.eventForPausedStatus(wantsToPlay: true, stallWaitEnabled: true), .paused)
    }
}
#endif
