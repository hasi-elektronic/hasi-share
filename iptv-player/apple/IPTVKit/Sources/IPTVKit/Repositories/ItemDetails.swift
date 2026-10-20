import Foundation
import IPTVCore

/// Detail-page metadata of a movie or series (IOS-09): Xtream `get_vod_info` / `get_series_info`, cached in
/// `item_details` with its fetch time. `genre` is the provider's genre text – never the category name.
public struct ItemDetails: Codable, Sendable, Hashable {
    public var plot: String?
    public var genre: String?
    public var cast: String?
    public var director: String?
    public var year: Int?
    public var rating: Double?
    public var durationSec: Int?
    /// YouTube id or URL (`youtube_trailer`).
    public var trailer: String?
    /// The panel's TMDB id (`tmdb_id` / `tmdb`) – metadata lookups skip name matching (CONTRACT §11.2).
    public var tmdbId: Int?

    public init(plot: String? = nil, genre: String? = nil, cast: String? = nil, director: String? = nil, year: Int? = nil,
                rating: Double? = nil, durationSec: Int? = nil, trailer: String? = nil, tmdbId: Int? = nil) {
        self.plot = plot
        self.genre = genre
        self.cast = cast
        self.director = director
        self.year = year
        self.rating = rating
        self.durationSec = durationSec
        self.trailer = trailer
        self.tmdbId = tmdbId
    }

    public init(_ info: XtreamVodInfo) {
        self.init(plot: info.plot, genre: info.genre, cast: info.cast, director: info.director, year: info.year,
                  rating: info.rating, durationSec: info.durationSec, trailer: info.trailer, tmdbId: info.tmdbId)
    }

    public init(_ details: XtreamSeriesDetails) {
        self.init(plot: details.plot, genre: details.genre, cast: details.cast, director: details.director,
                  year: details.year, rating: details.rating, trailer: details.trailer, tmdbId: details.tmdbId)
    }

    /// YouTube watch URL of the trailer, if any.
    public var trailerURL: URL? { XtreamMapper.trailerURL(trailer) }

    /// Revalidation age of cached details and episodes (stale-while-revalidate): weekly series get new episodes.
    public static let ttl: TimeInterval = 6 * 3600
}
