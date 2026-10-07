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

/// Live TV list (docs/SCREENS.md §3.3): category chips with counts, paged channel rows, now/next EPG.
/// With the "All" filter the favorite channels come first (own section), then all channels.
@MainActor
@Observable
public final class LiveTVViewModel {
    public private(set) var categories: [IPTVCore.Category] = []
    public var filter: ChannelFilter = .all { didSet { if filter != oldValue { reload() } } }
    public private(set) var rows: [ChannelRow] = []
    /// "All" filter: favorite channels (manual order), shown as the first section.
    public private(set) var favoriteRows: [ChannelRow] = []
    /// Channels per category id (chips) and in the whole source.
    public private(set) var categoryCounts: [String: Int] = [:]
    public private(set) var allCount = 0
    /// Favorite channels of the current source (the "★ Favorites" chip).
    public private(set) var favoriteCount = 0
    /// Live list only: build the favorites section and the chip counts (the guide shows plain rows).
    @ObservationIgnored public var showsFavoriteSections = false
    /// Chip counts (one GROUP BY over the source); the in-player panel does not show them.
    @ObservationIgnored public var loadsCategoryCounts = true
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
        categories = sourceId.flatMap { try? env.catalog.categories(sourceId: $0, kind: .live) } ?? []
        if showsFavoriteSections, loadsCategoryCounts, let sourceId {
            categoryCounts = (try? env.catalog.channelCountsByCategory(sourceId: sourceId)) ?? [:]
            allCount = (try? env.catalog.channelCount(sourceId: sourceId)) ?? 0
        } else {
            categoryCounts = [:]
            allCount = 0
        }
        rows = []
        totalCount = 0
        if let sourceId, filter != .favorites {
            totalCount = (try? env.catalog.channelCount(sourceId: sourceId, categoryId: categoryId)) ?? 0
            loadMore()
        }
        reloadFavorites()
    }

    /// Re-reads only what favorites change (after a ⭐ toggle): the favorites section of "All" or
    /// the rows of the Favorites filter; the paged rows of "All" stay as they are.
    public func reloadFavorites() {
        favoriteRows = []
        favoriteCount = 0
        guard let sourceId else { return }
        guard filter == .favorites || showsFavoriteSections else { return }
        let favorites = favoriteChannels(sourceId: sourceId)
        favoriteCount = favorites.count
        if filter == .favorites {
            rows = attachEpg(favorites)
            totalCount = rows.count
        } else if filter == .all {
            favoriteRows = attachEpg(favorites)
        }
    }

    /// The current source's favorite channels in the user's order.
    private func favoriteChannels(sourceId: String) -> [Channel] {
        let fingerprint = env.fingerprint(sourceId: sourceId)
        let ids = env.favorites.orderedKeys(kind: .live).compactMap { ContentKey.parse($0) }
            .filter { fingerprint == $0.fingerprint }.map(\.itemId)
        return (try? env.catalog.channels(sourceId: sourceId, ids: ids)) ?? []
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

    /// Loads pages until the channel is among the rows ("Show in TV guide"); stops after `maxRows`.
    /// Returns whether it is loaded.
    @discardableResult
    public func reveal(channelId: String, maxRows: Int = 3_000) -> Bool {
        while !rows.contains(where: { $0.channel.id == channelId }) {
            let before = rows.count
            guard before < maxRows else { return false }
            loadMore()
            if rows.count == before { return false }
        }
        return true
    }

    /// In-player channel panel (SCREENS §3.7): opens on `channel`'s category (else All; a hidden category
    /// → All) and pages until the channel is loaded (≤ `maxRows`, bounded for the ≤ 100 ms open budget).
    /// Returns whether the channel is in the rows / favorites section.
    @discardableResult
    public func open(on channel: Channel?, hiddenCategoryIds: Set<String> = [], maxRows: Int = 600) -> Bool {
        let target: ChannelFilter = channel?.categoryId.flatMap { hiddenCategoryIds.contains($0) ? nil : .category($0) } ?? .all
        if filter == target { reload() } else { filter = target }   // `filter` reloads on change
        guard let channel else { return false }
        return favoriteRows.contains { $0.id == channel.id } || reveal(channelId: channel.id, maxRows: maxRows)
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
    public var categoryId: String? { didSet { if categoryId != oldValue, !configuring { reload() } } }
    /// Items of any of these categories (a country's categories); overrides `categoryId` when set.
    public var categoryIds: [String]? { didSet { if categoryIds != oldValue, !configuring { reload() } } }
    public var sort: CatalogSort = .added { didSet { if sort != oldValue, !configuring { reload() } } }
    @ObservationIgnored private var configuring = false

    /// Sets the filter and sort, then loads once (setting them one by one reloads per property).
    public func configure(categoryId: String?, categoryIds: [String]?, sort: CatalogSort) {
        configuring = true
        self.categoryId = categoryId
        self.categoryIds = categoryIds
        self.sort = sort
        configuring = false
        reload()
    }
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
        let page = (try? categoryIds.map { try env.catalog.movies(sourceId: sourceId, categoryIds: $0, sort: sort, offset: movies.count, limit: 90) }
            ?? env.catalog.movies(sourceId: sourceId, categoryId: categoryId, sort: sort, offset: movies.count, limit: 90)) ?? []
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
    public var categoryId: String? { didSet { if categoryId != oldValue, !configuring { reload() } } }
    /// Items of any of these categories (a country's categories); overrides `categoryId` when set.
    public var categoryIds: [String]? { didSet { if categoryIds != oldValue, !configuring { reload() } } }
    public var sort: CatalogSort = .added { didSet { if sort != oldValue, !configuring { reload() } } }
    @ObservationIgnored private var configuring = false

    /// Sets the filter and sort, then loads once (setting them one by one reloads per property).
    public func configure(categoryId: String?, categoryIds: [String]?, sort: CatalogSort) {
        configuring = true
        self.categoryId = categoryId
        self.categoryIds = categoryIds
        self.sort = sort
        configuring = false
        reload()
    }
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
        let page = (try? categoryIds.map { try env.catalog.series(sourceId: sourceId, categoryIds: $0, sort: sort, offset: series.count, limit: 90) }
            ?? env.catalog.series(sourceId: sourceId, categoryId: categoryId, sort: sort, offset: series.count, limit: 90)) ?? []
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
    /// Content keys of the shown items (same order) – the subset `move` reorders.
    @ObservationIgnored private var shownKeys: [ContentKind: [String]] = [:]
    @ObservationIgnored private let env: AppEnvironment

    public init(env: AppEnvironment) {
        self.env = env
    }

    public func reload() {
        shownKeys = [:]
        guard let source = env.currentSource, let fingerprint = env.fingerprint(sourceId: source.id) else {
            channels = []; movies = []; series = []; return
        }
        func ids(_ kind: ContentKind) -> [String] {
            env.favorites.orderedKeys(kind: kind).compactMap { ContentKey.parse($0) }
                .filter { fingerprint == $0.fingerprint }.map(\.itemId)
        }
        func key(_ kind: ContentKind, _ id: String) -> String { ContentKey.make(fingerprint: fingerprint, kind: kind, itemId: id) }
        channels = (try? env.catalog.channels(sourceId: source.id, ids: ids(.live))) ?? []
        movies = ids(.movie).compactMap { (try? env.catalog.movie(sourceId: source.id, id: $0)) ?? nil }
        series = ids(.series).compactMap { (try? env.catalog.seriesItem(sourceId: source.id, id: $0)) ?? nil }
        shownKeys = [.live: channels.map { key(.live, $0.id) }, .movie: movies.map { key(.movie, $0.id) },
                     .series: series.map { key(.series, $0.id) }]
    }

    /// Reorders the current tab (SwiftUI `onMove` offsets) and saves the device-local order.
    public func move(from: IndexSet, to: Int) {
        let kind = tab
        guard let keys = shownKeys[kind] else { return }
        switch kind {
        case .live: channels.move(from: from, to: to)
        case .movie: movies.move(from: from, to: to)
        default: series.move(from: from, to: to)
        }
        var reordered = keys
        reordered.move(from: from, to: to)
        shownKeys[kind] = reordered
        env.favorites.move(kind: kind, from: from, to: to, within: keys)
    }
}

extension Array {
    /// SwiftUI `move(fromOffsets:toOffset:)` semantics (IPTVKit does not import SwiftUI).
    mutating func move(from offsets: IndexSet, to destination: Int) {
        let moving = offsets.filter { indices.contains($0) }.map { self[$0] }
        let removedBefore = offsets.filter { $0 < destination && indices.contains($0) }.count
        for index in offsets.sorted(by: >) where indices.contains(index) { remove(at: index) }
        insert(contentsOf: moving, at: Swift.min(Swift.max(destination - removedBefore, 0), count))
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
