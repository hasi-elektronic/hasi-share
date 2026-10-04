import Foundation

/// Kind of a playable/browsable item (CONTRACT §1). Raw values are part of content keys.
public enum ContentKind: String, Codable, Sendable, Hashable, CaseIterable {
    case live, movie, series, episode
}

/// Kind of a category list.
public enum CategoryKind: String, Codable, Sendable, Hashable, CaseIterable {
    case live, movie, series

    /// The content kind listed by this category.
    public var contentKind: ContentKind {
        switch self {
        case .live: return .live
        case .movie: return .movie
        case .series: return .series
        }
    }
}

/// Catch-up (archive) flavour of a channel.
public enum CatchupType: String, Codable, Sendable, Hashable, CaseIterable {
    case none, xtream, `default`, append, shift, flussonic

    /// Maps an M3U `catchup`/`catchup-type` attribute value. Unknown values → `.default`.
    public init(m3uValue: String) {
        switch m3uValue.trimmingCharacters(in: .whitespaces).lowercased() {
        case "append": self = .append
        case "shift", "timeshift": self = .shift
        case "flussonic", "flussonic-hls", "flussonic-ts", "fs": self = .flussonic
        case "xc", "xtream": self = .xtream
        case "none", "disabled": self = .none
        default: self = .default
        }
    }
}

/// Catch-up capability of a channel.
public struct CatchupInfo: Codable, Sendable, Hashable {
    public var type: CatchupType
    /// Archive depth in days (0 = unknown/none).
    public var days: Int
    /// M3U `catchup-source` template, if any.
    public var source: String?

    public init(type: CatchupType, days: Int, source: String? = nil) {
        self.type = type
        self.days = days
        self.source = source
    }

    /// No catch-up.
    public static let none = CatchupInfo(type: .none, days: 0, source: nil)

    /// True when the channel offers an archive.
    public var isAvailable: Bool { type != .none }
}

/// A category of a source (CONTRACT §1).
public struct Category: Codable, Sendable, Hashable, Identifiable {
    public var sourceId: String
    public var id: String
    public var kind: CategoryKind
    public var name: String
    public var sort: Int

    public init(sourceId: String, id: String, kind: CategoryKind, name: String, sort: Int) {
        self.sourceId = sourceId
        self.id = id
        self.kind = kind
        self.name = name
        self.sort = sort
    }
}

/// A live channel (CONTRACT §1). `url` is only set for M3U sources; Xtream URLs are
/// built at play time from the source secrets and never persisted.
public struct Channel: Codable, Sendable, Hashable, Identifiable {
    public var sourceId: String
    public var id: String
    public var name: String
    public var number: Int?
    public var logoUrl: String?
    public var categoryId: String?
    public var epgId: String?
    public var catchup: CatchupInfo
    public var url: String?
    public var userAgent: String?
    public var referrer: String?
    public var drm: Bool
    public var sort: Int

    public init(sourceId: String, id: String, name: String, number: Int? = nil, logoUrl: String? = nil,
                categoryId: String? = nil, epgId: String? = nil, catchup: CatchupInfo = .none,
                url: String? = nil, userAgent: String? = nil, referrer: String? = nil,
                drm: Bool = false, sort: Int = 0) {
        self.sourceId = sourceId
        self.id = id
        self.name = name
        self.number = number
        self.logoUrl = logoUrl
        self.categoryId = categoryId
        self.epgId = epgId
        self.catchup = catchup
        self.url = url
        self.userAgent = userAgent
        self.referrer = referrer
        self.drm = drm
        self.sort = sort
    }
}

/// A movie / VOD item (CONTRACT §1).
public struct Movie: Codable, Sendable, Hashable, Identifiable {
    public var sourceId: String
    public var id: String
    public var name: String
    public var posterUrl: String?
    public var categoryId: String?
    public var rating: Double?
    public var year: Int?
    public var plot: String?
    public var containerExt: String?
    public var url: String?
    public var addedAt: Date?
    /// Position in the source list (stable ordering for "added"/default sorting).
    public var sort: Int

    public init(sourceId: String, id: String, name: String, posterUrl: String? = nil,
                categoryId: String? = nil, rating: Double? = nil, year: Int? = nil,
                plot: String? = nil, containerExt: String? = nil, url: String? = nil,
                addedAt: Date? = nil, sort: Int = 0) {
        self.sourceId = sourceId
        self.id = id
        self.name = name
        self.posterUrl = posterUrl
        self.categoryId = categoryId
        self.rating = rating
        self.year = year
        self.plot = plot
        self.containerExt = containerExt
        self.url = url
        self.addedAt = addedAt
        self.sort = sort
    }
}

/// A series (CONTRACT §1).
public struct Series: Codable, Sendable, Hashable, Identifiable {
    public var sourceId: String
    public var id: String
    public var name: String
    public var posterUrl: String?
    public var categoryId: String?
    public var plot: String?
    public var rating: Double?
    public var year: Int?
    public var sort: Int

    public init(sourceId: String, id: String, name: String, posterUrl: String? = nil,
                categoryId: String? = nil, plot: String? = nil, rating: Double? = nil,
                year: Int? = nil, sort: Int = 0) {
        self.sourceId = sourceId
        self.id = id
        self.name = name
        self.posterUrl = posterUrl
        self.categoryId = categoryId
        self.plot = plot
        self.rating = rating
        self.year = year
        self.sort = sort
    }
}

/// An episode of a series (CONTRACT §1).
public struct Episode: Codable, Sendable, Hashable, Identifiable {
    public var sourceId: String
    public var id: String
    public var seriesId: String
    public var season: Int
    public var number: Int
    public var title: String
    public var containerExt: String?
    public var durationSec: Int?
    public var plot: String?
    public var posterUrl: String?
    public var url: String?

    public init(sourceId: String, id: String, seriesId: String, season: Int, number: Int,
                title: String, containerExt: String? = nil, durationSec: Int? = nil,
                plot: String? = nil, posterUrl: String? = nil, url: String? = nil) {
        self.sourceId = sourceId
        self.id = id
        self.seriesId = seriesId
        self.season = season
        self.number = number
        self.title = title
        self.containerExt = containerExt
        self.durationSec = durationSec
        self.plot = plot
        self.posterUrl = posterUrl
        self.url = url
    }
}

/// One EPG programme (CONTRACT §1). Times are UTC instants with the source's EPG shift applied.
public struct EpgProgram: Codable, Sendable, Hashable {
    public var sourceId: String
    public var channelEpgId: String
    public var start: Date
    public var end: Date
    public var title: String
    public var description: String?
    public var category: String?

    public init(sourceId: String, channelEpgId: String, start: Date, end: Date, title: String,
                description: String? = nil, category: String? = nil) {
        self.sourceId = sourceId
        self.channelEpgId = channelEpgId
        self.start = start
        self.end = end
        self.title = title
        self.description = description
        self.category = category
    }

    /// Programme duration in seconds.
    public var duration: TimeInterval { end.timeIntervalSince(start) }

    /// True if `date` lies in `[start, end)`.
    public func isOnAir(at date: Date) -> Bool { start <= date && date < end }
}
