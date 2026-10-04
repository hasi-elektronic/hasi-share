import IPTVCore
import IPTVKit
import SwiftUI

extension View {
    /// Registers detail destinations for catalog values pushed with `NavigationLink(value:)`.
    func catalogDestinations() -> some View {
        navigationDestination(for: Movie.self) { MovieDetailView(movie: $0) }
            .navigationDestination(for: Series.self) { SeriesDetailView(series: $0) }
    }
}

private var gridColumns: [GridItem] {
    [GridItem(.adaptive(minimum: Theme.isTV ? Theme.posterWidth : 110, maximum: Theme.isTV ? Theme.posterWidth + 20 : 160),
              spacing: Theme.isTV ? 48 : 12, alignment: .top)]
}

private func sortItems() -> [(id: CatalogSort, title: String)] {
    [(CatalogSort.added, L10n.t("sort_added")), (.az, L10n.t("sort_az")), (.rating, L10n.t("sort_rating"))]
}

/// Movies grid with categories and sort (SCREENS §3.4).
struct MoviesView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var model: MoviesViewModel?

    var body: some View {
        Group {
            if let model {
                VStack(spacing: 0) {
                    ChipBar(items: [(String?.none, L10n.t("all"))] + model.categories.map { (Optional($0.id), $0.name) },
                            selection: Binding(get: { model.categoryId }, set: { model.categoryId = $0 }))
                    ChipBar(items: sortItems(), selection: Binding(get: { model.sort }, set: { model.sort = $0 }))
                    if model.movies.isEmpty {
                        EmptyStateView(icon: "film", text: L10n.t("movies_empty"))
                    } else {
                        ScrollView {
                            LazyVGrid(columns: gridColumns, spacing: Theme.isTV ? 56 : 16) {
                                ForEach(model.movies) { movie in
                                    NavigationLink(value: movie) { PosterCard(title: movie.name, url: movie.posterUrl, width: Theme.isTV ? Theme.posterWidth : 110) }
                                        .buttonStyle(CardButtonStyle())
                                        .onAppear { model.loadMoreIfNeeded(movie) }
                                }
                            }
                            .padding(.horizontal, Theme.safeH)
                            .padding(.vertical, Theme.isTV ? 30 : 8)
                        }
                    }
                }
            } else {
                ProgressView()
            }
        }
        .screenBackground()
        .navigationTitle(L10n.t("nav_movies"))
        .onAppear {
            if model == nil {
                let m = MoviesViewModel(env: env)
                model = m
                m.reload()
            }
        }
        .onChange(of: env.catalogVersion) { model?.reload() }
    }
}

/// Movie detail: backdrop, metadata, ★ Play / Resume, play from start, favorite.
struct MovieDetailView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(Router.self) private var router
    let movie: Movie
    @State private var info: XtreamVodInfo?
    @State private var progress: SyncItem?

    var body: some View {
        ScrollView {
            HStack(alignment: .top, spacing: Theme.isTV ? 60 : 16) {
                RemoteImage(url: movie.posterUrl, maxPixel: 700, placeholder: "film")
                    .frame(width: Theme.isTV ? 360 : 130, height: Theme.isTV ? 540 : 195)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.posterRadius))
                VStack(alignment: .leading, spacing: Theme.isTV ? 20 : 10) {
                    Text(movie.name).font(Theme.title).foregroundStyle(Theme.textPrimary)
                    HStack(spacing: 12) {
                        if let year = movie.year ?? info?.year { Text(String(year)) }
                        if let rating = movie.rating ?? info?.rating { Label(String(format: "%.1f", rating), systemImage: "star.fill") }
                        if let d = info?.durationSec { Text(L10n.t("minutes_short", String(d / 60))) }
                    }
                    .font(Theme.caption).foregroundStyle(Theme.textSecondary)
                    if let plot = info?.plot ?? movie.plot { Text(plot).font(Theme.body).foregroundStyle(Theme.textSecondary) }
                    actions.padding(.top, 8)
                }
            }
            .padding(.horizontal, Theme.safeH)
            .padding(.vertical, Theme.safeV)
        }
        .background(
            RemoteImage(url: movie.posterUrl, maxPixel: 200).blur(radius: 40).opacity(0.25).ignoresSafeArea()
        )
        .screenBackground()
        .task {
            progress = env.contentKey(sourceId: movie.sourceId, kind: .movie, itemId: movie.id).flatMap { try? env.library.progress(contentKey: $0) }
            if movie.url == nil { info = await MoviesViewModel(env: env).details(for: movie) }
        }
    }

    private var actions: some View {
        let fav = env.isFavorite(sourceId: movie.sourceId, kind: .movie, itemId: movie.id)
        let resumeMs = progress?.data.positionMs ?? 0
        let canResume = resumeMs > 5000 && !WatchHistory.isCompleted(positionMs: resumeMs, durationMs: progress?.data.durationMs ?? 0)
        return HStack(spacing: 16) {
            Button(canResume ? L10n.t("action_resume_at", L10n.clock(Double(resumeMs) / 1000)) : L10n.t("action_play")) {
                router.play(.movie(movie))
            }
            .buttonStyle(PrimaryButtonStyle())
            if canResume {
                Button(L10n.t("action_play_from_start")) { router.play(.movie(movie), fromStart: true) }.buttonStyle(SecondaryButtonStyle())
            }
            Button {
                env.toggleFavorite(sourceId: movie.sourceId, kind: .movie, itemId: movie.id, title: movie.name, posterUrl: movie.posterUrl)
            } label: {
                Image(systemName: fav ? "star.fill" : "star")
            }
            .buttonStyle(SecondaryButtonStyle())
            .accessibilityLabel(L10n.t(fav ? "action_remove_favorite" : "action_add_favorite"))
        }
    }
}

