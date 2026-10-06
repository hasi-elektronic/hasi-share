import IPTVCore
import IPTVKit
import SwiftUI

extension View {
    /// Registers detail destinations for catalog values and browse routes (search, favorites, grids).
    func catalogDestinations() -> some View {
        navigationDestination(for: Movie.self) { MovieDetailView(movie: $0) }
            .navigationDestination(for: Series.self) { SeriesDetailView(series: $0) }
            .navigationDestination(for: CatalogItem.self) { item in
                switch item {
                case .movie(let m): MovieDetailView(movie: m)
                case .series(let s): SeriesDetailView(series: s)
                }
            }
            .navigationDestination(for: BrowseRoute.self) { route in
                switch route {
                case .search: SearchView()
                case .favorites:
                    #if os(tvOS)
                    FavoritesView()
                    #else
                    FavoritesView().navigationTitle(L10n.t("nav_favorites")).toolbar(.visible, for: .navigationBar)
                    #endif
                case let .grid(kind, categoryId, title, sort): CatalogGridView(kind: kind, categoryId: categoryId, title: title, initialSort: sort)
                }
            }
    }
}

private var gridColumns: [GridItem] {
    #if os(tvOS)
    [GridItem(.adaptive(minimum: Theme.posterWidth, maximum: Theme.posterWidth + 20), spacing: 48, alignment: .top)]
    #else
    [GridItem(.adaptive(minimum: 104, maximum: 170), spacing: 12, alignment: .top)]
    #endif
}

/// Poster width inside the grid: fixed on TV, cell-filling on iPhone/iPad.
private var gridPosterWidth: CGFloat? { Theme.isTV ? Theme.posterWidth : nil }

/// Movies tab: hero + rows (SCREENS §3.2).
struct MoviesView: View {
    var body: some View { BrowseView(kind: .movies) }
}

/// Series tab: hero + rows (SCREENS §3.2).
struct SeriesView: View {
    var body: some View { BrowseView(kind: .series) }
}

// MARK: - Detail

/// "★ 7.8 · 2024 · 1 hr 52 min" line.
private struct DetailMetaRow: View {
    var rating: Double?
    var year: Int?
    var durationSec: Int?
    var extra: String?

    var body: some View {
        HStack(spacing: Theme.isTV ? 20 : 10) {
            if let rating, rating > 0 {
                HStack(spacing: 4) {
                    Image(systemName: "star.fill").foregroundStyle(Theme.warning)
                    Text(String(format: "%.1f", rating)).fontWeight(.bold)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(L10n.t("rating_value", String(format: "%.1f", rating)))
            }
            if let year { Text(String(year)) }
            if let extra { Text(extra) }
            if let durationSec, durationSec > 0 { Text(DurationText.short(durationSec)) }
        }
        .font(Theme.isTV ? Theme.body : .subheadline)
        .foregroundStyle(Theme.textSecondary)
    }
}

/// Format/quality pill ("MKV · HD").
private struct FormatPill: View {
    let text: String

    var body: some View {
        Text(text).font((Theme.isTV ? Theme.caption : .caption).weight(.semibold)).foregroundStyle(Theme.textSecondary)
            .padding(.horizontal, Theme.isTV ? 22 : 12).frame(height: Theme.isTV ? 70 : 36)
            .overlay(Capsule().stroke(Theme.textSecondary.opacity(0.6), lineWidth: 1))
            .accessibilityIdentifier("format_pill")
    }
}

/// IPTVX-style detail layout (SCREENS §3.5): full-width hero with centered round play button and
/// close button, large title, meta, description, genre line; action row; extra content below.
private struct DetailScaffold<Actions: View, Below: View>: View {
    @Environment(\.dismiss) private var dismiss
    #if !os(tvOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif
    let title: String
    let imageURL: String?
    let meta: DetailMetaRow
    let genres: String?
    let plot: String?
    let onPlay: () -> Void
    @ViewBuilder var actions: () -> Actions
    @ViewBuilder var below: () -> Below

