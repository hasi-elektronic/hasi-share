import Foundation

/// One entry of `get_short_epg` (CONTRACT §4.3).
public struct XtreamShortEpgEntry: Codable, Sendable, Hashable {
    public var start: Date
    public var end: Date
    public var title: String?
    public var description: String?
    public var hasArchive: Bool

    public init(start: Date, end: Date, title: String?, description: String?, hasArchive: Bool) {
        self.start = start
        self.end = end
        self.title = title
        self.description = description
        self.hasArchive = hasArchive
    }
}

/// Series details from `get_series_info.info` (all optional; `info` may be `[]`).
public struct XtreamSeriesDetails: Codable, Sendable, Hashable {
    public var name: String?
    public var posterUrl: String?
    public var plot: String?
    public var genre: String?
    public var cast: String?
    public var director: String?
    public var rating: Double?
    public var year: Int?
    public var backdropUrl: String?
    public var categoryId: String?
    /// `youtube_trailer`: a YouTube video id or URL (see `YouTubeTrailer`).
    public var trailer: String? = nil
}

/// Result of `get_series_info`.
public struct XtreamSeriesInfo: Sendable, Hashable {
    public var details: XtreamSeriesDetails
    public var episodes: [Episode]
}

/// Result of `get_vod_info` (details screen).
public struct XtreamVodInfo: Codable, Sendable, Hashable {
    public var name: String?
    public var plot: String?
    public var genre: String?
    public var cast: String?
    public var director: String?
    public var rating: Double?
    public var year: Int?
    public var durationSec: Int?
    public var posterUrl: String?
    public var backdropUrl: String?
    public var containerExt: String?
    /// `youtube_trailer`: a YouTube video id or URL (see `YouTubeTrailer`).
    public var trailer: String? = nil
}

/// Maps lenient panel JSON to the domain model (CONTRACT §4.3 + test-vectors/README.md).
/// Items without an id are skipped; a malformed item never fails the whole list.
public enum XtreamMapper {
    /// List items of a response: an array, or the values of an object (sorted by numeric key).
    public static func listItems(_ json: JSONValue) -> [JSONValue] {
        switch json {
        case .array(let items): return items
        case .object(let object): return sortedByKey(object).map(\.1)
        default: return []
        }
    }

    static func sortedByKey(_ object: [String: JSONValue]) -> [(String, JSONValue)] {
        object.sorted { a, b in
            switch (Int(a.key), Int(b.key)) {
            case let (x?, y?): return x < y
            case (.some, nil): return true
            case (nil, .some): return false
            default: return a.key < b.key
            }
        }.map { ($0.key, $0.value) }
    }

    public static func categories(_ json: JSONValue, sourceId: String, kind: CategoryKind) -> [Category] {
        var out: [Category] = []
        for item in listItems(json) {
            guard let id = item["category_id"]?.stringValue else { continue }
            out.append(Category(sourceId: sourceId, id: id, kind: kind,
                                name: item["category_name"]?.stringValue ?? "", sort: out.count))
        }
        return out
    }

    public static func channels(_ json: JSONValue, sourceId: String) -> [Channel] {
        var out: [Channel] = []
        for item in listItems(json) {
            guard let id = item["stream_id"]?.stringValue else { continue }
            let archive = item["tv_archive"]?.boolValue ?? false
            let catchup = archive
                ? CatchupInfo(type: .xtream, days: item["tv_archive_duration"]?.intValue ?? 0)
                : CatchupInfo.none
            let categories = categoryIds(item)
            out.append(Channel(sourceId: sourceId, id: id, name: item["name"]?.stringValue ?? "",
                               number: item["num"]?.intValue, logoUrl: item["stream_icon"]?.stringValue,
                               categoryId: categories.first, epgId: item["epg_channel_id"]?.stringValue,
                               catchup: catchup, sort: out.count, categoryIds: categories))
        }
        return out
    }

