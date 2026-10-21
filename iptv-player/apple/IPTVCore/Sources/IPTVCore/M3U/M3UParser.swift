import Foundation

/// Incremental, line-based M3U parser (CONTRACT §3).
///
/// Feed lines one by one with `feed(line:)` (or raw bytes with `feed(bytes:)`); every URL
/// line that completes an entry returns it. Call `finish()` at the end of input. The parser
/// never holds more than the current entry in memory; use `M3UPlaylist` for batching
/// drivers over `Data`, files and async byte/line sequences.
public struct M3UParser: Sendable {
    public private(set) var summary = M3UParseSummary()
    private var isFirstLine = true
    private var pending: PendingInfo?
    private var options = PendingOptions()

    public init() {}

    /// Feeds one line (without the line terminator; a trailing `\r` is tolerated).
    public mutating func feed(line: String) -> M3UEntry? {
        var copy = line
        return copy.withUTF8 { feed(bytes: $0) }
    }

    /// Feeds one line given as UTF-8 bytes (without `\n`).
    public mutating func feed(bytes: UnsafeBufferPointer<UInt8>) -> M3UEntry? {
        var start = 0
        var end = bytes.count
        if isFirstLine {
            isFirstLine = false
            if end >= 3, bytes[0] == 0xEF, bytes[1] == 0xBB, bytes[2] == 0xBF { start = 3 }
        }
        while start < end, Bytes.isSpace(bytes[start]) { start += 1 }
        while end > start, Bytes.isSpace(bytes[end - 1]) { end -= 1 }
        guard start < end else { return nil }

        if bytes[start] == Bytes.hash {
            handleDirective(bytes, start, end)
            return nil
        }
        return handleURL(bytes, start, end)
    }

    /// Ends the input. A trailing `#EXTINF` without URL counts as skipped.
    @discardableResult
    public mutating func finish() -> M3UParseSummary {
        if pending != nil {
            pending = nil
            summary.skipped += 1
        }
        options = PendingOptions()
        return summary
    }

    // MARK: - Directives

    private mutating func handleDirective(_ b: UnsafeBufferPointer<UInt8>, _ start: Int, _ end: Int) {
        if Bytes.hasPrefixCI(b, start, end, Bytes.extinf) {
            summary.sawExtinf = true
            if pending != nil {
                // #EXTINF followed by another #EXTINF: the first one is dropped.
                summary.skipped += 1
                options = PendingOptions()
            }
            pending = parseExtinf(b, start + Bytes.extinf.count, end)
        } else if Bytes.hasPrefixCI(b, start, end, Bytes.extm3u) {
            summary.sawHeader = true
            parseHeader(b, start + Bytes.extm3u.count, end)
        } else if Bytes.hasPrefixCI(b, start, end, Bytes.extgrp) {
            let value = Bytes.trimmedString(b, start + Bytes.extgrp.count, end)
            if !value.isEmpty { options.group = value }
        } else if Bytes.hasPrefixCI(b, start, end, Bytes.extvlcopt) {
            guard let (key, value) = Bytes.keyValue(b, start + Bytes.extvlcopt.count, end) else { return }
            switch key {
            case "http-user-agent": if !value.isEmpty { options.userAgent = value }
            case "http-referrer", "http-referer": if !value.isEmpty { options.referrer = value }
            default: break
            }
        } else if Bytes.hasPrefixCI(b, start, end, Bytes.kodiprop) {
            guard let (key, _) = Bytes.keyValue(b, start + Bytes.kodiprop.count, end) else { return }
            if key == "inputstream.adaptive.license_type" || key == "inputstream.adaptive.license_key" {
                options.drm = true
            }
        }
        // Other '#' lines are ignored.
    }

