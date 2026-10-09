import CoreGraphics
import Foundation

/// Time window of the EPG list (SCREENS §3.4): "now" sits right after the channel tile when the list opens,
/// and the window follows the clock (`following(_:)`) so the guide never shows a frozen, finally empty window.
/// Other days of the day picker (`GuideDay`) show that whole day (`init(day:…)`) and do not follow the clock.
public struct EpgTimeline: Sendable, Equatable {
    public let start: Date
    public let end: Date
    public let pointsPerMinute: CGFloat
    /// Minutes before "now" at the window's start (the tile covers that much, plus 20 min of the airing programme).
    public let leadMinutes: Double
    public let hours: Double
    /// Today: the window moves with the clock. Another day: fixed.
    public let followsNow: Bool
    /// Another day: the moment the list opens on (same clock time as now, clamped to the day); today: nil (= now).
    public let focusDate: Date?

    public init(now: Date, tileWidth: CGFloat, pointsPerMinute: CGFloat, hours: Double = 12) {
        self.pointsPerMinute = pointsPerMinute
        self.hours = hours
        leadMinutes = Double(tileWidth / pointsPerMinute) + 20
        let raw = now.addingTimeInterval(-leadMinutes * 60)
        start = Date(timeIntervalSince1970: (raw.timeIntervalSince1970 / 60).rounded(.down) * 60)
        end = start.addingTimeInterval(hours * 3600)
        followsNow = true
        focusDate = nil
    }

    /// The window of a picker day. Today: the moving window from just before now to the end of the day (at least
    /// `minHours`, so a late evening still shows the night). Another day: the whole day (`day.start…day.end`).
    public init(day: GuideDay, now: Date, tileWidth: CGFloat, pointsPerMinute: CGFloat, minHours: Double = 12) {
        if day.contains(now) {
            let lead = Double(tileWidth / pointsPerMinute) + 20
            let raw = now.addingTimeInterval(-lead * 60)
            let start = Date(timeIntervalSince1970: (raw.timeIntervalSince1970 / 60).rounded(.down) * 60)
            let hours = max(minHours, (day.end.timeIntervalSince(start) / 3600).rounded(.up))
            self.init(now: now, tileWidth: tileWidth, pointsPerMinute: pointsPerMinute, hours: hours)
        } else {
            self.init(start: day.start, end: day.end, pointsPerMinute: pointsPerMinute,
                      leadMinutes: Double(tileWidth / pointsPerMinute) + 20, focusDate: day.sameClockTime(as: now))
        }
    }

    private init(start: Date, end: Date, pointsPerMinute: CGFloat, leadMinutes: Double, focusDate: Date) {
        self.start = start
        self.end = end
        self.pointsPerMinute = pointsPerMinute
        self.leadMinutes = leadMinutes
        hours = end.timeIntervalSince(start) / 3600
        followsNow = false
        self.focusDate = focusDate
    }

    /// The window for `now`: unchanged while "now" is less than `slackMinutes` past its opening position (no jump
    /// every minute), otherwise re-anchored so "now" sits right after the tile again (audit B10). Fixed days stay.
    public func following(_ now: Date, slackMinutes: Double = 30) -> EpgTimeline {
        guard followsNow else { return self }
        let anchor = start.addingTimeInterval(leadMinutes * 60)
        guard now.timeIntervalSince(anchor) > slackMinutes * 60 || now < start else { return self }
        let tileWidth = CGFloat(leadMinutes - 20) * pointsPerMinute
        return EpgTimeline(now: now, tileWidth: tileWidth, pointsPerMinute: pointsPerMinute, hours: hours)
    }

    public func x(_ date: Date) -> CGFloat {
        CGFloat(min(max(date.timeIntervalSince(start), 0), end.timeIntervalSince(start)) / 60) * pointsPerMinute
    }

    public var width: CGFloat { x(end) }
    public var interval: DateInterval { DateInterval(start: start, end: end) }

    /// The moment focus and scrolling start at: now (today) or `focusDate`.
    public func anchor(now: Date) -> Date { followsNow ? now : (focusDate ?? start) }

    /// Half-hour ticks inside the window.
    public var ticks: [Date] {
        var t = Date(timeIntervalSince1970: (start.timeIntervalSince1970 / 1800).rounded(.up) * 1800)
        var out: [Date] = []
        while t < end { out.append(t); t = t.addingTimeInterval(1800) }
        return out
    }
}

/// One day of the guide's day picker ("Gestern … Heute … +6"), local midnight to midnight in the EPG time zone.
public struct GuideDay: Sendable, Hashable, Identifiable {
    /// Days from today (0 = today, −1 = yesterday).
    public let offset: Int
    public let start: Date
    public let end: Date
    public let timeZone: TimeZone
    public var id: Int { offset }

    public func contains(_ date: Date) -> Bool { start <= date && date < end }

    /// The same wall-clock time as `now` on this day (DST-safe), clamped into the day.
    public func sameClockTime(as now: Date) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let c = calendar.dateComponents([.hour, .minute], from: now)
        let date = calendar.date(bySettingHour: c.hour ?? 0, minute: c.minute ?? 0, second: 0, of: start) ?? start
        return min(max(date, start), end.addingTimeInterval(-60))
    }

    /// Picker days: `pastDays` back (catch-up depth of the source, at least "yesterday", at most 7) to `futureDays`
    /// ahead (EPG retention: 7 days incl. today). DST days are 23 / 25 h long.
    public static func days(now: Date, timeZone: TimeZone, catchupDays: Int, futureDays: Int = 6) -> [GuideDay] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let today = calendar.startOfDay(for: now)
        let past = min(max(catchupDays, 1), 7)
        return (-past...max(0, futureDays)).compactMap { offset in
            guard let start = calendar.date(byAdding: .day, value: offset, to: today),
                  let end = calendar.date(byAdding: .day, value: 1, to: start) else { return nil }
            return GuideDay(offset: offset, start: start, end: end, timeZone: timeZone)
        }
    }

    /// The picker day containing `date` (nil outside the list).
    public static func day(containing date: Date, in days: [GuideDay]) -> GuideDay? {
        days.first { $0.contains(date) }
    }
}
