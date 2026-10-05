import IPTVCore
import IPTVKit
import Observation
import SwiftUI

/// A resolved "continue watching" entry (title, subtitle, artwork, playable item).
struct ContinueEntry: Identifiable {
    let progress: SyncItem
    let item: PlaybackRequest.Item?
    let title: String
    let subtitle: String?
    /// Detail target ("Info").
    let detail: CatalogItem?
    var id: String { progress.id }
}

/// A movie or a series in poster rows.
enum CatalogItem: Identifiable, Hashable {
    case movie(Movie)
    case series(Series)

    var id: String {
        switch self {
        case .movie(let m): return "m|\(m.id)"
        case .series(let s): return "s|\(s.id)"
        }
    }

    var title: String {
        switch self {
        case .movie(let m): return MediaTags.clean(m.name).title
        case .series(let s): return MediaTags.clean(s.name).title
        }
    }

    var posterUrl: String? {
        switch self {
        case .movie(let m): return m.posterUrl
        case .series(let s): return s.posterUrl
        }
    }

    var year: Int? {
        switch self {
        case .movie(let m): return m.year ?? MediaTags.clean(m.name).year
        case .series(let s): return s.year ?? MediaTags.clean(s.name).year
        }
    }
}

/// Which browse screen (SCREENS §3.2).
enum BrowseKind {
    case home, movies, series

    var contentKind: ContentKind? {
        switch self {
        case .home: return nil
        case .movies: return .movie
        case .series: return .series
        }
    }
}

/// Rows of a browse screen. Rules (SCREENS §3.2): "new" = 20 newest by `added`; Top 10 = rating
/// descending, or the 10 newest when the source has no ratings; one row per category (first 12).
@MainActor
@Observable
final class BrowseModel {
    struct CategoryRow: Identifiable {
        let category: IPTVCore.Category
        let items: [CatalogItem]
        var id: String { category.id }
    }

    let kind: BrowseKind
    private(set) var continueEntries: [ContinueEntry] = []
    private(set) var favorites: [CatalogItem] = []
    private(set) var favoriteChannels: [ChannelRow] = []
    private(set) var newMovies: [CatalogItem] = []
    private(set) var newSeries: [CatalogItem] = []
    private(set) var top10: [CatalogItem] = []
    private(set) var categoryRows: [CategoryRow] = []
    private(set) var liveRows: [ChannelRow] = []
    @ObservationIgnored private let env: AppEnvironment
    @ObservationIgnored private let home: HomeViewModel

    init(env: AppEnvironment, kind: BrowseKind) {
        self.env = env
        self.kind = kind
        home = HomeViewModel(env: env)
    }

    var newItems: [CatalogItem] { kind == .series ? newSeries : newMovies }
    var isEmpty: Bool { continueEntries.isEmpty && newMovies.isEmpty && newSeries.isEmpty && liveRows.isEmpty && favorites.isEmpty }

    /// Hero item: continue watching first, otherwise the newest item.
    var featured: (entry: ContinueEntry?, item: CatalogItem?) {
        if let entry = continueEntries.first { return (entry, entry.detail) }
        switch kind {
        case .series: return (nil, newSeries.first)
        case .movies: return (nil, newMovies.first)
        case .home: return (nil, newMovies.first ?? newSeries.first)
        }
    }

