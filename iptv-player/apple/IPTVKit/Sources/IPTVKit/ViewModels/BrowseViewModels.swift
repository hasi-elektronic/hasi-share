import Foundation
import IPTVCore
import Observation

/// A channel row with its EPG now/next.
public struct ChannelRow: Identifiable, Hashable, Sendable {
    public var channel: Channel
    public var nowNext: NowNext?
    public var id: String { channel.id }
    public init(channel: Channel, nowNext: NowNext?) {
        self.channel = channel
        self.nowNext = nowNext
    }
}

/// Category filter of the live list.
public enum ChannelFilter: Hashable, Sendable {
    case all
    case favorites
    case category(String)
}

/// Live TV list (docs/SCREENS.md §3.3): category chips, paged channel rows, now/next EPG.
@MainActor
@Observable
public final class LiveTVViewModel {
    public private(set) var categories: [IPTVCore.Category] = []
    public var filter: ChannelFilter = .all { didSet { if filter != oldValue { reload() } } }
    public private(set) var rows: [ChannelRow] = []
    public private(set) var totalCount = 0
    public private(set) var isLoading = false
    @ObservationIgnored private let env: AppEnvironment
    @ObservationIgnored private var sourceId: String?
    public static let pageSize = 120

    public init(env: AppEnvironment) {
        self.env = env
    }

    public func reload() {
        sourceId = env.currentSource?.id
        guard let sourceId else {
            categories = []
            rows = []
            totalCount = 0
            return
        }
        categories = (try? env.catalog.categories(sourceId: sourceId, kind: .live)) ?? []
        rows = []
        totalCount = 0
        switch filter {
        case .favorites:
            let fingerprint = env.fingerprint(sourceId: sourceId)
            let ids = env.favorites.orderedKeys(kind: .live).compactMap { ContentKey.parse($0) }
                .filter { fingerprint == $0.fingerprint }.map(\.itemId)
            let channels = (try? env.catalog.channels(sourceId: sourceId, ids: ids)) ?? []
            totalCount = channels.count
            rows = attachEpg(channels)
        case .all, .category:
            totalCount = (try? env.catalog.channelCount(sourceId: sourceId, categoryId: categoryId)) ?? 0
            loadMore()
        }
    }

    private var categoryId: String? {
        if case .category(let id) = filter { return id }
        return nil
    }

    /// Next page (called when the last rows appear).
    public func loadMore() {
        guard let sourceId, filter != .favorites, rows.count < totalCount, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        let page = (try? env.catalog.channels(sourceId: sourceId, categoryId: categoryId, offset: rows.count, limit: Self.pageSize)) ?? []
        rows += attachEpg(page)
    }

    public func loadMoreIfNeeded(current row: ChannelRow) {
        if let index = rows.firstIndex(of: row), index >= rows.count - 20 { loadMore() }
    }

    private func attachEpg(_ channels: [Channel]) -> [ChannelRow] {
        guard let sourceId else { return [] }
        let ids = channels.compactMap(\.epgId)
        let map = (try? env.epg.nowNext(sourceId: sourceId, epgIds: ids, at: Date())) ?? [:]
        return channels.map { ChannelRow(channel: $0, nowNext: $0.epgId.flatMap { map[$0.lowercased()] }) }
    }

    /// All loaded channels (zapping list).
    public var channels: [Channel] { rows.map(\.channel) }

    public func programs(for channel: Channel, hours: Double = 24) -> [EpgProgram] {
        guard let epgId = channel.epgId else { return [] }
        let now = Date()
        return (try? env.epg.programs(sourceId: channel.sourceId, epgId: epgId,
                                      in: DateInterval(start: now.addingTimeInterval(-3 * 3600), duration: hours * 3600))) ?? []
    }
}