    private mutating func parseHeader(_ b: UnsafeBufferPointer<UInt8>, _ start: Int, _ end: Int) {
        Bytes.forEachAttribute(b, start, end) { key, value in
            guard key == .urlTvg || key == .xTvgUrl, let value else { return }
            for part in value.split(separator: ",") {
                let url = part.trimmingCharacters(in: .whitespaces)
                if !url.isEmpty, !summary.epgUrls.contains(url) { summary.epgUrls.append(url) }
            }
        }
    }

    private func parseExtinf(_ b: UnsafeBufferPointer<UInt8>, _ start: Int, _ end: Int) -> PendingInfo {
        // Find the first comma outside quotes; a quote opens only right after '='.
        var split = -1
        var lastComma = -1
        var quote: UInt8 = 0
        var previousWasEquals = false
        var i = start
        while i < end {
            let c = b[i]
            if c == Bytes.comma { lastComma = i }
            if quote != 0 {
                if c == quote { quote = 0 }
                previousWasEquals = false
            } else if c == Bytes.comma {
                split = i
                break
            } else if previousWasEquals && (c == Bytes.dquote || c == Bytes.squote) {
                quote = c
                previousWasEquals = false
            } else {
                previousWasEquals = c == Bytes.equals
            }
            i += 1
        }
        if split < 0 && quote != 0 { split = lastComma }

        var info = PendingInfo()
        let headEnd = split >= 0 ? split : end
        if split >= 0 { info.title = Bytes.trimmedString(b, split + 1, end) }

        // Duration token (unless the first token is already an attribute).
        var p = start
        while p < headEnd, Bytes.isSpace(b[p]) { p += 1 }
        var tokenEnd = p
        var tokenHasEquals = false
        while tokenEnd < headEnd, !Bytes.isSpace(b[tokenEnd]) {
            if b[tokenEnd] == Bytes.equals { tokenHasEquals = true; break }
            tokenEnd += 1
        }
        var attrStart = p
        if !tokenHasEquals {
            info.duration = Double(Bytes.string(b, p, tokenEnd)) ?? -1
            attrStart = tokenEnd
        }
        Bytes.forEachAttribute(b, attrStart, headEnd) { key, value in
            guard let value else { return }
            switch key {
            case .tvgId: info.tvgId = value
            case .tvgName: info.tvgName = value
            case .tvgLogo: info.logo = value
            case .groupTitle: info.group = value
            case .tvgChno: info.chno = Int(value.trimmingCharacters(in: .whitespaces))
            case .catchup, .catchupType: info.catchupType = value; info.hasCatchup = true
            case .catchupDays, .timeshift: info.catchupDays = Bytes.parseDays(value); info.hasCatchup = true
            case .catchupSource: info.catchupSource = value; info.hasCatchup = true
            case .tvgShift: info.tvgShift = Double(value.trimmingCharacters(in: .whitespaces))
            case .urlTvg, .xTvgUrl, .other: break
            }
        }
        return info
    }

    // MARK: - URL lines

    private mutating func handleURL(_ b: UnsafeBufferPointer<UInt8>, _ start: Int, _ end: Int) -> M3UEntry? {
        let info = pending
        let opts = options
        pending = nil
        options = PendingOptions()

        guard let schemeEnd = Bytes.allowedSchemeEnd(b, start, end) else {
            summary.skipped += 1
            return nil
        }
        let url = Bytes.string(b, start, end)
        let path = Bytes.pathRange(b, start, end, schemeEnd: schemeEnd)
        let kind = Bytes.classify(b, path.lowerBound, path.upperBound)

        var name = info?.title ?? ""
        if name.isEmpty, let tvgName = info?.tvgName { name = tvgName }
        if name.isEmpty { name = Bytes.lastPathSegment(b, path.lowerBound, path.upperBound) }
        if name.isEmpty { name = url }

        var finalKind: M3UEntryKind = .live
        var series: M3USeriesInfo?
        switch kind {
        case .movieDir: finalKind = .movie
        case .seriesDir:
            finalKind = .episode
            series = SeriesTitleMatcher.match(name)
        case .vodExtension:
            series = SeriesTitleMatcher.match(name)
            finalKind = series == nil ? .movie : .episode
        case .other: finalKind = .live
        }

        var catchup: CatchupInfo?
        if let info, info.hasCatchup {
            catchup = CatchupInfo(type: info.catchupType.map(CatchupType.init(m3uValue:)) ?? .default,
                                  days: info.catchupDays ?? 0, source: info.catchupSource)
        }
        summary.entryCount += 1
        return M3UEntry(name: name, url: url, kind: finalKind, tvgId: info?.tvgId, tvgName: info?.tvgName,
                        logo: info?.logo, group: info?.group ?? opts.group, chno: info?.chno,
                        duration: info?.duration ?? -1, catchup: catchup, tvgShiftHours: info?.tvgShift,
                        userAgent: opts.userAgent, referrer: opts.referrer, drm: opts.drm, series: series)
    }
}