    func reload() {
        home.reload()
        guard let source = env.currentSource else { return }
        let sid = source.id
        continueEntries = home.continueWatching.compactMap { resolve($0) }.filter { entry in
            switch kind {
            case .home: return true
            case .movies: return entry.progress.data.contentKind == .movie
            case .series: return entry.progress.data.contentKind == .episode
            }
        }
        favoriteChannels = kind == .home ? home.favoriteChannels : []
        let favs = FavoritesViewModel(env: env)
        favs.reload()
        switch kind {
        case .home: favorites = favs.movies.map(CatalogItem.movie) + favs.series.map(CatalogItem.series)
        case .movies: favorites = favs.movies.map(CatalogItem.movie)
        case .series: favorites = favs.series.map(CatalogItem.series)
        }
        if kind != .series { newMovies = ((try? env.catalog.movies(sourceId: sid, sort: .added, limit: 20)) ?? []).map(CatalogItem.movie) }
        if kind != .movies { newSeries = ((try? env.catalog.series(sourceId: sid, sort: .added, limit: 20)) ?? []).map(CatalogItem.series) }
        top10 = []
        categoryRows = []
        liveRows = []
        switch kind {
        case .movies:
            let rated = (try? env.catalog.movies(sourceId: sid, sort: .rating, limit: 10)) ?? []
            top10 = rated.contains { ($0.rating ?? 0) > 0 } ? rated.map(CatalogItem.movie) : Array(newMovies.prefix(10))
            categoryRows = ((try? env.catalog.categories(sourceId: sid, kind: .movie)) ?? []).prefix(12).compactMap { c in
                let items = ((try? env.catalog.movies(sourceId: sid, categoryId: c.id, sort: .added, limit: 20)) ?? []).map(CatalogItem.movie)
                return items.isEmpty ? nil : CategoryRow(category: c, items: items)
            }
        case .series:
            let rated = (try? env.catalog.series(sourceId: sid, sort: .rating, limit: 10)) ?? []
            top10 = rated.contains { ($0.rating ?? 0) > 0 } ? rated.map(CatalogItem.series) : Array(newSeries.prefix(10))
            categoryRows = ((try? env.catalog.categories(sourceId: sid, kind: .series)) ?? []).prefix(12).compactMap { c in
                let items = ((try? env.catalog.series(sourceId: sid, categoryId: c.id, sort: .added, limit: 20)) ?? []).map(CatalogItem.series)
                return items.isEmpty ? nil : CategoryRow(category: c, items: items)
            }
        case .home:
            let hidden = HiddenStore.shared
            let channels = ((try? env.catalog.channels(sourceId: sid, limit: 40)) ?? [])
                .filter { !hidden.isHidden(channelId: $0.id, categoryId: $0.categoryId, sourceId: sid) }.prefix(20)
            let map = (try? env.epg.nowNext(sourceId: sid, epgIds: channels.compactMap(\.epgId), at: Date())) ?? [:]
            liveRows = channels.map { ChannelRow(channel: $0, nowNext: $0.epgId.flatMap { map[$0.lowercased()] }) }
        }
    }

    private func resolve(_ progress: SyncItem) -> ContinueEntry? {
        let item = home.item(for: progress)
        switch item {
        case .episode(let e, let seriesTitle)?:
            let series = (try? env.catalog.seriesItem(sourceId: e.sourceId, id: e.seriesId)) ?? nil
            return ContinueEntry(progress: progress, item: item, title: seriesTitle.isEmpty ? e.title : seriesTitle,
                                 subtitle: "\(L10n.t("episode_short", String(e.season), String(e.number))) · \(MediaTags.episodeTitle(e.title, seriesName: seriesTitle))",
                                 detail: series.map(CatalogItem.series))
        case .movie(let m)?:
            return ContinueEntry(progress: progress, item: item, title: MediaTags.clean(m.name).title, subtitle: genreLine(.movie(m)), detail: .movie(m))
        default:
            return nil
        }
    }

    /// "Drama · 2024 · 1 hr 52 min".
    func genreLine(_ item: CatalogItem, durationSec: Int? = nil) -> String {
        let genre: String?
        switch item {
        case .movie(let m): genre = env.categoryName(sourceId: m.sourceId, kind: .movie, id: m.categoryId)
        case .series(let s): genre = env.categoryName(sourceId: s.sourceId, kind: .series, id: s.categoryId)
        }
        return [genre.map(CountryFlag.strippedTitle), item.year.map(String.init), durationSec.flatMap { $0 > 0 ? DurationText.short($0) : nil }]
            .compactMap { $0 }.joined(separator: " · ")
    }
}

enum DurationText {
    static func short(_ seconds: Int) -> String {
        let f = DateComponentsFormatter()
        f.allowedUnits = [.hour, .minute]
        f.unitsStyle = .short
        return f.string(from: TimeInterval(seconds)) ?? L10n.t("minutes_short", String(seconds / 60))
    }
}

struct HomeView: View {
    var body: some View { BrowseView(kind: .home) }
}

