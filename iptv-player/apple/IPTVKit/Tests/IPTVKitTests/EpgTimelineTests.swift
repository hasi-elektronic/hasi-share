import XCTest
@testable import IPTVKit
import IPTVCore

/// TV guide window (SCREENS §3.4, QA audit B10 / tvOS B-08): "now" sits right after the channel tile when the
/// guide opens, and the window moves with the clock instead of staying anchored at the time the view was created.
final class EpgTimelineTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)   // a whole minute

    func testNowSitsRightAfterTheTile() {
        let timeline = EpgTimeline(now: t0, tileWidth: 250, pointsPerMinute: 8)
        XCTAssertEqual(timeline.x(t0), 250 + 20 * 8, accuracy: 8, "tile width + 20 min of the airing programme")
        XCTAssertEqual(timeline.end.timeIntervalSince(timeline.start), 12 * 3600)
    }

    func testWindowStaysWhileNowIsNearTheStart() {
        let timeline = EpgTimeline(now: t0, tileWidth: 250, pointsPerMinute: 8)
        XCTAssertEqual(timeline.following(t0.addingTimeInterval(20 * 60)).start, timeline.start, "no jump every minute")
    }

    func testWindowMovesWithNow() {
        let timeline = EpgTimeline(now: t0, tileWidth: 250, pointsPerMinute: 8)
        let later = t0.addingTimeInterval(3 * 3600)
        let moved = timeline.following(later)
        XCTAssertGreaterThan(moved.start, timeline.start)
        XCTAssertEqual(moved.x(later), moved.x(moved.start) + 250 + 20 * 8, accuracy: 8, "now right after the tile again")
        XCTAssertTrue(moved.interval.contains(later.addingTimeInterval(10 * 3600)), "the next 10 h stay in the window")
        // After 11 h the old window would be (almost) empty; the moved one is not.
        let much = timeline.following(t0.addingTimeInterval(11 * 3600))
        XCTAssertTrue(much.interval.contains(t0.addingTimeInterval(20 * 3600)))
    }
}