// MARK: - Pending state

private struct PendingInfo: Sendable {
    var duration: Double = -1
    var title = ""
    var tvgId: String?
    var tvgName: String?
    var logo: String?
    var group: String?
    var chno: Int?
    var catchupType: String?
    var catchupDays: Int?
    var catchupSource: String?
    var hasCatchup = false
    var tvgShift: Double?
}

private struct PendingOptions: Sendable {
    var group: String?
    var userAgent: String?
    var referrer: String?
    var drm = false
}

// MARK: - Byte helpers

enum M3UAttributeKey: Sendable {
    case tvgId, tvgName, tvgLogo, groupTitle, tvgChno, catchup, catchupType, catchupDays, timeshift,
         catchupSource, tvgShift, urlTvg, xTvgUrl, other
}

enum PathKind { case movieDir, seriesDir, vodExtension, other }

enum Bytes {
    static let hash: UInt8 = 0x23, comma: UInt8 = 0x2C, equals: UInt8 = 0x3D
    static let dquote: UInt8 = 0x22, squote: UInt8 = 0x27, colon: UInt8 = 0x3A
    static let slash: UInt8 = 0x2F, question: UInt8 = 0x3F, dot: UInt8 = 0x2E

    static let extinf = Array("#extinf:".utf8)
    static let extm3u = Array("#extm3u".utf8)
    static let extgrp = Array("#extgrp:".utf8)
    static let extvlcopt = Array("#extvlcopt:".utf8)
    static let kodiprop = Array("#kodiprop:".utf8)

    static let attributeKeys: [([UInt8], M3UAttributeKey)] = [
        (Array("tvg-id".utf8), .tvgId), (Array("tvg-name".utf8), .tvgName),
        (Array("tvg-logo".utf8), .tvgLogo), (Array("group-title".utf8), .groupTitle),
        (Array("tvg-chno".utf8), .tvgChno), (Array("catchup".utf8), .catchup),
        (Array("catchup-type".utf8), .catchupType), (Array("catchup-days".utf8), .catchupDays),
        (Array("timeshift".utf8), .timeshift), (Array("catchup-source".utf8), .catchupSource),
        (Array("tvg-shift".utf8), .tvgShift), (Array("url-tvg".utf8), .urlTvg),
        (Array("x-tvg-url".utf8), .xTvgUrl),
    ]

    static let allowedSchemes: [[UInt8]] = ["http", "https", "rtmp", "rtmps", "rtsp", "udp", "rtp"].map { Array($0.utf8) }
    static let vodExtensions: Set<String> = ["mp4", "mkv", "avi", "mov", "m4v", "wmv", "flv", "webm", "mpg", "mpeg"]
    static let movieDir = Array("/movie/".utf8)
    static let seriesDir = Array("/series/".utf8)

    @inline(__always) static func isSpace(_ c: UInt8) -> Bool {
        c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D || c == 0x0B || c == 0x0C
    }

    @inline(__always) static func lower(_ c: UInt8) -> UInt8 {
        (c >= 0x41 && c <= 0x5A) ? c | 0x20 : c
    }