/// Home / Movies / Series: hero + Netflix-style rows (SCREENS §3.2).
struct BrowseView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(Router.self) private var router
    let kind: BrowseKind
    @State private var model: BrowseModel?

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: Theme.rowSpacing) {
                if let model {
                    let featured = model.featured
                    if featured.entry != nil || featured.item != nil {
                        BrowseHero(model: model, entry: featured.entry, item: featured.item)
                    } else {
                        Color.clear.frame(height: Theme.isTV ? 0 : 60)
                    }
                    if model.isEmpty {
                        EmptyStateView(icon: kind == .series ? "rectangle.stack" : kind == .movies ? "film" : "sparkles.tv",
                                       text: L10n.t(kind == .series ? "series_empty" : kind == .movies ? "movies_empty" : "home_empty"))
                            .frame(height: 300)
                    }
                    rows(model)
                }
            }
            .padding(.bottom, Theme.isTV ? 80 : 40)
            #if !os(tvOS)
            .background(alignment: .top) {
                GeometryReader { g in
                    let solid = g.frame(in: .global).minY < -120
                    Color.clear
                        .onAppear { router.headerSolid = solid }
                        .onChange(of: solid) { _, v in router.headerSolid = v }
                }
            }
            #endif
        }
        #if os(tvOS)
        .scrollClipDisabled()
        #endif
        .ignoresSafeArea(edges: .top)
        .screenBackground()
        .onAppear {
            if model == nil { model = BrowseModel(env: env, kind: kind) }
            model?.reload()
        }
        .onChange(of: env.libraryVersion) { model?.reload() }
        .onChange(of: env.catalogVersion) { model?.reload() }
        .onChange(of: env.currentSource?.id) { model?.reload() }
    }

    @ViewBuilder
    private func rows(_ model: BrowseModel) -> some View {
        if !model.continueEntries.isEmpty {
            Shelf(title: L10n.t("home_continue"), identifier: "continue") {
                ForEach(model.continueEntries) { entry in
                    Button { if let item = entry.item { router.play(item) } } label: {
                        ContinueCard(title: entry.title, subtitle: entry.subtitle, imageURL: entry.progress.data.posterUrl,
                                     progress: entry.progress.data.fraction)
                    }
                    .buttonStyle(ArtworkButtonStyle())
                    .accessibilityIdentifier("continue_\(entry.id)")
                }
            }
        }
        if !model.favorites.isEmpty {
            posterRow(L10n.t("nav_favorites"), model.favorites, seeAll: .favorites, id: "favorites")
        }
        if !model.favoriteChannels.isEmpty {
            Shelf(title: L10n.t("home_favorite_channels"), seeAll: .favorites, identifier: "favorite_channels") {
                ForEach(model.favoriteChannels) { row in channelButton(row, list: model.favoriteChannels.map(\.channel)) }
            }
        }
        switch kind {
        case .home:
            if !model.newMovies.isEmpty {
                posterRow(L10n.t("home_new_movies"), model.newMovies, seeAll: .grid(kind: .movie, categoryId: nil, title: L10n.t("home_new_movies"), sort: .added),
                          id: "new_movies", markNew: true)
            }
            if !model.newSeries.isEmpty {
                posterRow(L10n.t("home_new_series"), model.newSeries, seeAll: .grid(kind: .series, categoryId: nil, title: L10n.t("home_new_series"), sort: .added),
                          id: "new_series", markNew: true)
            }
            if !model.liveRows.isEmpty {
                Shelf(title: L10n.t("home_live_channels"), identifier: "live") {
                    ForEach(model.liveRows) { row in channelButton(row, list: model.liveRows.map(\.channel)) }
                }
            }
        case .movies, .series:
            let ck: ContentKind = kind == .movies ? .movie : .series
            let newTitle = L10n.t(kind == .movies ? "home_new_movies" : "home_new_series")
            if !model.newItems.isEmpty {
                posterRow(newTitle, model.newItems, seeAll: .grid(kind: ck, categoryId: nil, title: newTitle, sort: .added), id: "new", markNew: true)
            }
            if !model.top10.isEmpty {
                Shelf(title: L10n.t("row_top10"), spacing: Theme.isTV ? 24 : 6, identifier: "top10") {
                    ForEach(Array(model.top10.enumerated()), id: \.element.id) { index, item in
                        NavigationLink(value: item) { RankedPosterCard(rank: index + 1, title: item.title, url: item.posterUrl) }
                            .buttonStyle(ArtworkButtonStyle())
                            .accessibilityIdentifier("top10_\(index + 1)")
                    }
                }
            }
            ForEach(model.categoryRows) { row in
                let title = [CountryFlag.emoji(for: row.category.name), CountryFlag.strippedTitle(row.category.name)].compactMap { $0 }.joined(separator: " ")
                posterRow(title, row.items, seeAll: .grid(kind: ck, categoryId: row.category.id, title: title, sort: .added), id: "category_\(row.category.id)")
            }
        }
    }

    private func posterRow(_ title: String, _ items: [CatalogItem], seeAll: BrowseRoute?, id: String, markNew: Bool = false) -> some View {
        Shelf(title: title, seeAll: seeAll, identifier: id) {
            ForEach(items) { item in
                NavigationLink(value: item) {
                    PosterCard(title: item.title, url: item.posterUrl, subtitle: item.year.map(String.init), isNew: markNew)
                }
                .buttonStyle(ArtworkButtonStyle())
                .accessibilityIdentifier("poster_\(item.id)")
            }
        }
    }

    private func channelButton(_ row: ChannelRow, list: [Channel]) -> some View {
        let isFav = env.isFavorite(sourceId: row.channel.sourceId, kind: .live, itemId: row.channel.id)
        return Button { router.play(.channel(row.channel), channels: list) } label: {
            ChannelCard(row: row, isFavorite: isFav)
        }
        .buttonStyle(ArtworkButtonStyle())
        .accessibilityIdentifier("channel_card_\(row.channel.id)")
        .contextMenu { ChannelMenuItems(channel: row.channel) }
    }
}

