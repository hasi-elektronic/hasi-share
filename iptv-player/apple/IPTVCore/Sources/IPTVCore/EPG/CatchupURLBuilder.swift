import Foundation

/// Catch-up (archive) playback URL of an **M3U** channel (CONTRACT §3.9, audit C11). Xtream sources build
/// their archive with `XtreamURLBuilder.timeshiftURL` (CONTRACT §4.5) instead.
///
/// Per `catchup` type (`CatchupType(m3uValue:)`):
/// * `default` – `catchup-source` is the archive URL (placeholders filled; a source that is not an absolute URL is
///   appended to the stream URL). Without a source: the stream URL itself when it has placeholders, else the server
///   kind is detected – Xtream-shaped → timeshift, Flussonic-shaped → archive, anything else → `shift`.
/// * `append` – stream URL + filled `catchup-source`.
/// * `shift` – stream URL + `utc={utc}&lutc={lutc}` (`?` or `&`).
/// * `flussonic` – `…/<name>/<list>.m3u8` → `…/<name>/<list>-{utc}-{duration}.m3u8`, `…/<name>/mpegts` →
///   `…/<name>/archive-{utc}-{duration}.ts` (query kept); an explicit `catchup-source` wins.
/// * `xtream` (`xc`) – `{host}/[live/]U/P/{id}.{ext}` → `{host}/timeshift/U/P/{minutes}/{Y-m-d:H-M}/{id}.{ext}` (UTC).
///
/// Placeholders: `{utc}` `${start}` `{start}` (programme start, Unix s) · `{utcend}` `${end}` `{end}` · `{lutc}`
/// `${now}` `${timestamp}` `{now}` · `{duration}` `${duration}` (s; `{duration:60}` = minutes) · `{offset}` `${offset}`
/// (now − start, s; `{offset:60}`) · `{Y}{m}{d}{H}{M}{S}` (start, UTC) · `{utc:FORMAT}` `${start:FORMAT}`
/// `{utcend:FORMAT}` `${end:FORMAT}` `{lutc:FORMAT}` `${now:FORMAT}` with the letters `Y m d H M S` in FORMAT (UTC).
/// Unknown placeholders stay as they are.
public enum CatchupURLBuilder {
    /// The archive URL of `[start, end)` or nil when the type cannot build one (none, non-HTTP stream, no match).
    public static func url(channelURL: String, catchup: CatchupInfo, start: Date, end: Date, now: Date) -> String? {
        let stream = channelURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isHTTP(stream) else { return nil }
        let source = catchup.source?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        func fill(_ template: String) -> String { format(template, start: start, end: end, now: now) }
        switch catchup.type {
        case .none:
            return nil
        case .append:
            guard let source else { return nil }
            return stream + fill(source)
        case .shift:
            return shift(stream, start: start, now: now)
        case .flussonic:
            if let source { return fromSource(source, stream: stream, fill: fill) }
            return flussonic(stream, start: start, end: end, anyList: true)
        case .xtream:
            if let source { return fromSource(source, stream: stream, fill: fill) }
            return xtream(stream, start: start, end: end)
        case .default:
            if let source { return fromSource(source, stream: stream, fill: fill) }
            let filled = fill(stream)
            if filled != stream { return filled }
            return xtream(stream, start: start, end: end)
                ?? flussonic(stream, start: start, end: end, anyList: false)
                ?? shift(stream, start: start, now: now)
        }
    }

    private static func isHTTP(_ s: String) -> Bool {
        let lower = s.lowercased()
        return lower.hasPrefix("http://") || lower.hasPrefix("https://")
    }

    /// An absolute source is the archive URL; a relative one ("?utc=…", "&…") is appended to the stream.
    private static func fromSource(_ source: String, stream: String, fill: (String) -> String) -> String {
        isHTTP(source) ? fill(source) : stream + fill(source)
    }

    private static func shift(_ stream: String, start: Date, now: Date) -> String {
        stream + (stream.contains("?") ? "&" : "?") + "utc=\(unix(start))&lutc=\(unix(now))"
    }

    private static let flussonicHLS = try! NSRegularExpression(pattern: #"^(https?://[^/?#]+/[^?#]*?)/([^/?#]+)\.m3u8(\?[^#]*)?$"#,
                                                               options: [.caseInsensitive])
    private static let flussonicTS = try! NSRegularExpression(pattern: #"^(https?://[^/?#]+/[^?#]*?)/mpegts(\?[^#]*)?$"#,
                                                              options: [.caseInsensitive])
    /// Playlist names Flussonic serves (auto-detection of `default` channels only accepts these).
    private static let flussonicLists: Set<String> = ["index", "video", "mono", "playlist", "tracks-v1a1"]