    /// Case-insensitive ASCII prefix test; `prefix` must be lowercase.
    static func hasPrefixCI(_ b: UnsafeBufferPointer<UInt8>, _ start: Int, _ end: Int, _ prefix: [UInt8]) -> Bool {
        guard end - start >= prefix.count else { return false }
        for (offset, p) in prefix.enumerated() where lower(b[start + offset]) != p { return false }
        return true
    }

    static func equalsCI(_ b: UnsafeBufferPointer<UInt8>, _ start: Int, _ end: Int, _ other: [UInt8]) -> Bool {
        end - start == other.count && hasPrefixCI(b, start, end, other)
    }

    static func containsCI(_ b: UnsafeBufferPointer<UInt8>, _ start: Int, _ end: Int, _ needle: [UInt8]) -> Bool {
        guard end - start >= needle.count else { return false }
        var i = start
        while i + needle.count <= end {
            if hasPrefixCI(b, i, end, needle) { return true }
            i += 1
        }
        return false
    }

    @inline(__always) static func string(_ b: UnsafeBufferPointer<UInt8>, _ start: Int, _ end: Int) -> String {
        guard start < end else { return "" }
        return String(decoding: UnsafeBufferPointer(rebasing: b[start..<end]), as: UTF8.self)
    }

    static func trimmedString(_ b: UnsafeBufferPointer<UInt8>, _ start: Int, _ end: Int) -> String {
        var s = start, e = end
        while s < e, isSpace(b[s]) { s += 1 }
        while e > s, isSpace(b[e - 1]) { e -= 1 }
        return string(b, s, e)
    }

    /// `key=value` after a directive prefix: key lowercased and trimmed, value trimmed.
    static func keyValue(_ b: UnsafeBufferPointer<UInt8>, _ start: Int, _ end: Int) -> (String, String)? {
        var eq = start
        while eq < end, b[eq] != equals { eq += 1 }
        guard eq < end else { return nil }
        return (trimmedString(b, start, eq).lowercased(), trimmedString(b, eq + 1, end))
    }

    /// Iterates `key=value` attributes: quoted ("…" / '…', unterminated → to the end) or
    /// unquoted (until whitespace). Empty values are reported as nil.
    static func forEachAttribute(_ b: UnsafeBufferPointer<UInt8>, _ start: Int, _ end: Int,
                                 _ body: (M3UAttributeKey, String?) -> Void) {
        var p = start
        while p < end {
            while p < end, isSpace(b[p]) { p += 1 }
            let keyStart = p
            while p < end, !isSpace(b[p]), b[p] != equals { p += 1 }
            let keyEnd = p
            guard p < end, b[p] == equals else { continue }
            p += 1
            var valueStart = p
            var valueEnd = p
            if p < end, b[p] == dquote || b[p] == squote {
                let q = b[p]
                p += 1
                valueStart = p
                while p < end, b[p] != q { p += 1 }
                valueEnd = p
                if p < end { p += 1 }
            } else {
                while p < end, !isSpace(b[p]) { p += 1 }
                valueEnd = p
            }
            guard keyEnd > keyStart else { continue }
            var key = M3UAttributeKey.other
            for (name, k) in attributeKeys where equalsCI(b, keyStart, keyEnd, name) {
                key = k
                break
            }
            if key == .other { continue }
            body(key, valueEnd > valueStart ? string(b, valueStart, valueEnd) : nil)
        }
    }

    static func parseDays(_ value: String) -> Int? {
        let t = value.trimmingCharacters(in: .whitespaces)
        if let i = Int(t) { return i }
        if let d = Double(t), d.isFinite { return Int(d) }
        return nil
    }

