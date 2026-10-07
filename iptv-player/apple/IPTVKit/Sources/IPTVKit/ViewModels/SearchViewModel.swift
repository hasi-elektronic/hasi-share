import Foundation
import IPTVCore
import Observation

/// Last searches of a source, newest first, at most 10 (device-local, SCREENS §3.6).
public final class RecentSearchStore: Sendable {
    public static let limit = 10
    private let kv: any KeyValueStore

    public init(kv: any KeyValueStore) {
        self.kv = kv
    }

    private func key(_ sourceId: String) -> String { "search.recent.\(sourceId)" }

    public func recent(sourceId: String) -> [String] {
        kv.value([String].self, forKey: key(sourceId)) ?? []
    }

    /// Adds `query` on top (case/diacritics-insensitive duplicates removed). Blank queries are ignored.
    @discardableResult
    public func add(_ query: String, sourceId: String) -> [String] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return recent(sourceId: sourceId) }
        let folded = CategoryCountry.fold(trimmed)
        let list = Array(([trimmed] + recent(sourceId: sourceId).filter { CategoryCountry.fold($0) != folded }).prefix(Self.limit))
        kv.setValue(list, forKey: key(sourceId))
        return list
    }

    @discardableResult
    public func remove(_ query: String, sourceId: String) -> [String] {
        let list = recent(sourceId: sourceId).filter { $0 != query }
        kv.setValue(list, forKey: key(sourceId))
        return list
    }

    public func clear(sourceId: String) {
        kv.setValue([String](), forKey: key(sourceId))
    }
}

/// Result filter chips (SCREENS §3.6).
public enum SearchFilter: String, CaseIterable, Sendable, Hashable {
    case all, categories, live, movies, series, programmes
}

/// What a full result list shows ("See all" of a section, a filter chip).
public enum SearchListKind: Hashable, Sendable {
    case categories
    case scope(SearchScope)
    case programmes
}

/// A resolved content result: the hit (how it matched) + the channel / movie / series.
public struct SearchItem: Identifiable, Sendable, Hashable {
    public enum Content: Sendable, Hashable {
        case channel(ChannelRow)
        case movie(Movie)
        case series(Series)
    }

    public var hit: SearchHit
    public var content: Content
    public var id: String { "\(hit.match.rawValue)|\(hit.id)" }

    public init(hit: SearchHit, content: Content) {
        self.hit = hit
        self.content = content
    }
}

/// A TV programme result (SCREENS §3.6 "On TV").
public struct ProgrammeHit: Identifiable, Sendable, Hashable {
    public enum State: Sendable, Hashable {
        /// Running now → plays the channel.
        case live
        /// Later → plays the channel.
        case upcoming
        /// Ended, channel has catch-up → plays the archive.
        case archive
    }

    public var program: EpgProgram
    public var channel: Channel
    public var state: State
    public var id: String { "\(channel.id)|\(Int(program.start.timeIntervalSince1970))|\(program.title)" }

    public init(program: EpgProgram, channel: Channel, state: State) {
        self.program = program
        self.channel = channel
        self.state = state
    }
}

/// Everything the search screen shows for one query.
public struct SearchResults: Sendable, Equatable {
    public var query = ""
    public var categories: [CategoryInfo] = []
    public var channels: [SearchItem] = []
    public var movies: [SearchItem] = []
    public var series: [SearchItem] = []
    /// Cast/director matches (title does not match).
    public var people: [SearchItem] = []
    /// Description matches (`hit.snippet`).
    public var descriptions: [SearchItem] = []
    public var programmes: [ProgrammeHit] = []
    /// "Did you mean": corrected query (only when the query found little and the correction finds something).
    public var correction: String?
    /// Results of `correction`.
    public var similar: [SearchItem] = []

    public init() {}

    public var contentCount: Int { channels.count + movies.count + series.count + people.count + descriptions.count }
    public var isEmpty: Bool { categories.isEmpty && contentCount == 0 && programmes.isEmpty && similar.isEmpty }

    /// Chips that have hits ("All" first).
    public var filters: [SearchFilter] {
        let all = movies + series + people + descriptions
        var out: [SearchFilter] = [.all]
        if !categories.isEmpty { out.append(.categories) }
        if !channels.isEmpty { out.append(.live) }
        if all.contains(where: { $0.hit.kind == .movie }) { out.append(.movies) }
        if all.contains(where: { $0.hit.kind == .series }) { out.append(.series) }
        if !programmes.isEmpty { out.append(.programmes) }
        return out
    }
}

