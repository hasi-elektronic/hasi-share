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
/// A `.paused` AVPlayer status is a user pause only when the user did not ask to play (or the item
/// ended/failed). Task 4c: the simulator's frozen tuned start fell to `.paused` once the relax timer had
/// re-enabled stall-waiting – AVPlayer reported paused while the user still wanted to play.
final class AVPlayerEnginePausedStatusTests: XCTestCase {
    func testStallWithWaitingDisabledBecomesBuffering() {
        XCTAssertEqual(AVPlayerEngine.eventForPausedStatus(wantsToPlay: true, itemFinished: false), .buffering)
    }
    func testUserPauseStaysPaused() {
        XCTAssertEqual(AVPlayerEngine.eventForPausedStatus(wantsToPlay: false, itemFinished: false), .paused)
        XCTAssertEqual(AVPlayerEngine.eventForPausedStatus(wantsToPlay: false, itemFinished: true), .paused)
    }
    /// Any time, not only in the stall-wait-off window: paused while wanting to play = stall.
    func testPauseWithoutUserIntentIsAStallAtAnyTime() {
        XCTAssertEqual(AVPlayerEngine.eventForPausedStatus(wantsToPlay: true, itemFinished: false), .buffering)
    }
    /// End of a VOD or a failed item: nothing to resume.
    func testFinishedItemStaysPaused() {
        XCTAssertEqual(AVPlayerEngine.eventForPausedStatus(wantsToPlay: true, itemFinished: true), .paused)
    }
    /// With stall-waiting off, `play()` before the item is ready can leave AVPlayer at rate 1 with a
    /// frozen clock; the engine re-issues `play()` once the item is ready.
    func testStartKickOnlyForTunedStartWhileWantingToPlay() {
        XCTAssertTrue(AVPlayerEngine.needsStartKick(wantsToPlay: true, stallWaitEnabled: false))
        XCTAssertFalse(AVPlayerEngine.needsStartKick(wantsToPlay: true, stallWaitEnabled: true))
        XCTAssertFalse(AVPlayerEngine.needsStartKick(wantsToPlay: false, stallWaitEnabled: false))
    }
    /// Unexpected pauses are resumed at most once per second (the controller's stall timeout bounds the rest).
    func testResumeThrottle() {
        XCTAssertEqual(AVPlayerEngine.resumeDelayMs(sinceLastResumeMs: nil), 0)
        XCTAssertEqual(AVPlayerEngine.resumeDelayMs(sinceLastResumeMs: 1_500), 0)
        XCTAssertEqual(AVPlayerEngine.resumeDelayMs(sinceLastResumeMs: 300), 700)
        XCTAssertEqual(AVPlayerEngine.resumeDelayMs(sinceLastResumeMs: 0), 1_000)
    }
}

/// The first `.playing` of a load is only forwarded once the item is ready (real first frame);
/// before that the engine reports `.buffering`, so PerfTrace's firstFrame / zap times are not understated.
final class AVPlayerEnginePlayingStatusTests: XCTestCase {
    func testFirstPlayingWaitsForReadyItem() {
        XCTAssertEqual(AVPlayerEngine.eventForPlayingStatus(firstPlayingEmitted: false, itemReady: false), .buffering)
        XCTAssertEqual(AVPlayerEngine.eventForPlayingStatus(firstPlayingEmitted: false, itemReady: true), .playing)
    }
    func testLaterPlayingIsUnchanged() {
        XCTAssertEqual(AVPlayerEngine.eventForPlayingStatus(firstPlayingEmitted: true, itemReady: false), .playing)
        XCTAssertEqual(AVPlayerEngine.eventForPlayingStatus(firstPlayingEmitted: true, itemReady: true), .playing)
    }
}
#endif
