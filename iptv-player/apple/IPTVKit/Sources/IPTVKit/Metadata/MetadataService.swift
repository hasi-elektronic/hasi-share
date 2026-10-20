import Foundation
import IPTVCore

/// TMDB posters, plot, rating, cast and trailer through the backend (CONTRACT §11, BACKEND_API.md "Metadata").
///
/// Everything is best effort: every method answers nil when the backend is not configured, unreachable or
/// answers `503 metadata_unavailable` – the views then keep the provider's own fields. After a 503 the service
/// stays quiet for `retryAfter` (30 min when the backend has no TMDB key at all), after a 429 or a transport
/// failure for a short while, so a scrolling grid never hammers a backend that cannot answer.
///
/// Only the title text (and the provider's year / TMDB id) leaves the device – never source, account or
/// stream data. Answers are kept in memory for the session (the backend and its HTTP caching hold the rest).
public actor MetadataService {
    /// What identifies a provider item for TMDB.
    public struct Lookup: Hashable, Sendable {
        /// Raw provider name ("DE | Inception (2010) 4K"); the backend parses it.
        public var name: String
        public var type: MediaType
        /// The provider's year, overrides the one in the name.
        public var year: Int?
        /// The provider's TMDB id (`get_vod_info` → `tmdb_id`): skips matching.
        public var tmdbId: Int?

        public init(name: String, type: MediaType, year: Int? = nil, tmdbId: Int? = nil) {
            self.name = name
            self.type = type
            self.year = year
            self.tmdbId = tmdbId
        }
    }

    /// Quiet period after `503 metadata_unavailable` without `retryAfter` (no TMDB key on the backend).
    static let unconfiguredBackoff: TimeInterval = 30 * 60
    /// Quiet period after `429` / offline / 5xx.
    static let transientBackoff: TimeInterval = 60
    /// Entries per in-memory cache before it is dropped (titles of a long scroll session).
    static let cacheLimit = 1000

    private let backend: BackendClient?
    private let now: @Sendable () -> Date
    private var matches: [String: MetadataSearchResult?] = [:]
    private var details: [String: MediaMetadata?] = [:]
    private var inFlightMatches: [String: Task<MetadataSearchResult??, Never>] = [:]
    private var inFlightDetails: [String: Task<MediaMetadata??, Never>] = [:]
    private var quietUntil: Date?

    /// - Parameter backend: nil when no backend is configured (placeholder config) – every lookup answers nil.
    public init(backend: BackendClient?, now: @escaping @Sendable () -> Date = Date.init) {
        self.backend = backend
        self.now = now
    }

    /// True while lookups are paused after a 503 / 429 / transport failure.
    public var isPaused: Bool {
        guard let quietUntil else { return false }
        return now() < quietUntil
    }

    /// Best TMDB candidate of a provider name (poster for grids without provider artwork), nil without a match.
    public func match(_ lookup: Lookup, language: MetadataLanguage) async -> MetadataSearchResult? {
        guard let backend, !lookup.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let key = "\(lookup.type.rawValue)|\(language.rawValue)|\(lookup.year ?? 0)|\(lookup.name)"
        if let hit = matches[key] { return hit }
        if let running = inFlightMatches[key] { return await running.value ?? nil }
        guard !isPaused else { return nil }
        let task = Task<MetadataSearchResult??, Never> {
            do {
                let result = try await backend.metadataMatch(name: lookup.name, type: lookup.type, year: lookup.year, language: language)
                return .some(result.match)
            } catch {
                self.handle(error)
                return .none
            }
        }
        inFlightMatches[key] = task
        let value = await task.value
        inFlightMatches[key] = nil
        if let value { store(value, key, in: &matches) }
        return value ?? nil
    }

    /// Full TMDB details: by the provider's TMDB id when known, else by matching the name.
    public func details(_ lookup: Lookup, language: MetadataLanguage) async -> MediaMetadata? {
        let tmdbId: Int
        if let id = lookup.tmdbId {
            tmdbId = id
        } else {
            guard let match = await match(lookup, language: language) else { return nil }
            tmdbId = match.tmdbId
        }
        return await details(tmdbId: tmdbId, type: lookup.type, language: language)
    }

    /// `GET /v1/metadata/{tmdbId}` (cached, deduplicated).
    public func details(tmdbId: Int, type: MediaType, language: MetadataLanguage) async -> MediaMetadata? {
        guard let backend else { return nil }
        let key = "\(type.rawValue)|\(language.rawValue)|\(tmdbId)"
        if let hit = details[key] { return hit }
        if let running = inFlightDetails[key] { return await running.value ?? nil }
        guard !isPaused else { return nil }
        let task = Task<MediaMetadata??, Never> {
            do {
                return .some(try await backend.metadata(tmdbId: tmdbId, type: type, language: language))
            } catch {
                self.handle(error)
                return .none
            }
        }
        inFlightDetails[key] = task
        let value = await task.value
        inFlightDetails[key] = nil
        if let value { store(value, key, in: &details) }
        return value ?? nil
    }

    /// Settings → Diagnostics "Clear image cache" also forgets metadata answers and an active pause.
    public func clear() {
        matches.removeAll()
        details.removeAll()
        quietUntil = nil
    }

    // MARK: Private

    private func store<V>(_ value: V?, _ key: String, in cache: inout [String: V?]) {
        if cache.count >= Self.cacheLimit { cache.removeAll(keepingCapacity: true) }
        cache[key] = .some(value)
    }

    /// Cancellation and malformed answers are not cached and do not pause; unavailability does.
    private func handle(_ error: Error) {
        if let unavailable = error as? MetadataUnavailable {
            let seconds = unavailable.retryAfter.map { TimeInterval(max(5, $0)) } ?? Self.unconfiguredBackoff
            pause(seconds)
        } else if let backendError = error as? BackendError, backendError.isTransient {
            pause(Self.transientBackoff)
        }
    }

    private func pause(_ seconds: TimeInterval) {
        let until = now().addingTimeInterval(seconds)
        if quietUntil.map({ $0 < until }) ?? true { quietUntil = until }
        SafeLog.info("metadata paused for \(Int(seconds)) s")
    }
}

public extension MetadataService.Lookup {
    /// Raw provider name + year (the backend strips prefixes / tags itself, CONTRACT §11.2).
    init(_ movie: Movie, tmdbId: Int? = nil) {
        self.init(name: movie.name, type: .movie, year: movie.year, tmdbId: tmdbId)
    }

    init(_ series: Series, tmdbId: Int? = nil) {
        self.init(name: series.name, type: .tv, year: series.year, tmdbId: tmdbId)
    }
}