/// Series grid.
struct SeriesView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var model: SeriesListViewModel?

    var body: some View {
        Group {
            if let model {
                VStack(spacing: 0) {
                    ChipBar(items: [(String?.none, L10n.t("all"))] + model.categories.map { (Optional($0.id), $0.name) },
                            selection: Binding(get: { model.categoryId }, set: { model.categoryId = $0 }))
                    if model.series.isEmpty {
                        EmptyStateView(icon: "rectangle.stack", text: L10n.t("series_empty"))
                    } else {
                        ScrollView {
                            LazyVGrid(columns: gridColumns, spacing: Theme.isTV ? 56 : 16) {
                                ForEach(model.series) { item in
                                    NavigationLink(value: item) { PosterCard(title: item.name, url: item.posterUrl, width: Theme.isTV ? Theme.posterWidth : 110) }
                                        .buttonStyle(CardButtonStyle())
                                        .onAppear { model.loadMoreIfNeeded(item) }
                                }
                            }
                            .padding(.horizontal, Theme.safeH)
                            .padding(.vertical, Theme.isTV ? 30 : 8)
                        }
                    }
                }
            } else {
                ProgressView()
            }
        }
        .screenBackground()
        .navigationTitle(L10n.t("nav_series"))
        .onAppear {
            if model == nil {
                let m = SeriesListViewModel(env: env)
                model = m
                m.reload()
            }
        }
        .onChange(of: env.catalogVersion) { model?.reload() }
    }
}

/// Series detail with season selector and episode list (SCREENS §3.5).
struct SeriesDetailView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(Router.self) private var router
    let series: Series
    @State private var model: SeriesDetailViewModel?

    var body: some View {
        ScrollView {
            if let model {
                VStack(alignment: .leading, spacing: Theme.isTV ? 24 : 12) {
                    HStack(alignment: .top, spacing: Theme.isTV ? 48 : 14) {
                        RemoteImage(url: series.posterUrl, maxPixel: 600, placeholder: "rectangle.stack")
                            .frame(width: Theme.isTV ? 300 : 110, height: Theme.isTV ? 450 : 165)
                            .clipShape(RoundedRectangle(cornerRadius: Theme.posterRadius))
                        VStack(alignment: .leading, spacing: 10) {
                            Text(series.name).font(Theme.title).foregroundStyle(Theme.textPrimary)
                            if let plot = model.plot { Text(plot).font(Theme.body).foregroundStyle(Theme.textSecondary).lineLimit(6) }
                            if let next = model.continueEpisode {
                                Button(L10n.t("continue_episode", L10n.t("episode_short", String(next.season), String(next.number)))) {
                                    router.play(.episode(next, seriesTitle: series.name))
                                }
                                .buttonStyle(PrimaryButtonStyle())
                            }
                            Button {
                                env.toggleFavorite(sourceId: series.sourceId, kind: .series, itemId: series.id, title: series.name, posterUrl: series.posterUrl)
                            } label: {
                                let fav = env.isFavorite(sourceId: series.sourceId, kind: .series, itemId: series.id)
                                Label(L10n.t(fav ? "action_remove_favorite" : "action_add_favorite"), systemImage: fav ? "star.fill" : "star")
                            }
                            .buttonStyle(SecondaryButtonStyle())
                        }
                    }
                    .padding(.horizontal, Theme.safeH)
                    if model.isLoading { ProgressView().padding() }
                    if !model.seasons.isEmpty {
                        ChipBar(items: model.seasons.map { ($0, L10n.t("season_n", String($0))) },
                                selection: Binding(get: { model.season }, set: { model.season = $0 }))
                    }
                    LazyVStack(spacing: Theme.isTV ? 12 : 4) {
                        ForEach(model.seasonEpisodes) { episode in
                            Button { router.play(.episode(episode, seriesTitle: series.name)) } label: {
                                episodeRow(episode, model.progress(of: episode))
                            }
                            .buttonStyle(CardButtonStyle())
                        }
                    }
                    .padding(.horizontal, Theme.safeH)
                }
                .padding(.vertical, Theme.safeV)
            } else {
                ProgressView()
            }
        }
        .screenBackground()
        .task {
            let m = SeriesDetailViewModel(env: env, series: series)
            model = m
            await m.load()
        }
    }

    private func episodeRow(_ e: Episode, _ progress: SyncItem?) -> some View {
        HStack(spacing: 14) {
            Text(L10n.t("episode_short", String(e.season), String(e.number))).font(Theme.caption.monospacedDigit())
                .foregroundStyle(Theme.textSecondary).frame(width: Theme.isTV ? 110 : 64, alignment: .leading)
            VStack(alignment: .leading, spacing: 4) {
                Text(e.title).font(Theme.body).foregroundStyle(Theme.textPrimary).lineLimit(1)
                if let fraction = progress?.data.fraction { ProgressBar(value: fraction).frame(height: 3) }
            }
            Spacer()
            if let d = e.durationSec { Text(L10n.t("minutes_short", String(d / 60))).font(Theme.caption).foregroundStyle(Theme.textSecondary) }
            if let p = progress, let pos = p.data.positionMs, let dur = p.data.durationMs, WatchHistory.isCompleted(positionMs: pos, durationMs: dur) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.success).accessibilityLabel(L10n.t("watched"))
            }
        }
        .padding(Theme.isTV ? 20 : 10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.surface))
    }
}