/// The search work, off the main actor: FTS queries, resolving hits to channels/movies/series in batches,
/// EPG programme matching (hidden channels left out, ended programmes only with a playable archive).
public struct SearchEngine: Sendable {
    public let catalog: CatalogRepository
    public let epg: EpgRepository
    public let sourceId: String?
    public var hiddenChannels: Set<String> = []
    public var hiddenLiveCategories: Set<String> = []
    public var hiddenMovieCategories: Set<String> = []
    public var hiddenSeriesCategories: Set<String> = []
    /// Archive playback possible (Xtream timeshift).
    public var canReplay = false
    /// Programme window: from 2 h ago (archive) to 48 h ahead.
    public static let pastWindow: TimeInterval = 2 * 3600
    public static let futureWindow: TimeInterval = 48 * 3600
    /// Below this many content hits the did-you-mean correction is tried.
    public static let fuzzyThreshold = 5
    public static let perSectionLimit = 30

    public init(catalog: CatalogRepository, epg: EpgRepository, sourceId: String?) {
        self.catalog = catalog
        self.epg = epg
        self.sourceId = sourceId
    }

    public func categories(_ text: String, infos: [CategoryInfo], limit: Int = 12) -> [CategoryInfo] {
        CatalogRepository.matchCategories(text, infos: infos, limit: limit) { kind in
            switch kind {
            case .live: return hiddenLiveCategories
            case .movie: return hiddenMovieCategories
            case .series: return hiddenSeriesCategories
            }
        }
    }

    /// The overview of one query: every section capped, programmes, did-you-mean when it found little.
    public func overview(_ text: String, infos: [CategoryInfo], now: Date = Date()) throws -> SearchResults {
        var r = SearchResults()
        r.query = text
        guard !SearchText.tokens(text).isEmpty else { return r }
        r.categories = sourceId == nil ? [] : categories(text, infos: infos)
        let hits = try catalog.search(text, sourceId: sourceId, perKindLimit: Self.perSectionLimit)
        try Task.checkCancellation()
        let items = try resolve(hits, now: now)
        r.channels = items.filter { $0.hit.match == .title && $0.hit.kind == .live }
        r.movies = items.filter { $0.hit.match == .title && $0.hit.kind == .movie }
        r.series = items.filter { $0.hit.match == .title && $0.hit.kind == .series }
        r.people = items.filter { $0.hit.match == .person }
        r.descriptions = items.filter { $0.hit.match == .description }
        r.programmes = try programmes(text, offset: 0, limit: Self.perSectionLimit, now: now).items
        try Task.checkCancellation()
        if r.contentCount < Self.fuzzyThreshold, let corrected = try catalog.correction(for: text, sourceId: sourceId),
           CategoryCountry.fold(corrected) != CategoryCountry.fold(text) {
            let shown = Set(items.map(\.hit.id))
            let similar = try resolve(try catalog.search(corrected, sourceId: sourceId, perKindLimit: 10), now: now)
                .filter { !shown.contains($0.hit.id) }
            var seen = Set<String>()
            r.similar = Array(similar.filter { seen.insert($0.hit.id).inserted }.prefix(Self.perSectionLimit))
            if !r.similar.isEmpty { r.correction = corrected }
        }
        return r
    }

