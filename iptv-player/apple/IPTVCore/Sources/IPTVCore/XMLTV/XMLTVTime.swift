import Foundation

/// XMLTV time parsing (CONTRACT §5): `YYYYMMDDhhmm[ss][ ±hhmm]`; a missing offset means UTC.
/// Pure arithmetic (no Calendar/DateFormatter), so it is fast and locale-independent.
public enum XMLTVTime {
    /// Parses an XMLTV timestamp to an instant; nil when invalid.
    public static func parse(_ string: String) -> Date? {
        parseEpochSeconds(string).map { Date(timeIntervalSince1970: TimeInterval($0)) }
    }

    /// Parses an XMLTV timestamp to epoch seconds (UTC); nil when invalid.
    public static func parseEpochSeconds(_ string: String) -> Int64? {
        let bytes = Array(string.utf8)
        var start = 0, end = bytes.count
        while start < end, isSpace(bytes[start]) { start += 1 }
        while end > start, isSpace(bytes[end - 1]) { end -= 1 }
        var i = start
        while i < end, isDigit(bytes[i]) { i += 1 }
        let digitCount = i - start
        guard digitCount == 12 || digitCount == 14 else { return nil }
        func number(_ offset: Int, _ length: Int) -> Int {
            var value = 0
            for k in 0..<length { value = value * 10 + Int(bytes[start + offset + k] - 0x30) }
            return value
        }
        let year = number(0, 4), month = number(4, 2), day = number(6, 2)
        let hour = number(8, 2), minute = number(10, 2)
        let second = digitCount == 14 ? number(12, 2) : 0
        guard (1...12).contains(month), day >= 1, day <= daysInMonth(year: year, month: month),
              (0...23).contains(hour), (0...59).contains(minute), (0...60).contains(second) else { return nil }

        // Offset part.
        while i < end, isSpace(bytes[i]) { i += 1 }
        var offsetSeconds = 0
        if i < end {
            let rest = Array(bytes[i..<end])
            if rest == Array("Z".utf8) || rest == Array("UTC".utf8) || rest == Array("GMT".utf8) {
                offsetSeconds = 0
            } else {
                guard rest.first == 0x2B || rest.first == 0x2D else { return nil }   // + / -
                var digits = Array(rest.dropFirst())
                if digits.count == 5, digits[2] == 0x3A { digits.remove(at: 2) }    // ±hh:mm
                guard digits.count == 4, digits.allSatisfy(isDigit) else { return nil }
                let hh = Int(digits[0] - 0x30) * 10 + Int(digits[1] - 0x30)
                let mm = Int(digits[2] - 0x30) * 10 + Int(digits[3] - 0x30)
                guard hh <= 23, mm <= 59 else { return nil }
                offsetSeconds = (hh * 3600 + mm * 60) * (rest.first == 0x2D ? -1 : 1)
            }
        }
        let days = daysFromCivil(year: year, month: month, day: day)
        let local = Int64(days) * 86_400 + Int64(hour * 3600 + minute * 60 + second)
        return local - Int64(offsetSeconds)
    }

    @inline(__always) private static func isSpace(_ c: UInt8) -> Bool { c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D }
    @inline(__always) private static func isDigit(_ c: UInt8) -> Bool { c >= 0x30 && c <= 0x39 }

    static func daysInMonth(year: Int, month: Int) -> Int {
        switch month {
        case 2: return (year % 4 == 0 && year % 100 != 0) || year % 400 == 0 ? 29 : 28
        case 4, 6, 9, 11: return 30
        default: return 31
        }
    }

    /// Days since 1970-01-01 for a proleptic Gregorian date (H. Hinnant's algorithm).
    static func daysFromCivil(year: Int, month: Int, day: Int) -> Int {
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let doy = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }
}
