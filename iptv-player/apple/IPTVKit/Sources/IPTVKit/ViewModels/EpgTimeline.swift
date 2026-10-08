import CoreGraphics
import Foundation

/// Time window of the EPG list (SCREENS §3.4): "now" sits right after the channel tile when the list opens,
/// and the window follows the clock (`following(_:)`) so the guide never shows a frozen, finally empty window.
public struct EpgTimeline: Sendable, Equatable {
    public let start: Date
    public let end: Date
    public let pointsPerMinute: CGFloat
    /// Minutes before "now" at the window's start (the tile covers that much, plus 20 min of the airing programme).
    public let leadMinutes: Double
    public let hours: Double

    public init(now: Date, tileWidth: CGFloat, pointsPerMinute: CGFloat, hours: Double = 12) {
        self.pointsPerMinute = pointsPerMinute
        self.hours = hours
        leadMinutes = Double(tileWidth / pointsPerMinute) + 20
        let raw = now.addingTimeInterval(-leadMinutes * 60)
        start = Date(timeIntervalSince1970: (raw.timeIntervalSince1970 / 60).rounded(.down) * 60)
        end = start.addingTimeInterval(hours * 3600)
    }

    /// The window for `now`: unchanged while "now" is less than `slackMinutes` past its opening position (no jump
    /// every minute), otherwise re-anchored so "now" sits right after the tile again (audit B10).
    public func following(_ now: Date, slackMinutes: Double = 30) -> EpgTimeline {
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

    /// Half-hour ticks inside the window.
    public var ticks: [Date] {
        var t = Date(timeIntervalSince1970: (start.timeIntervalSince1970 / 1800).rounded(.up) * 1800)
        var out: [Date] = []
        while t < end { out.append(t); t = t.addingTimeInterval(1800) }
        return out
    }
}