/// Movies grid (docs/SCREENS.md §3.4).
@MainActor
@Observable
public final class MoviesViewModel {
    public private(set) var categories: [IPTVCore.Category] = []
    public var categoryId: String? { didSet { if categoryId != oldValue { reload() } } }
    public var sort: CatalogSort = .added { didSet { if sort != oldValue { reload() } } }
    public private(set) var movies: [Movie] = []
    public private(set) var reachedEnd = false
    @ObservationIgnored private let env: AppEnvironment
    @ObservationIgnored private var sourceId: String?

    public init(env: AppEnvironment) {
        self.env = env
    }

    public func reload() {
        sourceId = env.currentSource?.id
        categories = sourceId.flatMap { try? env.catalog.categories(sourceId: $0, kind: .movie) } ?? []
        movies = []
        reachedEnd = false
        loadMore()
    }

    public func loadMore() {
        guard let sourceId, !reachedEnd else { return }
        let page = (try? env.catalog.movies(sourceId: sourceId, categoryId: categoryId, sort: sort, offset: movies.count, limit: 90)) ?? []
        reachedEnd = page.count < 90
        movies += page
    }

    public func loadMoreIfNeeded(_ movie: Movie) {
        if let index = movies.firstIndex(of: movie), index >= movies.count - 18 { loadMore() }
    }

    /// Xtream VOD details (plot, duration…), lazily.
    public func details(for movie: Movie) async -> XtreamVodInfo? {
        guard case .xtream(let secrets)? = env.secrets(for: movie.sourceId),
              let client = XtreamClient(sourceId: movie.sourceId, secrets: secrets) else { return nil }
        return try? await client.vodInfo(vodId: movie.id)
    }
}

/// Series grid.
@MainActor
@Observable
public final class SeriesListViewModel {
    public private(set) var categories: [IPTVCore.Category] = []
    public var categoryId: String? { didSet { if categoryId != oldValue { reload() } } }
    public var sort: CatalogSort = .added { didSet { if sort != oldValue { reload() } } }
    public private(set) var series: [Series] = []
    public private(set) var reachedEnd = false
    @ObservationIgnored private let env: AppEnvironment
    @ObservationIgnored private var sourceId: String?

    public init(env: AppEnvironment) {
        self.env = env
    }

    public func reload() {
        sourceId = env.currentSource?.id
        categories = sourceId.flatMap { try? env.catalog.categories(sourceId: $0, kind: .series) } ?? []
        series = []
        reachedEnd = false
        loadMore()
    }

    public func loadMore() {
        guard let sourceId, !reachedEnd else { return }
        let page = (try? env.catalog.series(sourceId: sourceId, categoryId: categoryId, sort: sort, offset: series.count, limit: 90)) ?? []
        reachedEnd = page.count < 90
        series += page
    }

    public func loadMoreIfNeeded(_ item: Series) {
        if let index = series.firstIndex(of: item), index >= series.count - 18 { loadMore() }
    }
}

/// Series detail with seasons and episodes (docs/SCREENS.md §3.5).
@MainActor
@Observable
public final class SeriesDetailViewModel {
    public let series: Series
    public private(set) var episodes: [Episode] = []
    public var season: Int = 1
    public private(set) var isLoading = false
    public private(set) var plot: String?
    @ObservationIgnored private let env: AppEnvironment

    public init(env: AppEnvironment, series: Series) {
        self.env = env
        self.series = series
        self.plot = series.plot
    }

    public var seasons: [Int] { Array(Set(episodes.map(\.season))).sorted() }
    public var seasonEpisodes: [Episode] { episodes.filter { $0.season == season } }

    public func load() async {
        episodes = (try? env.catalog.episodes(sourceId: series.sourceId, seriesId: series.id)) ?? []
        if episodes.isEmpty, case .xtream(let secrets)? = env.secrets(for: series.sourceId),
           let client = XtreamClient(sourceId: series.sourceId, secrets: secrets) {
            isLoading = true
            defer { isLoading = false }
            if let info = try? await client.seriesInfo(seriesId: series.id) {
                episodes = info.episodes.sorted { ($0.season, $0.number) < ($1.season, $1.number) }
                if plot == nil { plot = info.details.plot }
                try? env.catalog.replaceEpisodes(sourceId: series.sourceId, seriesId: series.id, episodes: episodes)
            }
        }
        if let next = continueEpisode { season = next.season } else if let first = seasons.first { season = first }
    }

