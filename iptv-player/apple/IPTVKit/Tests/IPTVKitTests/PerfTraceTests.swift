import XCTest
@testable import IPTVKit

/// Mutable fake clock usable from the `@Sendable` clock closure (Swift 6 strict concurrency).
private final class FakeClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64 = 0
    var now: UInt64 {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}

@MainActor
final class PerfTraceTests: XCTestCase {
    func testZapAndColdStartIntervals() throws {
        let clock = FakeClock()
        let t = PerfTrace(clock: { clock.now })
        t.mark(.appLaunch)
        clock.now = 200_000_000; t.mark(.playRequested)
        clock.now = 1_100_000_000; t.mark(.firstFrame)
        XCTAssertEqual(try XCTUnwrap(t.lastColdStartMs), 1100, accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap(t.lastZapMs), 900, accuracy: 0.01)
        clock.now = 2_000_000_000; t.mark(.playRequested)
        clock.now = 2_500_000_000; t.mark(.firstFrame)
        XCTAssertEqual(try XCTUnwrap(t.lastZapMs), 500, accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap(t.lastColdStartMs), 1100, accuracy: 0.01, "cold start only counts the first frame after launch")
        XCTAssertEqual(t.zapSamples, [900, 500])
        XCTAssertEqual(t.percentile(0.5), 500)
    }

    func testFirstFrameWithoutRequestIsIgnored() {
        let clock = FakeClock()
        let t = PerfTrace(clock: { clock.now })
        clock.now = 10; t.mark(.firstFrame)
        XCTAssertNil(t.lastZapMs)
    }
}
