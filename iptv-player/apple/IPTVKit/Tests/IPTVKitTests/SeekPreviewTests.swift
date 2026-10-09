import Foundation
import IPTVCore
import XCTest
@testable import IPTVKit

/// tvOS preview-then-commit seeking (SCREENS §3.7): target accumulation, acceleration, clamping,
/// idle commit, cancel, swipe mapping and the thumbnail safety gate / throttle.
final class SeekPreviewTests: XCTestCase {
    // MARK: Target

    func testPressesAccumulateFromTheOrigin() {
        var p = SeekPreview(origin: 100, duration: 3_600, nowMs: 0)
        p.step(direction: 1, heldMs: 0, nowMs: 100)
        p.step(direction: 1, heldMs: 0, nowMs: 200)
        p.step(direction: 1, heldMs: 0, nowMs: 300)
        XCTAssertEqual(p.target, 130)
        XCTAssertEqual(p.delta, 30)
        XCTAssertEqual(SeekPreview.deltaText(p.delta), "+0:30")
        p.step(direction: -1, heldMs: 0, nowMs: 400)
        XCTAssertEqual(p.delta, 20)
        XCTAssertEqual(p.fraction ?? -1, 120.0 / 3_600, accuracy: 1e-9)
    }

    /// B-19: a hold that runs into the end commits 10 s before it on idle; OK may still go to the end.
    func testAutoCommitStopsBeforeTheEnd() {
        var p = SeekPreview(origin: 45, duration: 180, nowMs: 0)
        for heldMs in stride(from: Int64(400), through: 3_100, by: 300) { p.step(direction: 1, heldMs: heldMs, nowMs: heldMs) }
        XCTAssertEqual(p.target, 180, "the target itself reaches the end")
        XCTAssertEqual(p.autoCommitTarget, 170)
        let near = SeekPreview(origin: 30, duration: 180, nowMs: 0)
        XCTAssertEqual(near.autoCommitTarget, 30, "targets before the margin are unchanged")
        let unknown = SeekPreview(origin: 500, duration: 0, nowMs: 0)
        XCTAssertEqual(unknown.autoCommitTarget, 500)
        let short = SeekPreview(origin: 2, duration: 5, nowMs: 0)
        XCTAssertEqual(short.autoCommitTarget, 0, "never negative")
    }

    func testHeldStepsAccelerate() {
        var p = SeekPreview(origin: 0, duration: 10_000, nowMs: 0)
        // TVHoldSeek: first repeat at 0.4 s, then every 0.3 s.
        for heldMs in stride(from: Int64(400), through: 5_200, by: 300) {
            p.step(direction: 1, heldMs: heldMs, nowMs: heldMs)
        }
        // 400,700 → 10 · 1000…2800 (7) → 30 · 3100…4900 (7) → 60 · 5200 → 120
        let expected: Double = 2 * 10 + 7 * 30 + 7 * 60 + 120
        XCTAssertEqual(p.target, expected)
    }

    func testTargetIsClampedToTheItem() {
        var p = SeekPreview(origin: 50, duration: 120, nowMs: 0)
        for _ in 0..<10 { p.step(direction: 1, heldMs: 0, nowMs: 1) }
        XCTAssertEqual(p.target, 120, "upper bound = duration")
        for _ in 0..<30 { p.step(direction: -1, heldMs: 0, nowMs: 2) }
        XCTAssertEqual(p.target, 0, "lower bound = 0")
        XCTAssertEqual(SeekPreview.deltaText(p.delta), "\u{2212}0:50")
    }

    func testUnknownDurationHasNoUpperBoundAndNoFraction() {
        var p = SeekPreview(origin: 30, duration: 0, nowMs: 0)
        for _ in 0..<5 { p.step(direction: 1, heldMs: 5_000, nowMs: 1) }
        XCTAssertEqual(p.target, 630)
        XCTAssertNil(p.fraction)
    }

    // MARK: Idle commit / cancel

    func testCommitIsDueAfterIdle() {
        var p = SeekPreview(origin: 0, duration: 600, nowMs: 1_000)
        p.step(direction: 1, heldMs: 0, nowMs: 1_000)
        XCTAssertFalse(p.isCommitDue(nowMs: 1_799))
        XCTAssertTrue(p.isCommitDue(nowMs: 1_800))
        // Another press restarts the idle window.
        p.step(direction: 1, heldMs: 0, nowMs: 1_700)
        XCTAssertFalse(p.isCommitDue(nowMs: 2_000))
        XCTAssertTrue(p.isCommitDue(nowMs: 2_500))
    }

