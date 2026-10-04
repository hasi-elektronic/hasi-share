import IPTVCore
import IPTVKit
import SwiftUI

/// Home rows: continue watching, recent channels, favorite channels, new movies/series (SCREENS §3.2).
struct HomeView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(Router.self) private var router
    @State private var model: HomeViewModel?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.isTV ? 40 : 24) {
                topBar
                if let model {
                    if model.isEmpty {
                        EmptyStateView(icon: "sparkles.tv", text: L10n.t("home_empty")).frame(height: 300)
                    }
                    if !model.continueWatching.isEmpty {
                        Shelf(title: L10n.t("home_continue")) {
                            ForEach(model.continueWatching) { item in
                                Button {
                                    if let playable = model.item(for: item) { router.play(playable) }
                                } label: {
                                    PosterCard(title: item.data.title, url: item.data.posterUrl, progress: item.data.fraction)
                                }
                                .buttonStyle(CardButtonStyle())
                            }
                        }
                    }
                    channelShelf("home_recent_channels", model.recentChannels)
                    channelShelf("home_favorite_channels", model.favoriteChannels)
                    if !model.newMovies.isEmpty {
                        Shelf(title: L10n.t("home_new_movies")) {
                            ForEach(model.newMovies) { movie in
                                NavigationLink(value: movie) { PosterCard(title: movie.name, url: movie.posterUrl) }
                                    .buttonStyle(CardButtonStyle())
                            }
                        }
                    }
                    if !model.newSeries.isEmpty {
                        Shelf(title: L10n.t("home_new_series")) {
                            ForEach(model.newSeries) { series in
                                NavigationLink(value: series) { PosterCard(title: series.name, url: series.posterUrl) }
                                    .buttonStyle(CardButtonStyle())
                            }
                        }
                    }
                }
            }
            .padding(.vertical, Theme.safeV)
        }
        .screenBackground()
        .onAppear {
            if model == nil { model = HomeViewModel(env: env) }
            model?.reload()
        }
        .onChange(of: env.libraryVersion) { model?.reload() }
        .onChange(of: env.catalogVersion) { model?.reload() }
    }

    private var topBar: some View {
        HStack(spacing: 16) {
            if env.sources.count > 1 {
                Menu {
                    ForEach(env.sources) { source in
                        Button(source.name) { env.selectSource(source.id) }
                    }
                } label: {
                    Label(env.currentSource?.name ?? L10n.t("source_picker"), systemImage: "antenna.radiowaves.left.and.right")
                        .font(Theme.body)
                }
            } else if let source = env.currentSource {
                Label(source.name, systemImage: "antenna.radiowaves.left.and.right").font(Theme.body).foregroundStyle(Theme.textSecondary)
            }
            Spacer()
            TrialChip()
        }
        .padding(.horizontal, Theme.safeH)
    }

    @ViewBuilder
    private func channelShelf(_ key: String, _ rows: [ChannelRow]) -> some View {
        if !rows.isEmpty {
            Shelf(title: L10n.t(key)) {
                ForEach(rows) { row in
                    Button { router.play(.channel(row.channel), channels: rows.map(\.channel)) } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            ChannelLogo(url: row.channel.logoUrl, width: Theme.isTV ? 280 : 150)
                            Text(row.channel.name).font(Theme.caption.weight(.semibold)).foregroundStyle(Theme.textPrimary).lineLimit(1)
                            Text(row.nowNext?.now?.title ?? " ").font(.caption2).foregroundStyle(Theme.textSecondary).lineLimit(1)
                        }
                        .frame(width: Theme.isTV ? 280 : 150, alignment: .leading)
                    }
                    .buttonStyle(CardButtonStyle())
                }
            }
        }
    }
}
