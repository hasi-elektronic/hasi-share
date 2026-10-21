import XCTest
@testable import IPTVKit
import IPTVCore

/// Multi-day TV guide (Build 18, SCREENS §3.4): day picker window math, the day timelines and the programme actions.
final class GuideDayTests: XCTestCase {
    let berlin = TimeZone(identifier: "Europe/Berlin")!
    /// 2026-10-09 20:15 Berlin (18:15 UTC).
    let now = Date(timeIntervalSince1970: 1_791_569_700)

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0, _ min: Int = 0, zone: TimeZone? = nil) -> Date {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = zone ?? berlin
        return c.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    func testDaysRunFromYesterdayToSixDaysAhead() {
        let days = GuideDay.days(now: now, timeZone: berlin, catchupDays: 0)
        XCTAssertEqual(days.map(\.offset), Array(-1...6), "Gestern … +6 (no catch-up still offers yesterday)")
        let today = try! XCTUnwrap(days.first { $0.offset == 0 })
        XCTAssertEqual(today.start, date(2026, 10, 9))
        XCTAssertEqual(today.end, date(2026, 10, 10))
        XCTAssertTrue(today.contains(now))
        XCTAssertEqual(GuideDay.day(containing: now, in: days)?.offset, 0)
    }

    func testPastDaysFollowTheCatchupDepthCappedAtSeven() {
        XCTAssertEqual(GuideDay.days(now: now, timeZone: berlin, catchupDays: 3).first?.offset, -3)
        XCTAssertEqual(GuideDay.days(now: now, timeZone: berlin, catchupDays: 14).first?.offset, -7)
        XCTAssertEqual(GuideDay.days(now: now, timeZone: berlin, catchupDays: 3).last?.offset, 6)
    }

    func testDaylightSavingDayIs25Hours() {
        // 2026-10-25: CEST → CET.
        let days = GuideDay.days(now: date(2026, 10, 24, 12), timeZone: berlin, catchupDays: 1)
        let dstDay = try! XCTUnwrap(days.first { $0.offset == 1 })
        XCTAssertEqual(dstDay.start, date(2026, 10, 25))
        XCTAssertEqual(dstDay.end.timeIntervalSince(dstDay.start), 25 * 3600)
        XCTAssertEqual(dstDay.sameClockTime(as: date(2026, 10, 24, 20, 15)), date(2026, 10, 25, 20, 15), "same wall-clock time")
    }

    func testDaysFollowTheEpgTimeZone() {
        let istanbul = TimeZone(identifier: "Europe/Istanbul")!
        let today = try! XCTUnwrap(GuideDay.days(now: now, timeZone: istanbul, catchupDays: 1).first { $0.offset == 0 })
        XCTAssertEqual(today.start, date(2026, 10, 9, zone: istanbul))
    }

    func testTodayTimelineFollowsNowAndReachesTheEndOfTheDay() {
        let today = try! XCTUnwrap(GuideDay.days(now: now, timeZone: berlin, catchupDays: 1).first { $0.offset == 0 })
        let timeline = EpgTimeline(day: today, now: now, tileWidth: 250, pointsPerMinute: 8)
        XCTAssertTrue(timeline.followsNow)
        XCTAssertEqual(timeline.x(now), 250 + 20 * 8, accuracy: 8, "now right after the tile (Build 16)")
        XCTAssertGreaterThanOrEqual(timeline.end, today.end, "the whole rest of today is in the window")
        XCTAssertGreaterThanOrEqual(timeline.hours, 12)
        XCTAssertEqual(timeline.anchor(now: now), now)
        XCTAssertGreaterThan(timeline.following(now.addingTimeInterval(3 * 3600)).start, timeline.start, "moving window kept")
    }

    func testOtherDayShowsTheWholeDayAndStaysFixed() {
        let days = GuideDay.days(now: now, timeZone: berlin, catchupDays: 3)
        let tomorrow = try! XCTUnwrap(days.first { $0.offset == 1 })
        let timeline = EpgTimeline(day: tomorrow, now: now, tileWidth: 250, pointsPerMinute: 8)
        XCTAssertFalse(timeline.followsNow)
        XCTAssertEqual(timeline.start, date(2026, 10, 10))
        XCTAssertEqual(timeline.end, date(2026, 10, 11))
        XCTAssertEqual(timeline.width, 24 * 60 * 8)
        XCTAssertEqual(timeline.anchor(now: now), date(2026, 10, 10, 20, 15), "opens at the same clock time")
        XCTAssertEqual(timeline.following(now.addingTimeInterval(5 * 3600)), timeline, "another day never moves")
        let yesterday = try! XCTUnwrap(days.first { $0.offset == -1 })
        XCTAssertEqual(EpgTimeline(day: yesterday, now: now, tileWidth: 92, pointsPerMinute: 4).interval,
                       DateInterval(start: date(2026, 10, 8), end: date(2026, 10, 9)))
    }

    // MARK: Programme detail actions

    private func program(_ startOffset: TimeInterval, _ minutes: Double) -> EpgProgram {
        let start = now.addingTimeInterval(startOffset)
        return EpgProgram(sourceId: "s", channelEpgId: "e", start: start, end: start.addingTimeInterval(minutes * 60), title: "P")
    }

    func testActionsPerTiming() {
        let catchup = CatchupInfo(type: .default, days: 2)
        let past = ProgramActions.decide(program: program(-3 * 3600, 60), catchup: catchup, replayURL: "u", now: now)
        XCTAssertEqual(past.timing, .past)
        XCTAssertTrue(past.canReplay, "Aufnahme ansehen")
        XCTAssertFalse(past.canRemind)
        let onAir = ProgramActions.decide(program: program(-1800, 60), catchup: catchup, replayURL: "u", now: now)
        XCTAssertEqual(onAir.timing, .onAir)
        XCTAssertTrue(onAir.canReplay, "Von Anfang an")
        XCTAssertTrue(onAir.canWatchLive)
        let future = ProgramActions.decide(program: program(3600, 60), catchup: catchup, replayURL: "u", now: now)
        XCTAssertEqual(future.timing, .future)
        XCTAssertFalse(future.canReplay)
        XCTAssertTrue(future.canRemind, "Erinnern")
    }

    func testReplayNeedsArchiveDaysAndAURL() {
        let catchup = CatchupInfo(type: .xtream, days: 2)
        XCTAssertFalse(ProgramActions.decide(program: program(-3 * 86_400, 60), catchup: catchup, replayURL: "u", now: now).canReplay,
                       "older than the archive")
        XCTAssertFalse(ProgramActions.decide(program: program(-3600, 30), catchup: catchup, replayURL: nil, now: now).canReplay, "no URL")
        XCTAssertFalse(ProgramActions.decide(program: program(-3600, 30), catchup: .none, replayURL: "u", now: now).canReplay, "no catch-up")
    }

    // MARK: Performance: day switching on the 500k-row EPG fixture

    /// Switching the day = every visible row (20 channels on a TV screen + overscan) loads the programmes of the new
    /// day window. Budget ≤ 100 ms (debug builds 2×), the 500k-row fixture of `CatalogPerformanceTests`.
    func testDaySwitchUnderBudgetOn500kEpgRows() throws {
        #if DEBUG
        let factor = 2.0
        #else
        let factor = 1.0
        #endif
        let db = try AppDatabase.inMemory()
        try db.db.run("INSERT INTO sources (id, sort, json) VALUES ('s', 0, '{}')")
        let epg = EpgRepository(database: db)
        let now = Date()
        let session = try epg.beginRefresh(sourceId: "s")
        for chunk in stride(from: 0, to: 2_500, by: 500) {
            var programs: [EpgProgram] = []
            for c in chunk..<(chunk + 500) {
                // 200 programmes per channel: −2 days … +6 days in 1 h steps → 500 000 rows.
                for p in 0..<200 {
                    let start = now.addingTimeInterval(Double(p - 48) * 3600 + Double(c % 60) * 60)
                    programs.append(EpgProgram(sourceId: "s", channelEpgId: "e\(c)", start: start, end: start.addingTimeInterval(3600),
                                               title: "Programm \(p)"))
                }
            }
            try session.write(programs)
        }
        try session.commit()
        XCTAssertEqual(try epg.programCount(sourceId: "s"), 500_000)
        let days = GuideDay.days(now: now, timeZone: .current, catchupDays: 2)
        let visible = (0..<24).map { "e\($0 * 97)" }
        var t: [Double] = []
        var rows = 0
        for day in days + days {   // every day, twice (warm + measured)
            let timeline = EpgTimeline(day: day, now: now, tileWidth: 250, pointsPerMinute: 8)
            let s = DispatchTime.now()
            rows = try visible.map { try epg.programs(sourceId: "s", epgId: $0, in: timeline.interval).count }.reduce(0, +)
            t.append(Double(DispatchTime.now().uptimeNanoseconds - s.uptimeNanoseconds) / 1e6)
            XCTAssertGreaterThan(rows, 0, "day \(day.offset) has programmes")
        }
        let measured = Array(t.suffix(days.count)).sorted()
        let worst = measured.last ?? 0
        print("PERF guide day switch (24 rows, 500k EPG rows): median \(String(format: "%.2f", measured[measured.count / 2])) ms, worst \(String(format: "%.2f", worst)) ms")
        XCTAssertLessThan(worst, 100 * factor, "day switch \(worst) ms")
    }
}