    public func progress(of episode: Episode) -> SyncItem? {
        env.contentKey(sourceId: episode.sourceId, kind: .episode, itemId: episode.id).flatMap { try? env.library.progress(contentKey: $0) }
    }

    /// "Continue S02E05": last watched episode, or the next one if it was completed.
    public var continueEpisode: Episode? {
        var latest: (Episode, SyncItem)?
        for e in episodes {
            if let p = progress(of: e), latest == nil || p.updatedAt > latest!.1.updatedAt { latest = (e, p) }
        }
        guard let (episode, item) = latest else { return nil }
        if let pos = item.data.positionMs, let dur = item.data.durationMs, WatchHistory.isCompleted(positionMs: pos, durationMs: dur),
           let index = episodes.firstIndex(of: episode), index + 1 < episodes.count {
            return episodes[index + 1]
        }
        return episode
    }
}

/// Home rows (docs/SCREENS.md §3.2).
@MainActor
@Observable
public final class HomeViewModel {
    public private(set) var continueWatching: [SyncItem] = []
    public private(set) var recentChannels: [ChannelRow] = []
    public private(set) var favoriteChannels: [ChannelRow] = []
    public private(set) var newMovies: [Movie] = []
    public private(set) var newSeries: [Series] = []
    @ObservationIgnored private let env: AppEnvironment

    public init(env: AppEnvironment) {
        self.env = env
    }

    public var isEmpty: Bool {
        continueWatching.isEmpty && recentChannels.isEmpty && favoriteChannels.isEmpty && newMovies.isEmpty && newSeries.isEmpty
    }

    public func reload() {
        guard let source = env.currentSource, let fingerprint = env.fingerprint(sourceId: source.id) else {
            continueWatching = []; recentChannels = []; favoriteChannels = []; newMovies = []; newSeries = []
            return
        }
        let progress = (try? env.library.progressItems()) ?? []
        let mine = progress.filter { $0.contentKey.hasPrefix(fingerprint + ":") }
        continueWatching = WatchHistory.continueWatching(mine, limit: 20)
        let recentIds = WatchHistory.recentlyWatched(mine, kind: .live, limit: 20).compactMap { ContentKey.parse($0.contentKey)?.itemId }
        let favIds = env.favorites.orderedKeys(kind: .live).filter { $0.hasPrefix(fingerprint + ":") }
            .compactMap { ContentKey.parse($0)?.itemId }
        recentChannels = rows((try? env.catalog.channels(sourceId: source.id, ids: recentIds)) ?? [], sourceId: source.id)
        favoriteChannels = rows((try? env.catalog.channels(sourceId: source.id, ids: favIds)) ?? [], sourceId: source.id)
        newMovies = (try? env.catalog.movies(sourceId: source.id, sort: .added, limit: 20)) ?? []
        newSeries = (try? env.catalog.series(sourceId: source.id, sort: .added, limit: 20)) ?? []
    }

    private func rows(_ channels: [Channel], sourceId: String) -> [ChannelRow] {
        let map = (try? env.epg.nowNext(sourceId: sourceId, epgIds: channels.compactMap(\.epgId), at: Date())) ?? [:]
        return channels.map { ChannelRow(channel: $0, nowNext: $0.epgId.flatMap { map[$0.lowercased()] }) }
    }