/// Favorite / hide-channel / hide-category menu (SCREENS §3.3).
struct ChannelMenuItems: View {
    @Environment(AppEnvironment.self) private var env
    let channel: Channel

    var body: some View {
        let fav = env.isFavorite(sourceId: channel.sourceId, kind: .live, itemId: channel.id)
        Button {
            env.toggleFavorite(sourceId: channel.sourceId, kind: .live, itemId: channel.id, title: channel.name, posterUrl: channel.logoUrl)
        } label: {
            Label(L10n.t(fav ? "action_remove_favorite" : "action_add_favorite"), systemImage: fav ? "star.slash" : "star")
        }
        Button { HiddenStore.shared.hideChannel(channel.id, sourceId: channel.sourceId) } label: {
            Label(L10n.t("channel_hide"), systemImage: "eye.slash")
        }
        if let categoryId = channel.categoryId {
            Button { HiddenStore.shared.hideCategory(categoryId, sourceId: channel.sourceId) } label: {
                Label(L10n.t("category_hide"), systemImage: "eye.slash.circle")
            }
        }
    }
}

/// Hero: featured / continue-watching item with title, genre line and Favorite · ▶ Play · Info.
private struct BrowseHero: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(Router.self) private var router
    #if !os(tvOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif
    let model: BrowseModel
    let entry: ContinueEntry?
    let item: CatalogItem?

    private var title: String { entry?.title ?? item?.title ?? "" }
    private var image: String? { entry?.progress.data.posterUrl ?? item?.posterUrl }
    private var subtitle: String {
        if let entry, entry.progress.data.contentKind == .episode { return entry.subtitle ?? "" }
        guard let item else { return entry?.subtitle ?? "" }
        let dur = entry?.progress.data.durationMs.map { Int($0 / 1000) }
        return model.genreLine(item, durationSec: dur)
    }

    private var favoriteTarget: (kind: ContentKind, id: String, sourceId: String, poster: String?)? {
        switch item {
        case .movie(let m)?: return (.movie, m.id, m.sourceId, m.posterUrl)
        case .series(let s)?: return (.series, s.id, s.sourceId, s.posterUrl)
        default: return nil
        }
    }

    private var playTitle: String {
        let pos = entry?.progress.data.positionMs ?? 0
        return pos > 5000 ? L10n.t("action_resume_at", L10n.clock(Double(pos) / 1000)) : L10n.t("action_play")
    }

    private func play() {
        if let entry, let playable = entry.item { router.play(playable); return }
        switch item {
        case .movie(let m)?: router.play(.movie(m))
        case .series(let s)?:
            let episodes = (try? env.catalog.episodes(sourceId: s.sourceId, seriesId: s.id)) ?? []
            if let first = episodes.first { router.play(.episode(first, seriesTitle: s.name)) } else { openInfo() }
        default: break
        }
    }

    private func openInfo() {
        guard let item else { return }
        #if os(tvOS)
        router.tvPushRequest = item
        #else
        router.path.append(item)
        #endif
    }

    private var isFavorite: Bool {
        guard let t = favoriteTarget else { return false }
        return env.isFavorite(sourceId: t.sourceId, kind: t.kind, itemId: t.id)
    }

    private func toggleFavorite() {
        guard let t = favoriteTarget else { return }
        env.toggleFavorite(sourceId: t.sourceId, kind: t.kind, itemId: t.id, title: title, posterUrl: t.poster)
    }

    var body: some View {
        #if os(tvOS)
        ZStack(alignment: .bottomLeading) {
            HeroBackdrop(url: image, height: 700)
            VStack(alignment: .leading, spacing: 18) {
                Text(entry != nil ? L10n.t("home_continue") : L10n.t("home_featured"))
                    .font(.system(size: 24, weight: .bold)).textCase(.uppercase).foregroundStyle(Theme.primary)
                Text(title).font(Theme.largeTitle).foregroundStyle(.white).lineLimit(2).minimumScaleFactor(0.6)
                if !subtitle.isEmpty { Text(subtitle).font(Theme.body).foregroundStyle(Theme.textSecondary).lineLimit(1) }
                HStack(spacing: 26) {
                    Button(action: play) { Label(playTitle, systemImage: "play.fill") }
                        .buttonStyle(WhitePillButtonStyle())
                        .accessibilityIdentifier("hero_play")
                    if favoriteTarget != nil {
                        Button(action: toggleFavorite) {
                            Label(L10n.t("action_favorite_short"), systemImage: isFavorite ? "star.fill" : "star")
                        }
                        .buttonStyle(SecondaryButtonStyle())
                        .accessibilityIdentifier("hero_favorite")
                    }
                    if item != nil {
                        Button(action: openInfo) { Label(L10n.t("action_info"), systemImage: "info.circle") }
                            .buttonStyle(SecondaryButtonStyle())
                            .accessibilityIdentifier("hero_info")
                    }
                    if kind == .home { TrialChip() }
                }
                .padding(.top, 10)
            }
            .frame(maxWidth: 1150, alignment: .leading)
            .padding(.horizontal, Theme.safeH)
            .padding(.bottom, 30)
        }
        .frame(height: 700)
        .focusSection()
        #else
        ZStack(alignment: .bottom) {
            Group {
                if sizeClass == .compact {
                    RemoteImage(url: image, maxPixel: 1200, placeholder: nil)
                        .overlay(LinearGradient(stops: [.init(color: .black.opacity(0.55), location: 0), .init(color: .clear, location: 0.22),
                                                        .init(color: .clear, location: 0.4), .init(color: .black.opacity(0.92), location: 0.78),
                                                        .init(color: .black, location: 1)],
                                                startPoint: .top, endPoint: .bottom))
                } else {
                    GeometryReader { g in HeroBackdrop(url: image, height: g.size.height) }
                }
            }
            .containerRelativeFrame(.vertical) { h, _ in h * 0.58 }
            .clipped()
            VStack(spacing: 12) {
                Text(title).font(.system(.largeTitle).weight(.heavy)).foregroundStyle(.white)
                    .multilineTextAlignment(.center).lineLimit(2).minimumScaleFactor(0.6)
                    .shadow(color: .black.opacity(0.7), radius: 8)
                    .accessibilityAddTraits(.isHeader)
                if !subtitle.isEmpty {
                    Text(subtitle).font(.footnote.weight(.medium)).foregroundStyle(.white.opacity(0.8)).lineLimit(1)
                }
                HStack(alignment: .center) {
                    labeledIcon(isFavorite ? "star.fill" : "star", L10n.t("action_favorite_short"), action: toggleFavorite)
                        .opacity(favoriteTarget == nil ? 0 : 1)
                        .accessibilityIdentifier("hero_favorite")
                    Spacer()
                    Button(action: play) { Label(playTitle, systemImage: "play.fill").fixedSize().frame(minWidth: 110) }
                        .buttonStyle(WhitePillButtonStyle())
                        .accessibilityIdentifier("hero_play")
                    Spacer()
                    labeledIcon("info.circle", L10n.t("action_info"), action: openInfo)
                        .opacity(item == nil ? 0 : 1)
                        .accessibilityIdentifier("hero_info")
                }
                .padding(.horizontal, 28)
                .padding(.top, 4)
                if kind == .home { homeStatusRow }
            }
            .padding(.horizontal, Theme.safeH)
            .padding(.bottom, 4)
        }
        #endif
    }

    private var kind: BrowseKind { model.kind }

    #if !os(tvOS)
    private func labeledIcon(_ icon: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon).font(.title3)
                Text(label).font(.caption2.weight(.medium)).lineLimit(1)
            }
            .foregroundStyle(.white)
            .frame(minWidth: 64, minHeight: 44)
        }
        .buttonStyle(.plain)
    }

    /// Source picker (several sources) + trial chip under the hero actions.
    @ViewBuilder
    private var homeStatusRow: some View {
        let showPicker = env.sources.count > 1
        HStack(spacing: 10) {
            if showPicker {
                Menu {
                    ForEach(env.sources) { source in Button(source.name) { env.selectSource(source.id) } }
                } label: {
                    Label(env.currentSource?.name ?? L10n.t("source_picker"), systemImage: "antenna.radiowaves.left.and.right")
                        .font(.caption.weight(.medium)).foregroundStyle(Theme.textPrimary)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(Capsule().fill(Theme.surface))
                }
                .accessibilityIdentifier("source_picker")
            }
            TrialChip()
        }
        .padding(.top, 6)
    }
    #endif
}