    func testRestingFingerBlocksTheIdleCommit() {
        var p = SeekPreview(origin: 0, duration: 600, nowMs: 0)
        p.beginPan(nowMs: 0)
        p.pan(translation: 0.1, nowMs: 100)
        XCTAssertFalse(p.isCommitDue(nowMs: 5_000), "finger still on the surface")
        p.endPan(nowMs: 5_000)
        XCTAssertFalse(p.isCommitDue(nowMs: 5_500))
        XCTAssertTrue(p.isCommitDue(nowMs: 5_800))
    }

    /// Cancel = the view drops the preview: nothing in it seeks, the origin is untouched.
    func testCancelLeavesTheOrigin() {
        var p = SeekPreview(origin: 75, duration: 600, nowMs: 0)
        p.step(direction: 1, heldMs: 0, nowMs: 0)
        XCTAssertEqual(p.origin, 75)
        XCTAssertNotEqual(p.target, p.origin)
    }

    // MARK: Swipe

    func testSwipeSpanIsFiveMinutesOrTenPercent() {
        XCTAssertEqual(SeekPreview.swipeSpanSeconds(duration: 1_200), 300, "20 min film: 5 min")
        XCTAssertEqual(SeekPreview.swipeSpanSeconds(duration: 7_200), 720, "2 h film: 10 %")
        XCTAssertEqual(SeekPreview.swipeSpanSeconds(duration: 0), 300, "unknown: 5 min")
    }

    func testSwipeFollowsTheFingerWithoutMomentum() {
        var p = SeekPreview(origin: 1_000, duration: 7_200, nowMs: 0)
        p.step(direction: 1, heldMs: 0, nowMs: 0)   // 1010
        p.beginPan(nowMs: 10)
        p.pan(translation: 0.5, nowMs: 20)
        XCTAssertEqual(p.target, 1_010 + 360, accuracy: 1e-9, "half swipe of a 2 h film = 6 min")
        p.pan(translation: -0.25, nowMs: 30)
        XCTAssertEqual(p.target, 1_010 - 180, accuracy: 1e-9, "relative to where the swipe began")
        p.endPan(nowMs: 40)
        XCTAssertEqual(p.target, 1_010 - 180, accuracy: 1e-9, "lifting the finger adds nothing")
        p.beginPan(nowMs: 50)
        p.pan(translation: 10, nowMs: 60)
        XCTAssertEqual(p.target, 7_200, "clamped")
    }

    func testClockTexts() {
        XCTAssertEqual(SeekPreview.deltaText(0), "+0:00")
        XCTAssertEqual(SeekPreview.deltaText(150), "+2:30")
        XCTAssertEqual(SeekPreview.deltaText(-3_723), "\u{2212}1:02:03")
        XCTAssertEqual(SeekPreview.shortClock(65), "1:05")
    }

    // MARK: Thumbnail gate

    private let mp4 = ResolvedStream(url: URL(string: "http://cdn.example.com/films/sintel.mp4")!, container: .mp4, headers: [:])

    private func movieRequest(source: Source?, url: String? = "http://cdn.example.com/films/sintel.mp4") -> PlaybackRequest {
        PlaybackRequest(item: .movie(Movie(sourceId: source?.id ?? "s1", id: "m1", name: "Film", url: url)), source: source)
    }

    private func xtream(maxConnections: Int?) -> Source {
        var s = Source.make(name: "P", secrets: .xtream(XtreamSecrets(serverUrl: "http://panel.example.com", username: "u", password: "p")), id: "x1")
        s.xtreamAccount = XtreamAccountInfo(status: "Active", expiresAt: nil, maxConnections: maxConnections, activeConnections: 0,
                                            allowedOutputFormats: [], serverTimezone: "UTC")
        return s
    }

    private let m3u = Source.make(name: "M", secrets: .m3u(M3USecrets(url: "http://list.example.com/l.m3u")), id: "m1")

    func testThumbnailsOnlyOnAVPlayer() {
        let request = movieRequest(source: m3u)
        XCTAssertTrue(SeekThumbnailPolicy.allows(engine: .avPlayer, request: request, stream: mp4))
        XCTAssertFalse(SeekThumbnailPolicy.allows(engine: .vlcKit, request: request, stream: mp4), "VLCKit: time only")
        XCTAssertFalse(SeekThumbnailPolicy.allows(engine: nil, request: request, stream: mp4))
        var hls = mp4
        hls.container = .hls
        XCTAssertFalse(SeekThumbnailPolicy.allows(engine: .avPlayer, request: request, stream: hls), "no image generator for HLS")
        let live = PlaybackRequest(item: .channel(Channel(sourceId: "m1", id: "c", name: "C", url: "http://cdn.example.com/c.mp4")), source: m3u)
        XCTAssertFalse(SeekThumbnailPolicy.allows(engine: .avPlayer, request: live, stream: mp4), "live: never")
        XCTAssertFalse(SeekThumbnailPolicy.allows(engine: .avPlayer, request: nil, stream: mp4))
    }