    /// Resolves a continue-watching item to a playback item.
    public func item(for progress: SyncItem) -> PlaybackRequest.Item? {
        guard let parsed = ContentKey.parse(progress.contentKey), let source = env.currentSource else { return nil }
        switch parsed.kind {
        case .movie:
            return (try? env.catalog.movie(sourceId: source.id, id: parsed.itemId)).flatMap { $0.map(PlaybackRequest.Item.movie) }
        case .episode:
            let all = (try? env.database.db.queryFirst("SELECT series_id FROM episodes WHERE source_id = ? AND id = ?",
                                                       [.text(source.id), .text(parsed.itemId)]) { $0.string(0) }) ?? nil
            guard let seriesId = all, let episode = (try? env.catalog.episodes(sourceId: source.id, seriesId: seriesId))?.first(where: { $0.id == parsed.itemId }) else { return nil }
            let title = (try? env.catalog.seriesItem(sourceId: source.id, id: seriesId))??.name ?? ""
            return .episode(episode, seriesTitle: title)
        default:
            return nil
        }
    }
}

/// Favorites (docs/SCREENS.md §3.6).
@MainActor
@Observable
public final class FavoritesViewModel {
    public var tab: ContentKind = .live { didSet { reload() } }
    public private(set) var channels: [Channel] = []
    public private(set) var movies: [Movie] = []
    public private(set) var series: [Series] = []
    @ObservationIgnored private let env: AppEnvironment

    public init(env: AppEnvironment) {
        self.env = env
    }

    public func reload() {
        guard let source = env.currentSource else { channels = []; movies = []; series = []; return }
        let fingerprint = env.fingerprint(sourceId: source.id)
        func ids(_ kind: ContentKind) -> [String] {
            env.favorites.orderedKeys(kind: kind).compactMap { ContentKey.parse($0) }
                .filter { fingerprint == $0.fingerprint }.map(\.itemId)
        }
        channels = (try? env.catalog.channels(sourceId: source.id, ids: ids(.live))) ?? []
        movies = ids(.movie).compactMap { (try? env.catalog.movie(sourceId: source.id, id: $0)) ?? nil }
        series = ids(.series).compactMap { (try? env.catalog.seriesItem(sourceId: source.id, id: $0)) ?? nil }
    }
}

/// Search with 250 ms debounce over FTS5.
@MainActor
@Observable
public final class SearchViewModel {
    public var query = "" { didSet { schedule() } }
    public private(set) var hits: [SearchHit] = []
    @ObservationIgnored private let env: AppEnvironment
    @ObservationIgnored private var task: Task<Void, Never>?

    public init(env: AppEnvironment) {
        self.env = env
    }

    private func schedule() {
        task?.cancel()
        let text = query
        task = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, let self else { return }
            hits = (try? env.catalog.search(text, sourceId: env.currentSource?.id)) ?? []
        }
    }

    public func channel(_ hit: SearchHit) -> Channel? { (try? env.catalog.channel(sourceId: hit.sourceId, id: hit.itemId)) ?? nil }
    public func movie(_ hit: SearchHit) -> Movie? { (try? env.catalog.movie(sourceId: hit.sourceId, id: hit.itemId)) ?? nil }
    public func series(_ hit: SearchHit) -> Series? { (try? env.catalog.seriesItem(sourceId: hit.sourceId, id: hit.itemId)) ?? nil }
}

/// EPG grid (time axis, 30 min = fixed width, "now" line).
@MainActor
@Observable
public final class EpgGridViewModel {
    public private(set) var rows: [(channel: Channel, programs: [EpgProgram])] = []
    public let start: Date
    public let hours: Double
    @ObservationIgnored private let env: AppEnvironment

    public init(env: AppEnvironment, hours: Double = 6) {
        self.env = env
        self.hours = hours
        let now = Date()
        start = Date(timeIntervalSince1970: (now.timeIntervalSince1970 / 1800).rounded(.down) * 1800 - 1800)
    }

    public func load(channels: [Channel]) {
        let interval = DateInterval(start: start, duration: hours * 3600)
        rows = channels.prefix(200).map { c in
            (c, c.epgId.flatMap { try? env.epg.programs(sourceId: c.sourceId, epgId: $0, in: interval) } ?? [])
        }
    }
}