/// White pill with black label – the primary "▶ Play" of heroes (SCREENS §1).
struct WhitePillButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.isTV ? Theme.headline : .headline)
            .foregroundStyle(.black)
            .lineLimit(1)
            .padding(.horizontal, Theme.isTV ? 44 : 22)
            .padding(.vertical, Theme.isTV ? 18 : 10)
            .background(Capsule().fill(.white))
            .modifier(TVFocusCard(radius: 60))
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}

/// Full-bleed hero artwork for wide layouts: blurred poster fill as backdrop extension, sharp poster
/// on top (fit) and a fade into the black background (SCREENS §3.2 / §3.5).
struct HeroBackdrop: View {
    let url: String?
    let height: CGFloat
    var sharpPoster = true

    var body: some View {
        ZStack {
            RemoteImage(url: url, maxPixel: 300, placeholder: nil, background: Theme.surface)
                .blur(radius: Theme.isTV ? 50 : 30)
                .opacity(0.7)
                .frame(height: height)
                .clipped()
            if sharpPoster {
                HStack {
                    Spacer(minLength: 0)
                    RemoteImage(url: url, maxPixel: 1100, contentMode: .fit, placeholder: nil, background: .clear)
                        .frame(height: height)
                        .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.25),
                                                     .init(color: .black, location: 1)], startPoint: .leading, endPoint: .trailing))
                    Spacer().frame(width: Theme.isTV ? 120 : 40)
                }
            }
            LinearGradient(stops: [.init(color: .black.opacity(0.35), location: 0), .init(color: .clear, location: 0.3),
                                   .init(color: .black.opacity(0.75), location: 0.78), .init(color: .black, location: 1)],
                           startPoint: .top, endPoint: .bottom)
            LinearGradient(colors: [.black.opacity(0.85), .black.opacity(0.2), .clear], startPoint: .leading, endPoint: .trailing)
        }
        .frame(maxWidth: .infinity)
        .frame(height: height)
        .clipped()
        .accessibilityHidden(true)
    }
}