    func testThumbnailsOnXtreamNeedMoreThanOneConnection() {
        let panelURL = ResolvedStream(url: URL(string: "http://panel.example.com/movie/u/p/77.mp4")!, container: .mp4, headers: [:])
        for (max, expected) in [(nil, false), (0, false), (1, false), (2, true), (4, true)] as [(Int?, Bool)] {
            let request = movieRequest(source: xtream(maxConnections: max), url: nil)
            XCTAssertEqual(SeekThumbnailPolicy.allows(engine: .avPlayer, request: request, stream: panelURL), expected, "max_connections \(String(describing: max))")
        }
        var noAccount = xtream(maxConnections: 2)
        noAccount.xtreamAccount = nil
        XCTAssertFalse(SeekThumbnailPolicy.allows(engine: .avPlayer, request: movieRequest(source: noAccount, url: nil), stream: panelURL),
                       "unknown account counts as unsafe")
    }

    func testThumbnailsOnM3UOnlyForNonXtreamShapedURLs() {
        let shaped = ["http://panel.example.com:8080/movie/user/pass/123.mp4",
                      "http://panel.example.com/series/user/pass/9.mp4",
                      "http://panel.example.com/live/user/pass/5.ts",
                      "http://panel.example.com/user/pass/5"]
        for url in shaped {
            let stream = ResolvedStream(url: URL(string: url)!, container: .mp4, headers: [:])
            XCTAssertFalse(SeekThumbnailPolicy.allows(engine: .avPlayer, request: movieRequest(source: m3u, url: url), stream: stream), url)
            XCTAssertFalse(SeekThumbnailPolicy.allows(engine: .avPlayer, request: movieRequest(source: nil, url: url), stream: stream), "raw \(url)")
        }
        let plain = ["http://localhost:8766/sintel.mp4", "https://cdn.example.com/a/b/c/film.mp4", "http://cdn.example.com/movie/film.mp4"]
        for url in plain {
            let stream = ResolvedStream(url: URL(string: url)!, container: .mp4, headers: [:])
            XCTAssertTrue(SeekThumbnailPolicy.allows(engine: .avPlayer, request: movieRequest(source: m3u, url: url), stream: stream), url)
        }
    }

    // MARK: Thumbnail throttle

    func testBuckets() {
        XCTAssertEqual(SeekThumbnailPolicy.bucket(0), 0)
        XCTAssertEqual(SeekThumbnailPolicy.bucket(9.9), 0)
        XCTAssertEqual(SeekThumbnailPolicy.bucket(10), 1)
        XCTAssertEqual(SeekThumbnailPolicy.bucket(-3), 0)
        XCTAssertEqual(SeekThumbnailPolicy.time(ofBucket: 3), 35)
    }

    func testScheduleThrottlesAndCancelsStaleRequests() {
        var s = SeekThumbnailSchedule()
        XCTAssertNil(s.delayBeforeNext(nowMs: 0), "nothing wanted")
        XCTAssertFalse(s.want(12))
        XCTAssertEqual(s.start(nowMs: 1_000), 1)
        XCTAssertNil(s.start(nowMs: 1_001), "one in flight")
        // The target moved on: the request in flight is stale.
        XCTAssertTrue(s.want(45))
        XCTAssertTrue(s.want(41), "still stale while bucket 1 is in flight")
        XCTAssertEqual(s.wanted, 4)
        s.finish(1, settle: false)   // cancelled
        XCTAssertEqual(s.delayBeforeNext(nowMs: 1_100), 200, "≤ 1 request per 300 ms")
        XCTAssertNil(s.start(nowMs: 1_100))
        XCTAssertEqual(s.start(nowMs: 1_300), 4)
        s.finish(4, settle: true)
        XCTAssertNil(s.delayBeforeNext(nowMs: 5_000), "bucket 4 done")
        XCTAssertFalse(s.want(44))
        XCTAssertNil(s.wanted, "settled buckets are not requested again")
        XCTAssertFalse(s.want(15))
        XCTAssertEqual(s.start(nowMs: 5_000), 1, "a cancelled bucket can be requested again")
    }
}