/// Favorites with tabs (SCREENS §3.6).
struct FavoritesView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(Router.self) private var router
    @State private var model: FavoritesViewModel?

    var body: some View {
        VStack(spacing: 0) {
            if let model {
                ChipBar(items: [(ContentKind.live, L10n.t("favorites_channels")), (.movie, L10n.t("favorites_movies")), (.series, L10n.t("favorites_series"))],
                        selection: Binding(get: { model.tab }, set: { model.tab = $0 }))
                content(model)
                if let synced = env.lastSyncedAt, env.account.isSignedIn {
                    LText("last_synced", synced.formatted(date: .omitted, time: .shortened)).font(Theme.caption).foregroundStyle(Theme.textSecondary).padding()
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .screenBackground()
        .navigationTitle(L10n.t("nav_favorites"))
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
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(model.channels) { channel in
                            Button { router.play(.channel(channel), channels: model.channels) } label: {
                                ChannelRowView(row: ChannelRow(channel: channel, nowNext: nil), isFavorite: true, timeFormatter: env.timeFormatter)
                            }
                            .buttonStyle(CardButtonStyle())
                            .contextMenu {
                                Button(L10n.t("action_remove"), role: .destructive) {
                                    env.toggleFavorite(sourceId: channel.sourceId, kind: .live, itemId: channel.id, title: channel.name, posterUrl: channel.logoUrl)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, Theme.safeH)
                }
            }
        case .movie:
            if model.movies.isEmpty { EmptyStateView(icon: "star", text: L10n.t("favorites_empty")) } else {
                ScrollView {
                    LazyVGrid(columns: gridColumns, spacing: 16) {
                        ForEach(model.movies) { m in
                            NavigationLink(value: m) { PosterCard(title: m.name, url: m.posterUrl, width: Theme.isTV ? Theme.posterWidth : 110) }.buttonStyle(CardButtonStyle())
                        }
                    }
                    .padding(.horizontal, Theme.safeH)
                }
            }
        default:
            if model.series.isEmpty { EmptyStateView(icon: "star", text: L10n.t("favorites_empty")) } else {
                ScrollView {
                    LazyVGrid(columns: gridColumns, spacing: 16) {
                        ForEach(model.series) { s in
                            NavigationLink(value: s) { PosterCard(title: s.name, url: s.posterUrl, width: Theme.isTV ? Theme.posterWidth : 110) }.buttonStyle(CardButtonStyle())
                        }
                    }
                    .padding(.horizontal, Theme.safeH)
                }
            }
        }
    }
}

/// Search over channels, movies and series (FTS5, 250 ms debounce).
struct SearchView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(Router.self) private var router
    @State private var model: SearchViewModel?

    var body: some View {
        Group {
            if let model {
                List {
                    if model.hits.isEmpty, !model.query.isEmpty {
                        LText("search_no_results", model.query).foregroundStyle(Theme.textSecondary).listRowBackground(Theme.bg)
                    }
                    ForEach(model.hits) { hit in
                        row(hit, model).listRowBackground(Theme.bg)
                    }
                }
                .listStyle(.plain)
                .hiddenListBackground()
                .searchable(text: Binding(get: { model.query }, set: { model.query = $0 }), prompt: L10n.t("search_hint"))
            }
        }
        .screenBackground()
        .navigationTitle(L10n.t("nav_search"))
        .onAppear { if model == nil { model = SearchViewModel(env: env) } }
    }

    @ViewBuilder
    private func row(_ hit: SearchHit, _ model: SearchViewModel) -> some View {
        let icon = hit.kind == .live ? "tv" : hit.kind == .movie ? "film" : "rectangle.stack"
        switch hit.kind {
        case .live:
            Button { if let c = model.channel(hit) { router.play(.channel(c)) } } label: { Label(hit.title, systemImage: icon) }
        case .movie:
            if let m = model.movie(hit) { NavigationLink(value: m) { Label(hit.title, systemImage: icon) } }
        default:
            if let s = model.series(hit) { NavigationLink(value: s) { Label(hit.title, systemImage: icon) } }
        }
    }
}