    var body: some View {
        #if os(tvOS)
        ScrollView {
            VStack(alignment: .leading, spacing: 40) {
                ZStack(alignment: .bottomLeading) {
                    HeroBackdrop(url: imageURL, height: 1000)
                    VStack(alignment: .leading, spacing: 20) {
                        Text(title).font(Theme.largeTitle).foregroundStyle(.white).lineLimit(2).minimumScaleFactor(0.6)
                        meta
                        if let plot {
                            Text(plot).font(Theme.body).foregroundStyle(Theme.textPrimary.opacity(0.85)).lineLimit(4)
                                .frame(maxWidth: 1000, alignment: .leading)
                        }
                        if let genres { Text(L10n.t("genres_value", genres)).font(Theme.caption).foregroundStyle(Theme.textSecondary) }
                        actions().padding(.top, 14)
                    }
                    .frame(maxWidth: 1150, alignment: .leading)
                    .padding(.horizontal, Theme.safeH)
                    .padding(.bottom, 70)
                    .focusSection()
                }
                below()
            }
            .padding(.bottom, 80)
        }
        .scrollClipDisabled()
        .ignoresSafeArea()
        .screenBackground()
        #else
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                ZStack {
                    Group {
                        if sizeClass == .compact {
                            RemoteImage(url: imageURL, maxPixel: 1200, placeholder: "film")
                                .overlay(LinearGradient(stops: [.init(color: .clear, location: 0.55), .init(color: .black, location: 1)],
                                                        startPoint: .top, endPoint: .bottom))
                        } else {
                            GeometryReader { g in HeroBackdrop(url: imageURL, height: g.size.height) }
                        }
                    }
                    .containerRelativeFrame(.vertical) { h, _ in h * 0.5 }
                    .clipped()
                    Button(action: onPlay) { PlayCircle(size: 72) }
                        .buttonStyle(.plain)
                        .accessibilityLabel(L10n.t("action_play"))
                        .accessibilityIdentifier("detail_hero_play")
                }
                VStack(alignment: .leading, spacing: 12) {
                    Text(title).font(.system(.largeTitle).weight(.heavy)).foregroundStyle(.white)
                        .lineLimit(3).minimumScaleFactor(0.6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityAddTraits(.isHeader)
                    meta
                    actions()
                    if let plot {
                        Text(plot).font(.body).foregroundStyle(Theme.textPrimary.opacity(0.9))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if let genres {
                        Text(L10n.t("genres_value", genres)).font(.footnote).foregroundStyle(Theme.textSecondary)
                    }
                    below().padding(.top, 8)
                }
                .padding(.horizontal, 20)
                .frame(maxWidth: 760)
                .frame(maxWidth: .infinity)
            }
            .padding(.bottom, 40)
        }
        .ignoresSafeArea(edges: .top)
        .screenBackground()
        .toolbar(.hidden, for: .navigationBar)
        .overlay(alignment: .topTrailing) {
            Button { dismiss() } label: { Image(systemName: "xmark") }
                .buttonStyle(RoundIconButtonStyle(size: 38))
                .accessibilityLabel(L10n.t("action_close"))
                .accessibilityIdentifier("detail_close")
                .padding(.trailing, 16)
                .padding(.top, 4)
        }
        #endif
    }
}

/// Action row: white pill (play / resume) + round icon buttons + format pill.
private struct DetailActions<Round: View>: View {
    let primaryTitle: String
    let primaryAction: () -> Void
    var format: String?
    @ViewBuilder var round: () -> Round

    var body: some View {
        HStack(spacing: Theme.isTV ? 28 : 10) {
            Button(action: primaryAction) { Label(primaryTitle, systemImage: "play.fill").fixedSize() }
                .buttonStyle(WhitePillButtonStyle())
                .accessibilityIdentifier("detail_play")
            round()
            #if !os(tvOS)
            Spacer(minLength: 0)
            #endif
            if let format { FormatPill(text: format) }
        }
    }
}

/// Movie detail: hero, ★ Play / Resume (01:12:30), favorite, restart (SCREENS §3.5).
struct MovieDetailView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(Router.self) private var router
    let movie: Movie
    @State private var info: XtreamVodInfo?
    @State private var progress: SyncItem?