    public static func movies(_ json: JSONValue, sourceId: String) -> [Movie] {
        var out: [Movie] = []
        for item in listItems(json) {
            guard let id = item["stream_id"]?.stringValue else { continue }
            let categories = categoryIds(item)
            out.append(Movie(sourceId: sourceId, id: id, name: item["name"]?.stringValue ?? "",
                             posterUrl: item["stream_icon"]?.stringValue, categoryId: categories.first,
                             rating: item["rating"]?.doubleValue, year: item["year"]?.intValue,
                             plot: item["plot"]?.stringValue, containerExt: item["container_extension"]?.stringValue,
                             addedAt: epochDate(item["added"]), sort: out.count, categoryIds: categories,
                             cast: text(item["cast"]), director: text(item["director"]), genre: text(item["genre"])))
        }
        return out
    }

    public static func series(_ json: JSONValue, sourceId: String) -> [Series] {
        var out: [Series] = []
        for item in listItems(json) {
            guard let id = item["series_id"]?.stringValue else { continue }
            let categories = categoryIds(item)
            out.append(Series(sourceId: sourceId, id: id, name: item["name"]?.stringValue ?? "",
                              posterUrl: item["cover"]?.stringValue, categoryId: categories.first,
                              plot: item["plot"]?.stringValue, rating: item["rating"]?.doubleValue,
                              year: year(item), sort: out.count, categoryIds: categories,
                              cast: text(item["cast"]), director: text(item["director"]), genre: text(item["genre"])))
        }
        return out
    }

