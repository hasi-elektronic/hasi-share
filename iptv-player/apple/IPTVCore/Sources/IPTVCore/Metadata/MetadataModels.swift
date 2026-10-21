import Foundation

// Wire models of CONTRACT §11.1 (TMDB metadata through the backend). Decoders are lenient: unknown
// fields are ignored, every optional field may be missing or `null`, and a malformed optional value
// (wrong type) reads as nil instead of failing the whole answer.

/// `movie` | `tv` (tv = series).
public enum MediaType: String, Codable, Sendable, Hashable, CaseIterable {
    case movie, tv
}

/// UI language of the metadata (`de` | `tr` | `en`); TMDB gets de-DE / tr-TR / en-US.
public enum MetadataLanguage: String, Codable, Sendable, Hashable, CaseIterable {
    case de, tr, en

    /// The metadata language of a UI language code ("de", "tr-TR", "en_GB"); anything else → `.en`.
    public init(code: String) {
        self = MetadataLanguage(rawValue: String(code.prefix(2)).lowercased()) ?? .en
    }
}

/// One cast entry (billing order, max 10).
public struct MetadataCastMember: Codable, Sendable, Hashable {
    public var name: String
    public var character: String?
    /// `https://image.tmdb.org/t/p/w185/…`.
    public var profileUrl: String?

    public init(name: String, character: String? = nil, profileUrl: String? = nil) {
        self.name = name
        self.character = character
        self.profileUrl = profileUrl
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        character = c.lenient(String.self, .character)
        profileUrl = c.lenient(String.self, .profileUrl)
    }
}

/// `GET /v1/metadata/{tmdbId}`.
public struct MediaMetadata: Codable, Sendable, Hashable {
    public var tmdbId: Int
    public var type: MediaType
    public var title: String
    public var originalTitle: String?
    /// UI language, English fallback when untranslated.
    public var overview: String?
    /// `…/w500/…`.
    public var posterUrl: String?
    /// `…/w1280/…`.
    public var backdropUrl: String?
    /// Vote average 0..10 (1 decimal); nil when `voteCount` = 0.
    public var rating: Double?
    public var voteCount: Int
    /// "YYYY-MM-DD" (tv: first air date).
    public var releaseDate: String?
    /// Localized genre names.
    public var genres: [String]
    public var cast: [MetadataCastMember]
    /// `https://www.youtube.com/watch?v=KEY`.
    public var trailerUrl: String?
    public var runtimeMinutes: Int?
    /// tv only.
    public var seasons: Int?
    public var language: MetadataLanguage?

    public init(tmdbId: Int, type: MediaType, title: String, originalTitle: String? = nil, overview: String? = nil,
                posterUrl: String? = nil, backdropUrl: String? = nil, rating: Double? = nil, voteCount: Int = 0,
                releaseDate: String? = nil, genres: [String] = [], cast: [MetadataCastMember] = [],
                trailerUrl: String? = nil, runtimeMinutes: Int? = nil, seasons: Int? = nil, language: MetadataLanguage? = nil) {
        self.tmdbId = tmdbId
        self.type = type
        self.title = title
        self.originalTitle = originalTitle
        self.overview = overview
        self.posterUrl = posterUrl
        self.backdropUrl = backdropUrl
        self.rating = rating
        self.voteCount = voteCount
        self.releaseDate = releaseDate
        self.genres = genres
        self.cast = cast
        self.trailerUrl = trailerUrl
        self.runtimeMinutes = runtimeMinutes
        self.seasons = seasons
        self.language = language
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tmdbId = try c.decode(Int.self, forKey: .tmdbId)
        type = try c.decode(MediaType.self, forKey: .type)
        title = try c.decode(String.self, forKey: .title)
        originalTitle = c.lenient(String.self, .originalTitle)
        overview = c.lenient(String.self, .overview)
        posterUrl = c.lenient(String.self, .posterUrl)
        backdropUrl = c.lenient(String.self, .backdropUrl)
        rating = c.lenient(Double.self, .rating)
        voteCount = c.lenient(Int.self, .voteCount) ?? 0
        releaseDate = c.lenient(String.self, .releaseDate)
        genres = c.lenient([String].self, .genres) ?? []
        cast = c.lenient([Lenient<MetadataCastMember>].self, .cast)?.compactMap(\.value) ?? []
        trailerUrl = c.lenient(String.self, .trailerUrl)
        runtimeMinutes = c.lenient(Int.self, .runtimeMinutes)
        seasons = c.lenient(Int.self, .seasons)
        language = c.lenient(MetadataLanguage.self, .language)
    }