    var body: some View {
        // Same rule as the request the Play button builds (AppEnvironment.request → ResumePolicy).
        let resumeMs = ResumePolicy.startPositionMs(positionMs: progress?.data.positionMs, durationMs: progress?.data.durationMs) ?? 0
        let canResume = resumeMs > 0
        let fav = env.isFavorite(sourceId: movie.sourceId, kind: .movie, itemId: movie.id)
        let duration = info?.durationSec ?? progress?.data.durationMs.map { Int($0 / 1000) }
        let clean = MediaTags.clean(movie.name)
        DetailScaffold(title: clean.title, imageURL: movie.posterUrl,
                       meta: DetailMetaRow(rating: movie.rating ?? info?.rating, year: movie.year ?? info?.year ?? clean.year, durationSec: duration),
                       genres: env.categoryName(sourceId: movie.sourceId, kind: .movie, id: movie.categoryId).map(CountryFlag.strippedTitle),
                       plot: info?.plot ?? movie.plot, onPlay: { router.play(.movie(movie)) }) {
            DetailActions(primaryTitle: canResume ? L10n.t("action_resume_at", L10n.clock(Double(resumeMs) / 1000)) : L10n.t("action_play"),
                          primaryAction: { router.play(.movie(movie)) },
                          format: MediaTags.format(container: movie.containerExt, name: movie.name)) {
                Button {
                    env.toggleFavorite(sourceId: movie.sourceId, kind: .movie, itemId: movie.id, title: movie.name, posterUrl: movie.posterUrl)
                } label: { Image(systemName: fav ? "star.fill" : "star") }
                    .buttonStyle(RoundIconButtonStyle(size: Theme.isTV ? 84 : 38))
                    .accessibilityLabel(L10n.t(fav ? "action_remove_favorite" : "action_add_favorite"))
                    .accessibilityIdentifier("detail_favorite")
                if canResume {
                    Button { router.play(.movie(movie), fromStart: true) } label: { Image(systemName: "arrow.counterclockwise") }
                        .buttonStyle(RoundIconButtonStyle(size: Theme.isTV ? 84 : 38))
                        .accessibilityLabel(L10n.t("action_play_from_start"))
                        .accessibilityIdentifier("detail_restart")
                }
            }
        } below: {
            EmptyView()
        }
        .task {
            progress = env.contentKey(sourceId: movie.sourceId, kind: .movie, itemId: movie.id).flatMap { try? env.library.progress(contentKey: $0) }
            if movie.url == nil { info = await MoviesViewModel(env: env).details(for: movie) }
        }
        .onChange(of: env.libraryVersion) {
            progress = env.contentKey(sourceId: movie.sourceId, kind: .movie, itemId: movie.id).flatMap { try? env.library.progress(contentKey: $0) }
        }
    }
}

/// Season tabs: text with accent underline (SCREENS §3.5).
private struct SeasonTabs: View {
    let seasons: [Int]
    @Binding var selection: Int

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Theme.isTV ? 40 : 22) {
                ForEach(seasons, id: \.self) { season in
                    let selected = selection == season
                    Button { selection = season } label: {
                        VStack(spacing: Theme.isTV ? 8 : 6) {
                            Text(L10n.t("season_n", String(season)))
                                .font(Theme.isTV ? Theme.body.weight(selected ? .bold : .medium) : .subheadline.weight(selected ? .bold : .medium))
                                .foregroundStyle(selected ? Color.white : Theme.textSecondary)
                            Capsule().fill(selected ? Theme.primary : .clear).frame(height: 3)
                        }
                        .fixedSize()
                        .padding(.horizontal, Theme.isTV ? 12 : 0).padding(.vertical, Theme.isTV ? 8 : 0)
                    }
                    #if os(tvOS)
                    .buttonStyle(CardButtonStyle(radius: 12, scale: 1.1))
                    #else
                    .buttonStyle(.plain)
                    #endif
                    .accessibilityIdentifier("season_\(season)")
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
            .padding(.horizontal, Theme.isTV ? Theme.safeH : 0)
            .padding(.vertical, Theme.isTV ? 14 : 2)
        }
        #if os(tvOS)
        .scrollClipDisabled()
        .focusSection()
        #endif
    }
}