/// Poster grid behind "See all" (category / new) with a sort menu.
struct CatalogGridView: View {
    @Environment(AppEnvironment.self) private var env
    let kind: ContentKind
    let categoryId: String?
    let title: String
    let initialSort: CatalogSort
    @State private var movies: MoviesViewModel?
    @State private var series: SeriesListViewModel?

    private var columns: [GridItem] {
        #if os(tvOS)
        [GridItem(.adaptive(minimum: Theme.posterWidth, maximum: Theme.posterWidth + 20), spacing: 48, alignment: .top)]
        #else
        [GridItem(.adaptive(minimum: 104, maximum: 170), spacing: 12, alignment: .top)]
        #endif
    }

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: Theme.isTV ? 56 : 18) {
                if let movies {
                    ForEach(movies.movies) { m in
                        NavigationLink(value: CatalogItem.movie(m)) {
                            PosterCard(title: m.name, url: m.posterUrl, subtitle: m.year.map(String.init), width: Theme.isTV ? Theme.posterWidth : nil)
                        }
                        .buttonStyle(ArtworkButtonStyle())
                        .accessibilityIdentifier("grid_\(m.id)")
                        .onAppear { movies.loadMoreIfNeeded(m) }
                    }
                }
                if let series {
                    ForEach(series.series) { s in
                        NavigationLink(value: CatalogItem.series(s)) {
                            PosterCard(title: s.name, url: s.posterUrl, subtitle: s.year.map(String.init), width: Theme.isTV ? Theme.posterWidth : nil)
                        }
                        .buttonStyle(ArtworkButtonStyle())
                        .accessibilityIdentifier("grid_\(s.id)")
                        .onAppear { series.loadMoreIfNeeded(s) }
                    }
                }
            }
            .padding(.horizontal, Theme.safeH)
            .padding(.vertical, Theme.isTV ? 30 : 10)
        }
        #if os(tvOS)
        .scrollClipDisabled()
        #endif
        .screenBackground()
        .navigationTitle(title)
        #if !os(tvOS)
        .toolbar(.visible, for: .navigationBar)
        #endif
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Picker(L10n.t("action_sort"), selection: Binding(get: { movies?.sort ?? series?.sort ?? initialSort },
                                                                    set: { movies?.sort = $0; series?.sort = $0 })) {
                        Text(L10n.t("sort_added")).tag(CatalogSort.added)
                        Text(L10n.t("sort_az")).tag(CatalogSort.az)
                        Text(L10n.t("sort_rating")).tag(CatalogSort.rating)
                    }
                } label: { Image(systemName: "arrow.up.arrow.down") }
                    .accessibilityLabel(L10n.t("action_sort"))
                    .accessibilityIdentifier("sort_menu")
            }
        }
        .onAppear {
            guard movies == nil, series == nil else { return }
            if kind == .movie {
                let m = MoviesViewModel(env: env)
                m.categoryId = categoryId
                m.sort = initialSort
                m.reload()
                movies = m
            } else {
                let s = SeriesListViewModel(env: env)
                s.categoryId = categoryId
                s.sort = initialSort
                s.reload()
                series = s
            }
        }
    }
}