    /// `cast` / `director` / `genre`: a string trimmed, or an array of strings joined with ", " (empty/null
    /// entries dropped); missing, null, "" or nothing left → nil (test-vectors/README.md).
    public static func text(_ value: JSONValue?) -> String? {
        if let array = value?.arrayValue {
            let parts = array.compactMap { $0.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            return parts.isEmpty ? nil : parts.joined(separator: ", ")
        }
        let trimmed = value?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    /// All categories of a list item (CONTRACT §4.3): `category_id` first, then the entries of
    /// `category_ids` (XUI.one / newer panels: ints or strings; `category_id` may be null, `""` or only
    /// the first of them). Empty/null entries are skipped, duplicates removed, order kept.
    static func categoryIds(_ item: JSONValue) -> [String] {
        var out: [String] = []
        let candidates = [item["category_id"]] + (item["category_ids"]?.arrayValue ?? []).map(Optional.some)
        for case let id? in candidates.map({ $0?.stringValue }) where !out.contains(id) { out.append(id) }
        return out
    }

    /// `year` field, else the first 4 digits of `releaseDate` / `release_date`.
    static func year(_ item: JSONValue) -> Int? {
        if let y = item["year"]?.intValue { return y }
        for key in ["releaseDate", "release_date"] {
            if let text = item[key]?.stringValue {
                let prefix = text.prefix(4)
                if prefix.count == 4, prefix.allSatisfy({ $0.isASCII && $0.isNumber }) { return Int(prefix) }
            }
        }
        return nil
    }

    static func epochDate(_ value: JSONValue?) -> Date? {
        guard let seconds = value?.int64Value, seconds > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(seconds))
    }

    /// Episodes of `get_series_info` in both shapes: `{"1":[…],"2":[…]}` or `[[…],[…]]`.
    /// Season = `episode.season`, fallback object key or array index + 1.
    public static func episodes(_ json: JSONValue, sourceId: String, seriesId: String) -> [Episode] {
        var groups: [(fallbackSeason: Int, items: [JSONValue])] = []
        switch json["episodes"] {
        case .object(let object)?:
            for (index, (key, value)) in sortedByKey(object).enumerated() {
                groups.append((Int(key) ?? index + 1, value.arrayValue ?? []))
            }
        case .array(let array)?:
            for (index, value) in array.enumerated() {
                if let items = value.arrayValue {
                    groups.append((index + 1, items))
                } else if value["id"] != nil {
                    groups.append((1, [value]))   // flat list variant
                }
            }
        default:
            break
        }
        var out: [Episode] = []
        for group in groups {
            for item in group.items {
                guard let id = item["id"]?.stringValue else { continue }
                let info = item["info"]?.objectValue ?? [:]
                let duration = info["duration_secs"]?.intValue ?? info["duration"]?.stringValue.flatMap(parseClock)
                out.append(Episode(sourceId: sourceId, id: id, seriesId: seriesId,
                                   season: item["season"]?.intValue ?? group.fallbackSeason,
                                   number: item["episode_num"]?.intValue ?? 0,
                                   title: item["title"]?.stringValue ?? "",
                                   containerExt: item["container_extension"]?.stringValue,
                                   durationSec: duration, plot: info["plot"]?.stringValue,
                                   posterUrl: info["movie_image"]?.stringValue))
            }
        }
        return out
    }

    /// Series details of `get_series_info.info`.
    public static func seriesDetails(_ json: JSONValue) -> XtreamSeriesDetails {
        let info = json["info"] ?? .null
        return XtreamSeriesDetails(name: info["name"]?.stringValue, posterUrl: info["cover"]?.stringValue,
                                   plot: info["plot"]?.stringValue, genre: text(info["genre"]),
                                   cast: text(info["cast"]), director: text(info["director"]),
                                   rating: info["rating"]?.doubleValue, year: year(info),
                                   backdropUrl: firstString(info["backdrop_path"]),
                                   categoryId: info["category_id"]?.stringValue,
                                   trailer: text(info["youtube_trailer"]) ?? text(info["trailer"]))
    }

    /// `get_vod_info` → details.
    public static func vodInfo(_ json: JSONValue) -> XtreamVodInfo {
        let info = json["info"] ?? .null
        let movie = json["movie_data"] ?? .null
        return XtreamVodInfo(name: info["name"]?.stringValue ?? movie["name"]?.stringValue,
                             plot: info["plot"]?.stringValue ?? info["description"]?.stringValue,
                             genre: text(info["genre"]), cast: text(info["cast"]) ?? text(info["actors"]),
                             director: text(info["director"]), rating: info["rating"]?.doubleValue,
                             year: year(info) ?? year(movie),
                             durationSec: info["duration_secs"]?.intValue ?? info["duration"]?.stringValue.flatMap(parseClock),
                             posterUrl: info["movie_image"]?.stringValue ?? info["cover_big"]?.stringValue,
                             backdropUrl: firstString(info["backdrop_path"]),
                             containerExt: movie["container_extension"]?.stringValue,
                             trailer: text(info["youtube_trailer"]) ?? text(info["trailer"]))
    }

    /// YouTube watch URL of a panel `youtube_trailer` value: a bare 11-character video id, or a
    /// youtube.com / youtu.be URL (anything else → nil).
    public static func trailerURL(_ value: String?) -> URL? {
        guard let raw = value?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        let idChars = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        if raw.count == 11, raw.unicodeScalars.allSatisfy(idChars.contains) {
            return URL(string: "https://www.youtube.com/watch?v=\(raw)")
        }
        guard let url = URL(string: raw), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host?.lowercased(), host == "youtu.be" || host == "youtube.com" || host.hasSuffix(".youtube.com") else { return nil }
        return url
    }

    static func firstString(_ value: JSONValue?) -> String? {
        if let array = value?.arrayValue { return array.lazy.compactMap(\.stringValue).first }
        return value?.stringValue
    }

    /// "HH:MM:SS" / "MM:SS" → seconds.
    static func parseClock(_ text: String) -> Int? {
        let parts = text.split(separator: ":").map { Int($0.trimmingCharacters(in: .whitespaces)) }
        guard !parts.isEmpty, parts.count <= 3, parts.allSatisfy({ $0 != nil }) else { return nil }
        return parts.reduce(0) { $0 * 60 + ($1 ?? 0) }
    }

    /// `get_short_epg` → entries. Titles/descriptions are base64 (raw string if decoding
    /// fails); timestamps prefer `start_timestamp`/`stop_timestamp`, fallback `start`/`end`
    /// ("yyyy-MM-dd HH:mm:ss" in the server zone). Unparsable entries are skipped.
    public static func shortEpg(_ json: JSONValue, serverTimezone: String? = nil) -> [XtreamShortEpgEntry] {
        let listings = json["epg_listings"].map(listItems) ?? listItems(json)
        var out: [XtreamShortEpgEntry] = []
        for item in listings {
            guard let start = timestamp(item["start_timestamp"]) ?? panelTime(item["start"], serverTimezone),
                  let end = timestamp(item["stop_timestamp"]) ?? timestamp(item["end_timestamp"]) ?? panelTime(item["end"], serverTimezone) ?? panelTime(item["stop"], serverTimezone)
            else { continue }
            out.append(XtreamShortEpgEntry(start: start, end: end,
                                           title: decodeBase64Text(item["title"]?.stringValue),
                                           description: decodeBase64Text(item["description"]?.stringValue),
                                           hasArchive: item["has_archive"]?.boolValue ?? false))
        }
        return out
    }

    static func timestamp(_ value: JSONValue?) -> Date? {
        guard let seconds = value?.int64Value else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(seconds))
    }