/// Series detail: hero, ★ "Continue S02E05", season tabs, episode list with progress / ✓ (SCREENS §3.5).
struct SeriesDetailView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(Router.self) private var router
    let series: Series
    @State private var model: SeriesDetailViewModel?

    var body: some View {
        let fav = env.isFavorite(sourceId: series.sourceId, kind: .series, itemId: series.id)
        let next = model?.continueEpisode ?? model?.episodes.first
        let primaryTitle: String = {
            guard let next else { return L10n.t("action_play") }
            let code = L10n.t("episode_short", String(next.season), String(next.number))
            return model?.continueEpisode != nil ? L10n.t("continue_episode", code) : "\(L10n.t("action_play")) \(code)"
        }()
        let play = { if let next { router.play(.episode(next, seriesTitle: series.name)) } }
        let clean = MediaTags.clean(series.name)
        DetailScaffold(title: clean.title, imageURL: series.posterUrl,
                       meta: DetailMetaRow(rating: series.rating, year: series.year ?? clean.year, durationSec: nil,
                                           extra: model.flatMap { $0.seasons.isEmpty ? nil : L10n.t("seasons_value", String($0.seasons.count)) }),
                       genres: env.categoryName(sourceId: series.sourceId, kind: .series, id: series.categoryId).map(CountryFlag.strippedTitle),
                       plot: model?.plot ?? series.plot, onPlay: play) {
            DetailActions(primaryTitle: primaryTitle, primaryAction: play,
                          format: next.flatMap { MediaTags.format(container: $0.containerExt, name: series.name) }) {
                Button {
                    env.toggleFavorite(sourceId: series.sourceId, kind: .series, itemId: series.id, title: series.name, posterUrl: series.posterUrl)
                } label: { Image(systemName: fav ? "star.fill" : "star") }
                    .buttonStyle(RoundIconButtonStyle(size: Theme.isTV ? 84 : 38))
                    .accessibilityLabel(L10n.t(fav ? "action_remove_favorite" : "action_add_favorite"))
                    .accessibilityIdentifier("detail_favorite")
            }
        } below: {
            if let model { episodes(model) }
        }
        .task {
            let m = SeriesDetailViewModel(env: env, series: series)
            model = m
            await m.load()
        }
    }

    @ViewBuilder
    private func episodes(_ model: SeriesDetailViewModel) -> some View {
        VStack(alignment: .leading, spacing: Theme.isTV ? 10 : 12) {
            if model.isLoading { ProgressView() }
            if !model.seasons.isEmpty {
                SeasonTabs(seasons: model.seasons, selection: Binding(get: { model.season }, set: { model.season = $0 }))
            }
            #if os(tvOS)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: Theme.shelfSpacing) {
                    ForEach(model.seasonEpisodes) { episode in
                        let p = model.progress(of: episode)
                        Button { router.play(.episode(episode, seriesTitle: series.name)) } label: {
                            ContinueCard(title: "\(episode.number). \(episodeTitle(episode))", subtitle: episodeSubtitle(episode, p),
                                         imageURL: episode.posterUrl ?? series.posterUrl, progress: p?.data.fraction, width: 440)
                        }
                        .buttonStyle(ArtworkButtonStyle())
                        .accessibilityIdentifier("episode_\(episode.id)")
                    }
                }
                .padding(.horizontal, Theme.safeH)
                .padding(.vertical, 28)
            }
            .scrollClipDisabled()
            .focusSection()
            #else
            LazyVStack(spacing: 14) {
                ForEach(model.seasonEpisodes) { episode in
                    let p = model.progress(of: episode)
                    Button { router.play(.episode(episode, seriesTitle: series.name)) } label: {
                        episodeRow(episode, p)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("episode_\(episode.id)")
                }
            }
            #endif
        }
    }

    private func episodeTitle(_ e: Episode) -> String { MediaTags.episodeTitle(e.title, seriesName: series.name) }

    private func isWatched(_ p: SyncItem?) -> Bool {
        guard let p, let pos = p.data.positionMs, let dur = p.data.durationMs else { return false }
        return WatchHistory.isCompleted(positionMs: pos, durationMs: dur)
    }

    private func episodeSubtitle(_ e: Episode, _ p: SyncItem?) -> String {
        var parts = [L10n.t("episode_short", String(e.season), String(e.number))]
        if let d = e.durationSec, d > 0 { parts.append(L10n.t("minutes_short", String(d / 60))) }
        if isWatched(p) { parts.append(L10n.t("watched")) }
        return parts.joined(separator: " · ")
    }

    #if !os(tvOS)
    private func episodeRow(_ e: Episode, _ progress: SyncItem?) -> some View {
        HStack(alignment: .center, spacing: 14) {
            ZStack {
                RemoteImage(url: e.posterUrl ?? series.posterUrl, maxPixel: 300, placeholder: "play.rectangle")
                    .frame(width: 140, height: 79)
                PlayCircle(size: 30)
            }
            .frame(width: 140, height: 79)
            .overlay(alignment: .bottom) {
                if let fraction = progress?.data.fraction, fraction > 0 {
                    ProgressBar(value: fraction).frame(height: 3).padding(.horizontal, 6).padding(.bottom, 5)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text("\(e.number). \(episodeTitle(e))").font(.subheadline.weight(.semibold)).foregroundStyle(Theme.textPrimary).lineLimit(2)
                Text(episodeSubtitle(e, progress)).font(.caption).foregroundStyle(Theme.textSecondary).lineLimit(1)
                if let plot = e.plot { Text(plot).font(.caption).foregroundStyle(Theme.textSecondary).lineLimit(2) }
            }
            Spacer(minLength: 0)
            if isWatched(progress) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.success).accessibilityLabel(L10n.t("watched"))
            }
        }
        .contentShape(Rectangle())
    }
    #endif
}

