import Foundation

/// Kind of an M3U entry (CONTRACT §3.9).
public enum M3UEntryKind: String, Codable, Sendable, Hashable {
    case live, movie, episode

    public var contentKind: ContentKind {
        switch self {
        case .live: return .live
        case .movie: return .movie
        case .episode: return .episode
        }
    }
}

/// Series information extracted from an entry title (`… S01E02`).
public struct M3USeriesInfo: Codable, Sendable, Hashable {
    public var name: String
    public var season: Int
    public var episode: Int

    public init(name: String, season: Int, episode: Int) {
        self.name = name
        self.season = season
        self.episode = episode
    }
}

/// One parsed playlist entry (schema of `test-vectors/m3u/*.expected.json`).
public struct M3UEntry: Codable, Sendable, Hashable {
    public var name: String
    public var url: String
    public var kind: M3UEntryKind
    public var tvgId: String?
    public var tvgName: String?
    public var logo: String?
    public var group: String?
    public var chno: Int?
    /// `#EXTINF` duration; -1 if absent/unparsable.
    public var duration: Double
    public var catchup: CatchupInfo?
    public var tvgShiftHours: Double?
    public var userAgent: String?
    public var referrer: String?
    public var drm: Bool
    public var series: M3USeriesInfo?

    public init(name: String, url: String, kind: M3UEntryKind, tvgId: String? = nil, tvgName: String? = nil,
                logo: String? = nil, group: String? = nil, chno: Int? = nil, duration: Double = -1,
                catchup: CatchupInfo? = nil, tvgShiftHours: Double? = nil, userAgent: String? = nil,
                referrer: String? = nil, drm: Bool = false, series: M3USeriesInfo? = nil) {
        self.name = name
        self.url = url
        self.kind = kind
        self.tvgId = tvgId
        self.tvgName = tvgName
        self.logo = logo
        self.group = group
        self.chno = chno
        self.duration = duration
        self.catchup = catchup
        self.tvgShiftHours = tvgShiftHours
        self.userAgent = userAgent
        self.referrer = referrer
        self.drm = drm
        self.series = series
    }

    /// Item id used in content keys: `"u" + hex(sha256(url))[0..16]`.
    public var itemId: String { ContentKey.m3uItemId(entryUrl: url) }
}

/// Counters of a finished parse.
public struct M3UParseSummary: Sendable, Hashable {
    /// EPG URLs from `url-tvg` / `x-tvg-url` header attributes (deduplicated, in order).
    public var epgUrls: [String]
    /// Entries dropped (bad scheme, `#EXTINF` without URL, garbage lines).
    public var skipped: Int
    /// Entries emitted.
    public var entryCount: Int
    /// `#EXTM3U` header seen.
    public var sawHeader: Bool
    /// At least one `#EXTINF` line seen.
    public var sawExtinf: Bool

    public init(epgUrls: [String] = [], skipped: Int = 0, entryCount: Int = 0, sawHeader: Bool = false, sawExtinf: Bool = false) {
        self.epgUrls = epgUrls
        self.skipped = skipped
        self.entryCount = entryCount
        self.sawHeader = sawHeader
        self.sawExtinf = sawExtinf
    }

    /// CONTRACT §3.11: throws `SourceError.invalidFormat` (nothing M3U-like at all) or
    /// `SourceError.empty` (valid but zero entries).
    public func validate() throws {
        guard entryCount == 0 else { return }
        if !sawHeader && !sawExtinf { throw SourceError.invalidFormat }
        throw SourceError.empty
    }
}

/// Complete in-memory parse result (convenience for small playlists and tests).
public struct M3UParseResult: Sendable, Hashable {
    public var epgUrls: [String]
    public var skipped: Int
    public var entries: [M3UEntry]

    public init(epgUrls: [String], skipped: Int, entries: [M3UEntry]) {
        self.epgUrls = epgUrls
        self.skipped = skipped
        self.entries = entries
    }
}