    private static func flussonic(_ stream: String, start: Date, end: Date, anyList: Bool) -> String? {
        let range = NSRange(stream.startIndex..., in: stream)
        let duration = max(1, Int(end.timeIntervalSince(start).rounded()))
        if let m = flussonicTS.firstMatch(in: stream, range: range) {
            return group(m, 1, stream) + "/archive-\(unix(start))-\(duration).ts" + group(m, 2, stream)
        }
        if let m = flussonicHLS.firstMatch(in: stream, range: range) {
            let list = group(m, 2, stream)
            guard anyList || flussonicLists.contains(list.lowercased()) else { return nil }
            return group(m, 1, stream) + "/\(list)-\(unix(start))-\(duration).m3u8" + group(m, 3, stream)
        }
        return nil
    }

    private static let xtreamLive = try! NSRegularExpression(
        pattern: #"^(https?://[^/?#]+)/(?:live/)?([^/?#]+)/([^/?#]+)/(\d+)\.(ts|m3u8)(\?[^#]*)?$"#, options: [.caseInsensitive])

    private static func xtream(_ stream: String, start: Date, end: Date) -> String? {
        let range = NSRange(stream.startIndex..., in: stream)
        guard let m = xtreamLive.firstMatch(in: stream, range: range) else { return nil }
        let user = group(m, 2, stream), pass = group(m, 3, stream)
        guard !["movie", "series", "timeshift"].contains(user.lowercased()) else { return nil }
        let minutes = max(1, Int((end.timeIntervalSince(start) / 60).rounded(.up)))
        return "\(group(m, 1, stream))/timeshift/\(user)/\(pass)/\(minutes)/\(XtreamURLBuilder.timeshiftStart(start, serverTimezone: nil))/"
            + "\(group(m, 4, stream)).\(group(m, 5, stream))"
    }

    private static func group(_ m: NSTextCheckingResult, _ i: Int, _ s: String) -> String {
        guard i < m.numberOfRanges, let r = Range(m.range(at: i), in: s) else { return "" }
        return String(s[r])
    }

    private static func unix(_ date: Date) -> Int64 { Int64(date.timeIntervalSince1970.rounded(.down)) }

    // MARK: Placeholders

    /// Fills every known placeholder of `template` (see the type documentation).
    public static func format(_ template: String, start: Date, end: Date, now: Date) -> String {
        var out = ""
        var i = template.startIndex
        while i < template.endIndex {
            let c = template[i]
            let dollar = c == "$" && template.index(after: i) < template.endIndex && template[template.index(after: i)] == "{"
            guard c == "{" || dollar else {
                out.append(c)
                i = template.index(after: i)
                continue
            }
            let open = dollar ? template.index(after: i) : i
            guard let close = template[open...].firstIndex(of: "}") else {
                out.append(contentsOf: template[i...])
                break
            }
            let body = String(template[template.index(after: open)..<close])
            if let value = replacement(body, dollar: dollar, start: start, end: end, now: now) {
                out += value
            } else {
                out += template[i...close]
            }
            i = template.index(after: close)
        }
        return out
    }

    private static func replacement(_ body: String, dollar: Bool, start: Date, end: Date, now: Date) -> String? {
        let parts = body.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        let name = parts[0]
        let arg = parts.count > 1 ? parts[1] : nil
        let date: Date?
        switch name {
        case "utc", "start": date = start
        case "utcend", "end": date = end
        case "lutc", "now", "timestamp": date = now
        default: date = nil
        }
        if let date {
            if let arg { return formatDate(date, arg) }
            return String(unix(date))
        }
        func divided(_ seconds: TimeInterval) -> String {
            let divisor = arg.flatMap(Double.init) ?? 1
            guard divisor > 0 else { return String(Int64(seconds)) }
            return String(Int64((seconds / divisor).rounded(.down)))
        }
        switch name {
        case "duration": return divided(end.timeIntervalSince(start))
        case "offset": return divided(max(0, now.timeIntervalSince(start)))
        default: break
        }
        guard !dollar, arg == nil, name.count == 1, let token = name.first, dateTokens.contains(token) else { return nil }
        return formatDate(start, String(token))
    }

    private static let dateTokens: Set<Character> = ["Y", "m", "d", "H", "M", "S"]

    /// `Y m d H M S` (UTC, zero-padded) – every other character is literal.
    private static func formatDate(_ date: Date, _ pattern: String) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        func pad(_ v: Int?, _ width: Int = 2) -> String {
            let s = String(v ?? 0)
            return String(repeating: "0", count: max(0, width - s.count)) + s
        }
        return pattern.map { ch -> String in
            switch ch {
            case "Y": return pad(c.year, 4)
            case "m": return pad(c.month)
            case "d": return pad(c.day)
            case "H": return pad(c.hour)
            case "M": return pad(c.minute)
            case "S": return pad(c.second)
            default: return String(ch)
            }
        }.joined()
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
