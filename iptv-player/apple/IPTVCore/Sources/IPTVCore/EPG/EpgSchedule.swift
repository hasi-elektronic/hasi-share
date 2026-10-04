import Foundation

/// Now/next lookup and progress helpers for programmes of one channel.
public enum EpgSchedule {
    /// The programme on air at `date` and the one after it. `programs` must be sorted by start.
    public static func nowAndNext(_ programs: [EpgProgram], at date: Date) -> (now: EpgProgram?, next: EpgProgram?) {
        // First index whose start is after `date`.
        var low = 0, high = programs.count
        while low < high {
            let mid = (low + high) / 2
            if programs[mid].start <= date { low = mid + 1 } else { high = mid }
        }
        let next = low < programs.count ? programs[low] : nil
        var current: EpgProgram?
        if low > 0, programs[low - 1].isOnAir(at: date) { current = programs[low - 1] }
        return (current, next)
    }

    /// Progress fraction 0…1 of `[start, end)` at `date`.
    public static func progress(start: Date, end: Date, at date: Date) -> Double {
        let total = end.timeIntervalSince(start)
        guard total > 0 else { return 0 }
        return min(1, max(0, date.timeIntervalSince(start) / total))
    }

    /// Progress of a programme at `date`.
    public static func progress(of program: EpgProgram, at date: Date) -> Double {
        progress(start: program.start, end: program.end, at: date)
    }

    /// Programmes overlapping `interval` (e.g. the visible part of the EPG grid), in order.
    public static func programs(_ programs: [EpgProgram], overlapping interval: DateInterval) -> [EpgProgram] {
        programs.filter { $0.end > interval.start && $0.start < interval.end }
    }

    /// True if a past programme can be replayed via catch-up at `now`.
    public static func isCatchupAvailable(_ program: EpgProgram, catchup: CatchupInfo, now: Date) -> Bool {
        guard catchup.isAvailable, program.end <= now else { return false }
        let days = max(catchup.days, 1)
        return program.start >= now.addingTimeInterval(-TimeInterval(days) * 86_400)
    }
}

/// Formats EPG times in a chosen time zone (device zone by default, CONTRACT §5 – never the
/// server zone). Thread-safe.
public final class EpgTimeFormatter: @unchecked Sendable {
    public let timeZone: TimeZone
    public let locale: Locale
    private let lock = NSLock()
    private let timeFormatter: DateFormatter
    private let dayFormatter: DateFormatter

    /// - Parameter use24Hour: true → "HH:mm", false → 12-hour clock, nil → locale default.
    public init(timeZone: TimeZone = .current, locale: Locale = .current, use24Hour: Bool? = nil) {
        self.timeZone = timeZone
        self.locale = locale
        timeFormatter = DateFormatter()
        timeFormatter.locale = locale
        timeFormatter.timeZone = timeZone
        timeFormatter.calendar = Calendar(identifier: .gregorian)
        switch use24Hour {
        case .some(true): timeFormatter.dateFormat = "HH:mm"
        case .some(false): timeFormatter.dateFormat = DateFormatter.dateFormat(fromTemplate: "hmma", options: 0, locale: locale) ?? "h:mm a"
        case .none: timeFormatter.dateFormat = DateFormatter.dateFormat(fromTemplate: "jmm", options: 0, locale: locale) ?? "HH:mm"
        }
        dayFormatter = DateFormatter()
        dayFormatter.locale = locale
        dayFormatter.timeZone = timeZone
        dayFormatter.calendar = Calendar(identifier: .gregorian)
        dayFormatter.dateFormat = DateFormatter.dateFormat(fromTemplate: "EEEdMMM", options: 0, locale: locale) ?? "EEE d MMM"
    }

    /// Clock time, e.g. "18:30".
    public func time(_ date: Date) -> String {
        lock.lock()
        defer { lock.unlock() }
        return timeFormatter.string(from: date)
    }

    /// Time range, e.g. "18:30 – 20:00" (matches `epg_time_range`).
    public func range(start: Date, end: Date) -> String {
        "\(time(start)) – \(time(end))"
    }

    /// Short day label, e.g. "Sat 4 Oct".
    public func day(_ date: Date) -> String {
        lock.lock()
        defer { lock.unlock() }
        return dayFormatter.string(from: date)
    }
}