    static func panelTime(_ value: JSONValue?, _ zone: String?) -> Date? {
        guard let text = value?.stringValue else { return nil }
        let parts = text.split(whereSeparator: { $0 == "-" || $0 == " " || $0 == ":" || $0 == "T" }).compactMap { Int($0) }
        guard parts.count >= 5 else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone.flatMap { TimeZone(identifier: $0) } ?? TimeZone(identifier: "UTC")!
        let components = DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: parts[3],
                                        minute: parts[4], second: parts.count > 5 ? parts[5] : 0)
        return calendar.date(from: components)
    }

    /// Base64 (UTF-8) → text; raw input when it is not valid base64/UTF-8 text. Empty → nil.
    public static func decodeBase64Text(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        var candidate = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let remainder = candidate.utf8.count % 4
        if remainder > 0 { candidate += String(repeating: "=", count: 4 - remainder) }
        if let data = Data(base64Encoded: candidate), let text = String(data: data, encoding: .utf8),
           !text.unicodeScalars.contains(where: { $0.value < 0x20 && $0 != "\n" && $0 != "\r" && $0 != "\t" }) {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        return raw
    }
}

/// Account classification of `player_api.php` without action (CONTRACT §4.4).
public enum XtreamAccountClassifier {
    /// Classifies an HTTP response. Network failures are classified by the caller
    /// (`ErrorClassifier.sourceError(from:)`).
    public static func classify(httpStatus: Int, body: Data, now: Date) -> Result<XtreamAccountInfo, SourceError> {
        if let error = ErrorClassifier.sourceError(httpStatus: httpStatus) { return .failure(error) }
        guard let json = JSONValue.parse(body) else { return .failure(.invalidResponse) }
        let root: [String: JSONValue]
        switch json {
        case .object(let object): root = object
        case .array(let array) where array.isEmpty: root = [:]   // `[]` = empty object (§4.3)
        default: return .failure(.invalidResponse)
        }
        guard let userInfo = root["user_info"]?.objectValue, !userInfo.isEmpty,
              userInfo["auth"]?.intValue == 1 else { return .failure(.invalidCredentials) }
        let status = userInfo["status"]?.stringValue ?? ""
        let expiresAt = XtreamMapper.epochDate(userInfo["exp_date"])
        switch status.lowercased() {
        case "expired": return .failure(.accountExpired(expiresAt: expiresAt))
        case "banned", "disabled": return .failure(.accountDisabled)
        default: break
        }
        if let expiresAt, expiresAt < now { return .failure(.accountExpired(expiresAt: expiresAt)) }
        let serverInfo = root["server_info"]?.objectValue ?? [:]
        let formats = (userInfo["allowed_output_formats"]?.arrayValue ?? []).compactMap { $0.stringValue?.lowercased() }
        return .success(XtreamAccountInfo(status: status.isEmpty ? "Active" : status, expiresAt: expiresAt,
                                          maxConnections: userInfo["max_connections"]?.intValue,
                                          activeConnections: userInfo["active_cons"]?.intValue,
                                          allowedOutputFormats: formats,
                                          serverTimezone: serverInfo["timezone"]?.stringValue ?? "UTC"))
    }
}