#if !os(tvOS)
/// iPhone/iPad header (SCREENS §2): app mark · text tabs with accent underline · search · settings.
/// Transparent over heroes, solid black once scrolled (or on screens without hero).
struct MobileTopBar: View {
    @Environment(Router.self) private var router
    var solid: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "play.tv.fill").font(.title3.weight(.bold)).foregroundStyle(Theme.premiumGradient)
                .accessibilityHidden(true)
            ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 18) {
                    ForEach(AppSection.mobile, id: \.self) { section in
                        let selected = router.section == section
                        Button {
                            router.section = section
                            withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(section, anchor: .center) }
                        } label: {
                            VStack(spacing: 5) {
                                Text(L10n.t(section.titleKey))
                                    .font(.subheadline.weight(selected ? .bold : .semibold))
                                    .foregroundStyle(selected ? Color.white : Color.white.opacity(0.6))
                                    .lineLimit(1)
                                Capsule().fill(selected ? Theme.primary : .clear).frame(height: 3)
                            }
                            .fixedSize(horizontal: true, vertical: false)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("tab_\(section.rawValue)")
                        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
                        .id(section)
                    }
                }
                .padding(.vertical, 6)
                .padding(.trailing, 20)
            }
            // Soft fade at the edges so a clipped tab ("Live T…") reads as "more to scroll",
            // not as a broken label.
            .mask(LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.85),
                                         .init(color: .clear, location: 1)], startPoint: .leading, endPoint: .trailing))
            .onAppear { proxy.scrollTo(router.section, anchor: .center) }
            .onChange(of: router.section) { _, s in withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(s, anchor: .center) } }
            }
            Button { router.path.append(BrowseRoute.search) } label: {
                Image(systemName: "magnifyingglass").font(.body.weight(.semibold)).foregroundStyle(.white).frame(width: 36, height: 36)
            }
            .accessibilityLabel(L10n.t("action_search"))
            .accessibilityIdentifier("open_search")
            Button { router.settingsPresented = true } label: {
                Image(systemName: "gearshape.fill").font(.body.weight(.semibold)).foregroundStyle(.white).frame(width: 36, height: 36)
            }
            .accessibilityLabel(L10n.t("action_settings"))
            .accessibilityIdentifier("open_settings")
        }
        .padding(.horizontal, Theme.safeH)
        .padding(.top, 2)
        .background {
            ZStack {
                LinearGradient(colors: [.black.opacity(0.7), .clear], startPoint: .top, endPoint: .bottom)
                Color.black.opacity(solid ? 1 : 0)
            }
            .ignoresSafeArea(edges: .top)
            .animation(.easeOut(duration: 0.2), value: solid)
        }
    }
}
#endif