    /// Hits → items, in hit order; channels with now/next, hidden channels left out.
    public func resolve(_ hits: [SearchHit], now: Date = Date()) throws -> [SearchItem] {
        var out: [SearchItem] = []
        for (sourceId, group) in Dictionary(grouping: hits, by: \.sourceId) {
            let channels = try catalog.channels(sourceId: sourceId, ids: group.filter { $0.kind == .live }.map(\.itemId))
            let nowNext = try epg.nowNext(sourceId: sourceId, epgIds: channels.compactMap(\.epgId), at: now)
            let channelById = Dictionary(channels.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            let movies = Dictionary(try catalog.movies(sourceId: sourceId, ids: group.filter { $0.kind == .movie }.map(\.itemId))
                .map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            let series = Dictionary(try catalog.series(sourceId: sourceId, ids: group.filter { $0.kind == .series }.map(\.itemId))
                .map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            for hit in group {
                switch hit.kind {
                case .live:
                    guard let c = channelById[hit.itemId], !isHidden(c) else { continue }
                    out.append(SearchItem(hit: hit, content: .channel(ChannelRow(channel: c, nowNext: c.epgId.flatMap { nowNext[$0.lowercased()] }))))
                case .movie:
                    if let m = movies[hit.itemId] { out.append(SearchItem(hit: hit, content: .movie(m))) }
                case .series:
                    if let s = series[hit.itemId] { out.append(SearchItem(hit: hit, content: .series(s))) }
                case .episode:
                    continue
                }
            }
        }
        let order = Dictionary(hits.enumerated().map { ($0.element.id + $0.element.match.rawValue, $0.offset) }, uniquingKeysWith: { a, _ in a })
        return out.sorted { (order[$0.hit.id + $0.hit.match.rawValue] ?? 0) < (order[$1.hit.id + $1.hit.match.rawValue] ?? 0) }
    }

    func isHidden(_ channel: Channel) -> Bool {
        hiddenChannels.contains(channel.id) || channel.categoryId.map(hiddenLiveCategories.contains) == true
    }

    /// One page of programme results starting at raw row `offset`; `consumed` = rows read (the next page's
    /// offset), `end` = nothing more.
    public func programmes(_ text: String, offset: Int, limit: Int, now: Date = Date()) throws -> (items: [ProgrammeHit], consumed: Int, end: Bool) {
        guard let sourceId else { return ([], 0, true) }
        let fetch = limit * 2
        let rows = try epg.searchProgrammes(text, sourceId: sourceId, now: now, from: now.addingTimeInterval(-Self.pastWindow),
                                            to: now.addingTimeInterval(Self.futureWindow), offset: offset, limit: fetch)
        let channels = try catalog.channels(sourceId: sourceId, epgIds: rows.map(\.channelEpgId))
        var byEpg: [String: Channel] = [:]
        for c in channels where !isHidden(c) {
            guard let id = c.epgId.map(EpgRepository.sqliteLower), byEpg[id] == nil else { continue }
            byEpg[id] = c
        }
        var out: [ProgrammeHit] = []
        var consumed = 0
        for p in rows {
            guard out.count < limit else { break }
            consumed += 1
            guard let channel = byEpg[EpgRepository.sqliteLower(p.channelEpgId)] else { continue }
            let state: ProgrammeHit.State
            if p.isOnAir(at: now) {
                state = .live
            } else if p.start > now {
                state = .upcoming
            } else {
                // Ended: only when the archive can be played (catch-up channel, within its days, Xtream).
                let days = max(channel.catchup.days, 1)
                guard canReplay, channel.catchup.isAvailable, p.start >= now.addingTimeInterval(-Double(days) * 86_400) else { continue }
                state = .archive
            }
            out.append(ProgrammeHit(program: p, channel: channel, state: state))
        }
        return (out, consumed, consumed == rows.count && rows.count < fetch)
    }

    /// One page of a full list.
    public func page(_ kind: SearchListKind, text: String, offset: Int, limit: Int, now: Date = Date()) throws -> [SearchItem] {
        guard case .scope(let scope) = kind else { return [] }
        return try resolve(try catalog.search(text, scope: scope, sourceId: sourceId, offset: offset, limit: limit), now: now)
    }
}

/// Global search (SCREENS §3.6): 250 ms debounce, the work runs off the main actor and a newer query
/// cancels the older one; suggestions while typing, recent searches, filter chips.
@MainActor
@Observable
public final class SearchViewModel {
    public var query = "" { didSet { if query != oldValue { schedule() } } }
    public var filter: SearchFilter = .all
    public private(set) var results = SearchResults()
    /// Completions under the field while typing (≥ 2 characters).
    public private(set) var suggestions: [SearchSuggestion] = []
    /// Last searches of the current source (empty field).
    public private(set) var recent: [String] = []
    public private(set) var isSearching = false
    /// Hidden live channels / categories of a source (Live TV's local hidden lists live in the app layer).
    @ObservationIgnored public var hiddenLiveCategories: (String) -> Set<String> = { _ in [] }
    @ObservationIgnored public var hiddenChannels: (String) -> Set<String> = { _ in [] }
    @ObservationIgnored private let env: AppEnvironment
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var suggestTask: Task<Void, Never>?
    @ObservationIgnored private var lists: [SearchFilter: SearchListModel] = [:]
    @ObservationIgnored var debounce: Duration = .milliseconds(250)

    public init(env: AppEnvironment) {
        self.env = env
        reloadRecent()
    }

    // Compatibility accessors (tests, screenshots).
    public var hits: [SearchHit] { (results.channels + results.movies + results.series + results.people + results.descriptions).map(\.hit) }
    public var categories: [CategoryInfo] { results.categories }
    public var titleHits: [SearchHit] { hits.filter { $0.match == .title } }
    public var personHits: [SearchHit] { hits.filter(\.isPersonMatch) }
    public var isEmpty: Bool { results.isEmpty }

    private var sourceId: String? { env.currentSource?.id }

    /// Snapshot of everything the background work needs.
    public func makeEngine() -> SearchEngine {
        var engine = SearchEngine(catalog: env.catalog, epg: env.epg, sourceId: sourceId)
        if let sourceId {
            engine.hiddenChannels = hiddenChannels(sourceId)
            engine.hiddenLiveCategories = hiddenLiveCategories(sourceId)
            engine.hiddenMovieCategories = env.categoryPrefs.hidden(sourceId: sourceId, kind: .movie)
            engine.hiddenSeriesCategories = env.categoryPrefs.hidden(sourceId: sourceId, kind: .series)
            engine.canReplay = env.currentSource?.type == .xtream   // metadata only (no Keychain read per keystroke)
        }
        return engine
    }

    private func schedule() {
        task?.cancel()
        suggestTask?.cancel()
        let text = query
        guard !SearchText.tokens(text).isEmpty else {
            results = SearchResults()
            suggestions = []
            isSearching = false
            lists = [:]
            filter = .all
            reloadRecent()
            return
        }
        isSearching = true
        let engine = makeEngine()
        suggestTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            let found = await Task.detached(priority: .userInitiated) {
                (try? engine.catalog.completions(text, sourceId: engine.sourceId)) ?? []
            }.value
            guard !Task.isCancelled, let self, self.query == text else { return }
            self.suggestions = found
        }
        run(text, engine: engine, after: debounce)
    }

    private func run(_ text: String, engine: SearchEngine, after delay: Duration) {
        task?.cancel()
        let cached = categoryCache
        let version = env.catalogVersion
        task = Task { [weak self] in
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled else { return }
            let work = Task.detached(priority: .userInitiated) { () -> (SearchResults, [CategoryInfo])? in
                let infos: [CategoryInfo]
                if let cached, cached.key == "\(engine.sourceId ?? "")|\(version)" {
                    infos = cached.infos
                } else if let sourceId = engine.sourceId {
                    infos = [CategoryKind.movie, .series, .live].flatMap { (try? engine.catalog.categoryInfos(sourceId: sourceId, kind: $0)) ?? [] }
                } else {
                    infos = []
                }
                guard let results = try? engine.overview(text, infos: infos) else { return nil }
                return (results, infos)
            }
            let output = await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
            guard !Task.isCancelled, let self, self.query == text, let (results, infos) = output else { return }
            self.categoryCache = ("\(engine.sourceId ?? "")|\(version)", infos)
            self.lists = [:]
            self.results = results
            if !results.filters.contains(self.filter) { self.filter = .all }
            self.isSearching = false
        }
    }

    /// Keyboard "Search": runs at once (no debounce) and remembers the query.
    public func submit() {
        let text = query
        guard !SearchText.tokens(text).isEmpty else { return }
        rememberQuery()
        suggestTask?.cancel()
        suggestions = []
        run(text, engine: makeEngine(), after: .zero)
    }

    /// A suggestion was chosen: it becomes the query and runs.
    public func apply(_ suggestion: SearchSuggestion) {
        query = suggestion.text
        submit()
    }

    /// Hides the suggestions (screen left) until the query changes again.
    public func dismissSuggestions() {
        suggestTask?.cancel()
        suggestions = []
    }

    /// "Did you mean …" was tapped.
    public func applyCorrection() {
        guard let correction = results.correction else { return }
        query = correction
        submit()
    }

    /// A recent search was tapped.
    public func applyRecent(_ text: String) {
        query = text
        submit()
    }

    /// A result was opened: the query goes to the recent searches.
    public func rememberQuery() {
        guard let sourceId, !SearchText.tokens(query).isEmpty else { return }
        recent = env.recentSearches.add(query, sourceId: sourceId)
    }

    public func removeRecent(_ text: String) {
        guard let sourceId else { return }
        recent = env.recentSearches.remove(text, sourceId: sourceId)
    }

    public func clearRecent() {
        guard let sourceId else { return }
        env.recentSearches.clear(sourceId: sourceId)
        recent = []
    }

    public func reloadRecent() {
        recent = sourceId.map { env.recentSearches.recent(sourceId: $0) } ?? []
    }

    /// The full list behind a filter chip (kept while the results stay).
    public func list(for filter: SearchFilter) -> SearchListModel? {
        let kind: SearchListKind
        switch filter {
        case .all: return nil
        case .categories: kind = .categories
        case .live: kind = .scope(.kind(.live))
        case .movies: kind = .scope(.kind(.movie))
        case .series: kind = .scope(.kind(.series))
        case .programmes: kind = .programmes
        }
        if let model = lists[filter], model.query == results.query { return model }
        let model = listModel(kind)
        lists[filter] = model
        return model
    }

    /// A full list model for the current results' query.
    public func listModel(_ kind: SearchListKind) -> SearchListModel {
        SearchListModel(engine: makeEngine(), kind: kind, query: results.query, categoryInfos: categoryCache?.infos ?? [])
    }

    /// Category lists per source, cached until the catalog changes (not three GROUP BY queries per keystroke).
    @ObservationIgnored private var categoryCache: (key: String, infos: [CategoryInfo])?
}

/// A full, paged result list (60 per page; SCREENS §3.6 "See all", filter chips).
@MainActor
@Observable
public final class SearchListModel {
    public let kind: SearchListKind
    public let query: String
    public private(set) var items: [SearchItem] = []
    public private(set) var programmes: [ProgrammeHit] = []
    public private(set) var categories: [CategoryInfo] = []
    public private(set) var reachedEnd = false
    public private(set) var isLoading = false
    public static let pageSize = 60
    @ObservationIgnored private let engine: SearchEngine
    @ObservationIgnored private var offset = 0
    @ObservationIgnored private let categoryInfos: [CategoryInfo]

    public init(engine: SearchEngine, kind: SearchListKind, query: String, categoryInfos: [CategoryInfo] = []) {
        self.engine = engine
        self.kind = kind
        self.query = query
        self.categoryInfos = categoryInfos
    }

    /// Standalone list (pushed "See all" screen): builds its engine like the search screen.
    public convenience init(env: AppEnvironment, kind: SearchListKind, query: String,
                            hiddenChannels: Set<String> = [], hiddenLiveCategories: Set<String> = []) {
        let model = SearchViewModel(env: env)
        model.hiddenChannels = { _ in hiddenChannels }
        model.hiddenLiveCategories = { _ in hiddenLiveCategories }
        self.init(engine: model.makeEngine(), kind: kind, query: query)
    }

    public var isEmpty: Bool { items.isEmpty && programmes.isEmpty && categories.isEmpty }

    /// Loads the next page in the background (no-op while loading or at the end).
    public func loadMore() {
        guard !isLoading, !reachedEnd else { return }
        isLoading = true
        let engine = engine, kind = kind, query = query, offset = offset, infos = categoryInfos
        let limit = Self.pageSize
        Task { [weak self] in
            let page = await Task.detached(priority: .userInitiated) { () -> (items: [SearchItem], programmes: [ProgrammeHit], categories: [CategoryInfo], consumed: Int, end: Bool) in
                switch kind {
                case .categories:
                    var infos = infos
                    if infos.isEmpty, let sourceId = engine.sourceId {
                        infos = [CategoryKind.movie, .series, .live].flatMap { (try? engine.catalog.categoryInfos(sourceId: sourceId, kind: $0)) ?? [] }
                    }
                    return ([], [], engine.categories(query, infos: infos, limit: 1000), 0, true)
                case .programmes:
                    let r = (try? engine.programmes(query, offset: offset, limit: limit)) ?? (items: [], consumed: 0, end: true)
                    return ([], r.items, [], r.consumed, r.end)
                case .scope(let scope):
                    let hits = (try? engine.catalog.search(query, scope: scope, sourceId: engine.sourceId, offset: offset, limit: limit)) ?? []
                    let items = (try? engine.resolve(hits)) ?? []
                    return (items, [], [], hits.count, hits.count < limit)
                }
            }.value
            guard let self else { return }
            self.items += page.items
            self.programmes += page.programmes
            if case .categories = kind { self.categories = page.categories }
            self.offset += page.consumed
            self.reachedEnd = page.end
            self.isLoading = false
        }
    }

    public func loadMoreIfNeeded(_ id: String) {
        let ids = items.isEmpty ? programmes.map(\.id) : items.map(\.id)
        if let index = ids.firstIndex(of: id), index >= ids.count - 12 { loadMore() }
    }
}