    /// Year of `releaseDate`.
    public var year: Int? { MetadataDate.year(releaseDate) }

    /// Trailer as a URL (YouTube only).
    public var trailerURL: URL? { trailerUrl.flatMap(URL.init(string:)) }
}

/// One TMDB candidate (`/search`, `match` in `/match`).
public struct MetadataSearchResult: Codable, Sendable, Hashable {
    public var tmdbId: Int
    public var type: MediaType
    public var title: String
    public var originalTitle: String?
    public var overview: String?
    public var posterUrl: String?
    public var backdropUrl: String?
    public var rating: Double?
    public var voteCount: Int
    public var releaseDate: String?

    public init(tmdbId: Int, type: MediaType, title: String, originalTitle: String? = nil, overview: String? = nil,
                posterUrl: String? = nil, backdropUrl: String? = nil, rating: Double? = nil, voteCount: Int = 0,
                releaseDate: String? = nil) {
        self.tmdbId = tmdbId
        self.type = type
        self.title = title
        self.originalTitle = originalTitle
        self.overview = overview
        self.posterUrl = posterUrl
        self.backdropUrl = backdropUrl
        self.rating = rating
        self.voteCount = voteCount
        self.releaseDate = releaseDate
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tmdbId = try c.decode(Int.self, forKey: .tmdbId)
        type = try c.decode(MediaType.self, forKey: .type)
        title = try c.decode(String.self, forKey: .title)
        originalTitle = c.lenient(String.self, .originalTitle)
        overview = c.lenient(String.self, .overview)
        posterUrl = c.lenient(String.self, .posterUrl)
        backdropUrl = c.lenient(String.self, .backdropUrl)
        rating = c.lenient(Double.self, .rating)
        voteCount = c.lenient(Int.self, .voteCount) ?? 0
        releaseDate = c.lenient(String.self, .releaseDate)
    }

    public var year: Int? { MetadataDate.year(releaseDate) }
}

/// The backend's reading of a raw IPTV name (§11.2).
public struct ParsedVodName: Codable, Sendable, Hashable {
    public var title: String
    public var year: Int?
    public var yearInBrackets: Bool
    public var season: Int?
    public var episode: Int?

    public init(title: String, year: Int? = nil, yearInBrackets: Bool = false, season: Int? = nil, episode: Int? = nil) {
        self.title = title
        self.year = year
        self.yearInBrackets = yearInBrackets
        self.season = season
        self.episode = episode
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = try c.decode(String.self, forKey: .title)
        year = c.lenient(Int.self, .year)
        yearInBrackets = c.lenient(Bool.self, .yearInBrackets) ?? false
        season = c.lenient(Int.self, .season)
        episode = c.lenient(Int.self, .episode)
    }
}

/// `GET /v1/metadata/match`: `match` is set iff `confidence ≥ 0.75`.
public struct MetadataMatch: Codable, Sendable, Hashable {
    public var parsed: ParsedVodName?
    public var match: MetadataSearchResult?
    public var confidence: Double

    public init(parsed: ParsedVodName? = nil, match: MetadataSearchResult? = nil, confidence: Double = 0) {
        self.parsed = parsed
        self.match = match
        self.confidence = confidence
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        parsed = c.lenient(ParsedVodName.self, .parsed)
        match = c.lenient(MetadataSearchResult.self, .match)
        confidence = c.lenient(Double.self, .confidence) ?? 0
    }
}

enum MetadataDate {
    /// "2010-07-15" → 2010.
    static func year(_ date: String?) -> Int? {
        guard let date, date.count >= 4, let y = Int(date.prefix(4)), (1800...2200).contains(y) else { return nil }
        return y
    }
}

/// Decodes an element or yields nil (one malformed cast entry never fails the answer).
private struct Lenient<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) throws { value = try? T(from: decoder) }
}

private extension KeyedDecodingContainer {
    /// Missing, `null` or wrongly typed → nil.
    func lenient<T: Decodable>(_ type: T.Type, _ key: Key) -> T? {
        (try? decodeIfPresent(type, forKey: key)) ?? nil
    }
}
