import Foundation

/// Everything a full Xtream refresh produces.
public struct XtreamCatalog: Sendable, Hashable {
    public var account: XtreamAccountInfo
    public var liveCategories: [Category]
    public var vodCategories: [Category]
    public var seriesCategories: [Category]
    public var channels: [Channel]
    public var movies: [Movie]
    public var series: [Series]

    /// Summary for `Source.lastRefreshResult`.
    public var status: SourceStatus {
        SourceStatus(error: nil, liveCount: channels.count, movieCount: movies.count, seriesCount: series.count)
    }
}

/// Async Xtream Codes API client (CONTRACT §4). Every method throws `SourceError`
/// (`.cancelled` on task cancellation). GETs are retried per `RetryPolicy`.
public struct XtreamClient: Sendable {
    public let sourceId: String
    public let urls: XtreamURLBuilder
    private let transport: any HTTPTransport
    private let retryPolicy: RetryPolicy
    private let sleeper: Sleeper
    private let headers: [String: String]

    public init(sourceId: String, urls: XtreamURLBuilder, transport: any HTTPTransport = URLSessionTransport.shared,
                retryPolicy: RetryPolicy = .sourceDefault, sleeper: Sleeper = .live, userAgent: String? = nil) {
        self.sourceId = sourceId
        self.urls = urls
        self.transport = transport
        self.retryPolicy = retryPolicy
        self.sleeper = sleeper
        self.headers = userAgent.map { ["User-Agent": $0] } ?? [:]
    }

    /// Returns nil when the server URL cannot be normalized.
    public init?(sourceId: String, secrets: XtreamSecrets, transport: any HTTPTransport = URLSessionTransport.shared,
                 retryPolicy: RetryPolicy = .sourceDefault, sleeper: Sleeper = .live, userAgent: String? = nil) {
        guard let urls = XtreamURLBuilder(secrets: secrets) else { return nil }
        self.init(sourceId: sourceId, urls: urls, transport: transport, retryPolicy: retryPolicy,
                  sleeper: sleeper, userAgent: userAgent)
    }

    /// Source fingerprint (CONTRACT §1.1).
    public var fingerprint: String { SourceFingerprint.xtream(host: urls.host, username: urls.username) }

    // MARK: Account

    /// `player_api.php` without action, classified per CONTRACT §4.4.
    public func authenticate(now: Date = Date()) async throws -> XtreamAccountInfo {
        let request = HTTPRequest(url: urls.apiURL(), headers: headers, timeouts: .xtreamJSON)
        return try await retryPolicy.run(sleeper: sleeper) {
            let response = try await transport.send(request)
            return try XtreamAccountClassifier.classify(httpStatus: response.statusCode, body: response.body, now: now).get()
        }
    }

    // MARK: Lists

    public func liveCategories() async throws -> [Category] {
        XtreamMapper.categories(try await list("get_live_categories"), sourceId: sourceId, kind: .live)
    }

    public func vodCategories() async throws -> [Category] {
        XtreamMapper.categories(try await list("get_vod_categories"), sourceId: sourceId, kind: .movie)
    }

    public func seriesCategories() async throws -> [Category] {
        XtreamMapper.categories(try await list("get_series_categories"), sourceId: sourceId, kind: .series)
    }

    public func liveStreams() async throws -> [Channel] {
        XtreamMapper.channels(try await list("get_live_streams"), sourceId: sourceId)
    }

    public func vodStreams() async throws -> [Movie] {
        XtreamMapper.movies(try await list("get_vod_streams"), sourceId: sourceId)
    }

    public func series() async throws -> [Series] {
        XtreamMapper.series(try await list("get_series"), sourceId: sourceId)
    }

    // MARK: Details

    /// `get_series_info` (both episode shapes).
    public func seriesInfo(seriesId: String) async throws -> XtreamSeriesInfo {
        let json = try await getJSON(urls.apiURL(action: "get_series_info", parameters: [("series_id", seriesId)]))
        return XtreamSeriesInfo(details: XtreamMapper.seriesDetails(json),
                                episodes: XtreamMapper.episodes(json, sourceId: sourceId, seriesId: seriesId))
    }

    /// `get_vod_info`.
    public func vodInfo(vodId: String) async throws -> XtreamVodInfo {
        XtreamMapper.vodInfo(try await getJSON(urls.apiURL(action: "get_vod_info", parameters: [("vod_id", vodId)])))
    }

    /// `get_short_epg` (base64 titles decoded).
    public func shortEpg(streamId: String, limit: Int = 4, serverTimezone: String? = nil) async throws -> [XtreamShortEpgEntry] {
        let json = try await getJSON(urls.apiURL(action: "get_short_epg",
                                                 parameters: [("stream_id", streamId), ("limit", String(limit))]))
        return XtreamMapper.shortEpg(json, serverTimezone: serverTimezone)
    }

    /// `get_simple_data_table` (full archive listing of a channel).
    public func simpleDataTable(streamId: String, serverTimezone: String? = nil) async throws -> [XtreamShortEpgEntry] {
        let json = try await getJSON(urls.apiURL(action: "get_simple_data_table", parameters: [("stream_id", streamId)]))
        return XtreamMapper.shortEpg(json, serverTimezone: serverTimezone)
    }

    // MARK: Refresh

    /// Full refresh: account check, then the small category lists concurrently and the three big lists
    /// **one after another** – each body and its JSON tree is mapped and released before the next download
    /// starts (peak memory on Apple TV HD; no competing downloads on a slow panel).
    /// Throws `SourceError.empty` when there is no live, VOD or series item (CONTRACT §4.4).
    public func fetchCatalog(now: Date = Date()) async throws -> XtreamCatalog {
        let account = try await authenticate(now: now)
        async let liveCats = liveCategories()
        async let vodCats = vodCategories()
        async let seriesCats = seriesCategories()
        let channels = try await liveStreams()
        let movies = try await vodStreams()
        let series = try await series()
        let catalog = try await XtreamCatalog(account: account, liveCategories: liveCats, vodCategories: vodCats,
                                              seriesCategories: seriesCats, channels: channels, movies: movies,
                                              series: series)
        if catalog.channels.isEmpty && catalog.movies.isEmpty && catalog.series.isEmpty { throw SourceError.empty }
        return catalog
    }

    // MARK: Plumbing

    private func list(_ action: String) async throws -> JSONValue {
        let json = try await getJSON(urls.apiURL(action: action), timeouts: .xtreamList)
        switch json {
        case .array, .object, .null: return json
        default: throw SourceError.invalidResponse
        }
    }

    private func getJSON(_ url: URL, timeouts: HTTPTimeouts = .xtreamJSON) async throws -> JSONValue {
        let request = HTTPRequest(url: url, headers: headers, timeouts: timeouts)
        return try await retryPolicy.run(sleeper: sleeper) {
            let response = try await transport.send(request)
            if let error = ErrorClassifier.sourceError(httpStatus: response.statusCode) { throw error }
            guard let json = JSONValue.parse(response.body) else { throw SourceError.invalidResponse }
            return json
        }
    }
}