// MARK: - Favorites

/// Favorites: segmented Channels · Movies · Series (SCREENS §3.6). Channels use the EPG list.
struct FavoritesView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(Router.self) private var router
    @State private var model: FavoritesViewModel?

    var body: some View {
        VStack(spacing: 0) {
            if let model {
                Picker(L10n.t("nav_favorites"), selection: Binding(get: { model.tab }, set: { model.tab = $0 })) {
                    LText("favorites_channels").tag(ContentKind.live)
                    LText("favorites_movies").tag(ContentKind.movie)
                    LText("favorites_series").tag(ContentKind.series)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, Theme.safeH)
                .padding(.vertical, Theme.isTV ? 24 : 10)
                .frame(maxWidth: Theme.isTV ? 900 : .infinity)
                .accessibilityIdentifier("favorites_segment")
                content(model)
                if let synced = env.lastSyncedAt, env.account.isSignedIn {
                    LText("last_synced", L10n.date(synced, date: .omitted, time: .shortened)).font(Theme.caption).foregroundStyle(Theme.textSecondary).padding()
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .screenBackground()
        .onAppear {
            if model == nil { model = FavoritesViewModel(env: env) }
            model?.reload()
        }
        .onChange(of: env.libraryVersion) { model?.reload() }
    }

    @ViewBuilder
    private func content(_ model: FavoritesViewModel) -> some View {
        switch model.tab {
        case .live:
            if model.channels.isEmpty { EmptyStateView(icon: "star", text: L10n.t("favorites_empty")) } else {
                EpgListView(rows: model.channels.map { ChannelRow(channel: $0, nowNext: nil) }, zapList: model.channels)
            }
        case .movie:
            if model.movies.isEmpty { EmptyStateView(icon: "star", text: L10n.t("favorites_empty")) } else {
                grid {
                    ForEach(model.movies) { m in
                        NavigationLink(value: m) { PosterCard(title: m.name, url: m.posterUrl, subtitle: m.year.map(String.init), width: gridPosterWidth) }
                            .buttonStyle(ArtworkButtonStyle())
                    }
                }
            }
        default:
            if model.series.isEmpty { EmptyStateView(icon: "star", text: L10n.t("favorites_empty")) } else {
                grid {
                    ForEach(model.series) { s in
                        NavigationLink(value: s) { PosterCard(title: s.name, url: s.posterUrl, subtitle: s.year.map(String.init), width: gridPosterWidth) }
                            .buttonStyle(ArtworkButtonStyle())
                    }
                }
            }
        }
    }

    private func grid<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        ScrollView {
            LazyVGrid(columns: gridColumns, spacing: Theme.isTV ? 56 : 18) { content() }
                .padding(.horizontal, Theme.safeH)
                .padding(.vertical, Theme.isTV ? 30 : 10)
        }
        #if os(tvOS)
        .scrollClipDisabled()
        #endif
    }
}

// MARK: - Search

/// Global search over channels, movies and series (FTS5, 250 ms debounce); results as rows.
struct SearchView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(Router.self) private var router
    @State private var model: SearchViewModel?
    @State private var channels: [ChannelRow] = []
    @State private var movies: [Movie] = []
    @State private var series: [Series] = []
    @State private var searchPresented = true

    var body: some View {
        ZStack(alignment: .top) {
            if let model {
                ScrollView {
                    VStack(alignment: .leading, spacing: Theme.rowSpacing) {
                        if model.hits.isEmpty, !model.query.isEmpty {
                            LText("search_no_results", model.query).font(Theme.body).foregroundStyle(Theme.textSecondary)
                                .padding(.horizontal, Theme.safeH).padding(.top, 20)
                        }
                        if !channels.isEmpty {
                            Shelf(title: L10n.t("favorites_channels")) {
                                ForEach(channels) { row in
                                    Button { router.play(.channel(row.channel), channels: channels.map(\.channel)) } label: { ChannelCard(row: row) }
                                        .buttonStyle(ArtworkButtonStyle())
                                        .accessibilityIdentifier("search_channel_\(row.channel.id)")
                                }
                            }
                        }
                        if !movies.isEmpty {
                            Shelf(title: L10n.t("favorites_movies")) {
                                ForEach(movies) { m in
                                    NavigationLink(value: m) { PosterCard(title: m.name, url: m.posterUrl, subtitle: m.year.map(String.init)) }
                                        .buttonStyle(ArtworkButtonStyle())
                                        .accessibilityIdentifier("search_movie_\(m.id)")
                                }
                            }
                        }
                        if !series.isEmpty {
                            Shelf(title: L10n.t("favorites_series")) {
                                ForEach(series) { s in
                                    NavigationLink(value: s) { PosterCard(title: s.name, url: s.posterUrl, subtitle: s.year.map(String.init)) }
                                        .buttonStyle(ArtworkButtonStyle())
                                        .accessibilityIdentifier("search_series_\(s.id)")
                                }
                            }
                        }
                    }
                    .padding(.vertical, Theme.isTV ? 30 : 12)
                }
                #if os(tvOS)
                .scrollClipDisabled()
                .searchable(text: Binding(get: { model.query }, set: { model.query = $0 }), prompt: L10n.t("search_hint"))
                #else
                .searchable(text: Binding(get: { model.query }, set: { model.query = $0 }), isPresented: $searchPresented,
                            placement: .navigationBarDrawer(displayMode: .always), prompt: L10n.t("search_hint"))
                #endif
                .onChange(of: model.hits) { _, hits in resolve(hits, model) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .screenBackground()
        .navigationTitle(L10n.t("nav_search"))
        #if !os(tvOS)
        .toolbar(.visible, for: .navigationBar)
        #endif
        .onAppear { if model == nil { model = SearchViewModel(env: env) } }
    }

    private func resolve(_ hits: [SearchHit], _ model: SearchViewModel) {
        let liveHits = hits.filter { $0.kind == .live }
        let found = liveHits.compactMap { model.channel($0) }
        var rows = found.map { ChannelRow(channel: $0, nowNext: nil) }
        if let sourceId = found.first?.sourceId,
           let map = try? env.epg.nowNext(sourceId: sourceId, epgIds: found.compactMap(\.epgId), at: Date()) {
            rows = found.map { ChannelRow(channel: $0, nowNext: $0.epgId.flatMap { map[$0.lowercased()] }) }
        }
        channels = rows
        movies = hits.filter { $0.kind == .movie }.compactMap { model.movie($0) }
        series = hits.filter { $0.kind == .series }.compactMap { model.series($0) }
    }
}