    /// Returns the index of ':' after an allowed scheme, or nil.
    static func allowedSchemeEnd(_ b: UnsafeBufferPointer<UInt8>, _ start: Int, _ end: Int) -> Int? {
        var i = start
        while i < end, i - start <= 6, b[i] != colon { i += 1 }
        guard i < end, b[i] == colon, i > start else { return nil }
        for scheme in allowedSchemes where equalsCI(b, start, i, scheme) { return i }
        return nil
    }

    /// Path range (without query/fragment) of an absolute URL.
    static func pathRange(_ b: UnsafeBufferPointer<UInt8>, _ start: Int, _ end: Int, schemeEnd: Int) -> Range<Int> {
        var p = schemeEnd + 1
        if p + 1 < end, b[p] == slash, b[p + 1] == slash {
            p += 2
            while p < end, b[p] != slash, b[p] != question, b[p] != hash { p += 1 }
        }
        var q = p
        while q < end, b[q] != question, b[q] != hash { q += 1 }
        return p..<q
    }

    static func classify(_ b: UnsafeBufferPointer<UInt8>, _ start: Int, _ end: Int) -> PathKind {
        if containsCI(b, start, end, movieDir) { return .movieDir }
        if containsCI(b, start, end, seriesDir) { return .seriesDir }
        var i = end - 1
        while i >= start, b[i] != slash, b[i] != dot { i -= 1 }
        if i >= start, b[i] == dot, end - i - 1 <= 5 {
            let ext = string(b, i + 1, end).lowercased()
            if vodExtensions.contains(ext) { return .vodExtension }
        }
        return .other
    }

    static func lastPathSegment(_ b: UnsafeBufferPointer<UInt8>, _ start: Int, _ end: Int) -> String {
        var e = end
        while e > start, b[e - 1] == slash { e -= 1 }
        var s = e
        while s > start, b[s - 1] != slash { s -= 1 }
        return string(b, s, e)
    }
}

/// Matcher for the series pattern of CONTRACT §3.10 (case-insensitive):
/// `^(.*?)[\s._-]*S(\d{1,2})[\s._-]*E(\d{1,3})\b` – implemented by hand (no regex engine in
/// the hot path) with identical semantics.
public enum SeriesTitleMatcher {
    public static func match(_ title: String) -> M3USeriesInfo? {
        let s = Array(title.unicodeScalars)
        let n = s.count
        func isSep(_ c: Unicode.Scalar) -> Bool { c == "." || c == "_" || c == "-" || c.properties.isWhitespace }
        func isDigit(_ c: Unicode.Scalar) -> Bool { c.value >= 0x30 && c.value <= 0x39 }
        func isWord(_ c: Unicode.Scalar) -> Bool { c == "_" || c.properties.isAlphabetic || c.properties.numericType != nil }
        var i = 0
        while i <= n {
            var j = i
            while j < n, isSep(s[j]) { j += 1 }
            if j < n, s[j] == "S" || s[j] == "s" {
                var k = j + 1
                let seasonStart = k
                while k < n, isDigit(s[k]) { k += 1 }
                let seasonLen = k - seasonStart
                if seasonLen >= 1 && seasonLen <= 2 {
                    while k < n, isSep(s[k]) { k += 1 }
                    if k < n, s[k] == "E" || s[k] == "e" {
                        let episodeStart = k + 1
                        var m = episodeStart
                        while m < n, isDigit(s[m]) { m += 1 }
                        let episodeLen = m - episodeStart
                        if episodeLen >= 1 && episodeLen <= 3 && (m == n || !isWord(s[m])) {
                            let name = String(String.UnicodeScalarView(s[0..<i])).trimmingCharacters(in: .whitespacesAndNewlines)
                            let season = Int(String(String.UnicodeScalarView(s[seasonStart..<(seasonStart + seasonLen)]))) ?? 0
                            let episode = Int(String(String.UnicodeScalarView(s[episodeStart..<m]))) ?? 0
                            return M3USeriesInfo(name: name, season: season, episode: episode)
                        }
                    }
                }
            }
            i += 1
        }
        return nil
    }
}
