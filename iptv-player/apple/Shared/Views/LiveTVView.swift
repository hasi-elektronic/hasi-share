import IPTVCore
import IPTVKit
import SwiftUI

/// Live TV (SCREENS §3.3). Mobile: category chips + list; TV: categories | channels ★ | preview.
struct LiveTVView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(Router.self) private var router
    @State private var model: LiveTVViewModel?
    @State private var showGuide = false

    var body: some View {
        Group {
            if let model {
                #if os(tvOS)
                TVLiveLayout(model: model, showGuide: $showGuide)
                #else
                mobile(model)
                #endif
            } else {
                ProgressView()
            }
        }
        .screenBackground()
        .onAppear {
            if model == nil {
                let m = LiveTVViewModel(env: env)
                model = m
                m.reload()
            }
        }
        .onChange(of: env.catalogVersion) { model?.reload() }
        .onChange(of: env.libraryVersion) { if model?.filter == .favorites { model?.reload() } }
        .navigationDestination(isPresented: $showGuide) {
            EpgGridView(channels: model?.channels ?? [])
        }
    }

    private func filters(_ model: LiveTVViewModel) -> [(id: ChannelFilter, title: String)] {
        [(ChannelFilter.all, L10n.t("all")), (.favorites, L10n.t("nav_favorites"))]
            + model.categories.map { (ChannelFilter.category($0.id), $0.name) }
    }

    #if !os(tvOS)
    private func mobile(_ model: LiveTVViewModel) -> some View {
        VStack(spacing: 0) {
            ChipBar(items: filters(model), selection: Binding(get: { model.filter }, set: { model.filter = $0 }))
            if model.rows.isEmpty {
                EmptyStateView(icon: "tv", text: L10n.t("live_empty"))
            } else {
                List {
                    ForEach(model.rows) { row in
                        Button { router.play(.channel(row.channel), channels: model.channels) } label: {
                            ChannelRowView(row: row, isFavorite: env.isFavorite(sourceId: row.channel.sourceId, kind: .live, itemId: row.channel.id),
                                           timeFormatter: env.timeFormatter)
                        }
                        .listRowBackground(Theme.bg)
                        .accessibilityIdentifier("channel_\(row.channel.id)")
                        .contextMenu { favoriteButton(row.channel) }
                        .onAppear { model.loadMoreIfNeeded(current: row) }
                    }
                }
                .listStyle(.plain)
                .hiddenListBackground()
            }
        }
        .navigationTitle(L10n.t("nav_live"))
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(L10n.t("action_guide")) { showGuide = true }
            }
        }
    }
    #endif

    @ViewBuilder
    private func favoriteButton(_ channel: Channel) -> some View {
        let fav = env.isFavorite(sourceId: channel.sourceId, kind: .live, itemId: channel.id)
        Button {
            env.toggleFavorite(sourceId: channel.sourceId, kind: .live, itemId: channel.id, title: channel.name, posterUrl: channel.logoUrl)
        } label: {
            Label(L10n.t(fav ? "action_remove_favorite" : "action_add_favorite"), systemImage: fav ? "star.slash" : "star")
        }
    }
}

#if os(tvOS)
/// TV: three columns with the preview panel; Menu/long-press → favorite.
private struct TVLiveLayout: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(Router.self) private var router
    @Bindable var model: LiveTVViewModel
    @Binding var showGuide: Bool
    @FocusState private var focusedChannel: String?
    @State private var previewRow: ChannelRow?

    var body: some View {
        HStack(alignment: .top, spacing: 32) {
            categoryColumn.frame(width: 360)
            channelColumn.frame(maxWidth: .infinity)
            preview.frame(width: 520)
        }
        .padding(.vertical, Theme.safeV)
        .padding(.trailing, Theme.safeH)
        .onChange(of: focusedChannel) { _, id in
            if let id, let row = model.rows.first(where: { $0.id == id }) { previewRow = row }
        }
    }

    private var categoryColumn: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                categoryButton(.all, L10n.t("all"))
                categoryButton(.favorites, L10n.t("nav_favorites"))
                ForEach(model.categories) { category in
                    categoryButton(.category(category.id), category.name)
                }
            }
            .padding(.vertical, 20)
            .padding(.horizontal, 12)
        }
        .focusSection()
    }

    private func categoryButton(_ filter: ChannelFilter, _ title: String) -> some View {
        Button { model.filter = filter } label: {
            Text(title).font(Theme.caption).lineLimit(1)
                .foregroundStyle(model.filter == filter ? Theme.primary : Theme.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
        }
        .buttonStyle(CardButtonStyle())
    }

    private var channelColumn: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(L10n.t("nav_live")).font(Theme.headline)
                Spacer()
                Button(L10n.t("action_guide")) { showGuide = true }.buttonStyle(SecondaryButtonStyle())
            }
            if model.rows.isEmpty {
                EmptyStateView(icon: "tv", text: L10n.t("live_empty"))
            } else {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(model.rows) { row in
                            Button { router.play(.channel(row.channel), channels: model.channels) } label: {
                                ChannelRowView(row: row, isFavorite: env.isFavorite(sourceId: row.channel.sourceId, kind: .live, itemId: row.channel.id),
                                               timeFormatter: env.timeFormatter)
                                    .background(RoundedRectangle(cornerRadius: 12).fill(focusedChannel == row.id ? Theme.surfaceElevated : Theme.surface))
                            }
                            .buttonStyle(CardButtonStyle())
                            .focused($focusedChannel, equals: row.id)
                            .contextMenu {
                                let fav = env.isFavorite(sourceId: row.channel.sourceId, kind: .live, itemId: row.channel.id)
                                Button(L10n.t(fav ? "action_remove_favorite" : "action_add_favorite")) {
                                    env.toggleFavorite(sourceId: row.channel.sourceId, kind: .live, itemId: row.channel.id,
                                                       title: row.channel.name, posterUrl: row.channel.logoUrl)
                                }
                            }
                            .accessibilityIdentifier("channel_\(row.channel.id)")
                            .onAppear { model.loadMoreIfNeeded(current: row) }
                        }
                    }
                    .padding(.vertical, 20)
                    .padding(.horizontal, 24)
                }
            }
        }
        .focusSection()
        .defaultFocus($focusedChannel, model.rows.first?.id)
    }

    private var preview: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let row = previewRow ?? model.rows.first {
                ChannelLogo(url: row.channel.logoUrl, width: 320)
                Text(row.channel.name).font(Theme.headline).foregroundStyle(Theme.textPrimary)
                if let now = row.nowNext?.now {
                    HStack { LiveBadge(); Text(env.timeFormatter.range(start: now.start, end: now.end)).font(Theme.caption) }
                    Text(now.title).font(Theme.body.weight(.semibold))
                    ProgressBar(value: EpgSchedule.progress(of: now, at: Date())).frame(height: 6)
                    if let desc = now.description { Text(desc).font(Theme.caption).foregroundStyle(Theme.textSecondary).lineLimit(6) }
                } else {
                    LText("epg_no_info").font(Theme.caption).foregroundStyle(Theme.textSecondary)
                }
                if let next = row.nowNext?.next {
                    Divider()
                    Text("\(L10n.t("epg_next")) · \(env.timeFormatter.time(next.start))").font(Theme.caption).foregroundStyle(Theme.textSecondary)
                    Text(next.title).font(Theme.body)
                }
            }
            Spacer()
        }
        .padding(28)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(RoundedRectangle(cornerRadius: Theme.cardRadius).fill(Theme.surface))
    }
}
#endif

/// EPG grid: time axis (30 min = 120 pt), red "now" line (SCREENS §3.3).
struct EpgGridView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(Router.self) private var router
    let channels: [Channel]
    @State private var model: EpgGridViewModel?
    private let slotWidth: CGFloat = Theme.isTV ? 300 : 120
    private let rowHeight: CGFloat = Theme.isTV ? 96 : 60
    private let nameWidth: CGFloat = Theme.isTV ? 280 : 110

    var body: some View {
        Group {
            if let model {
                ScrollView([.vertical]) {
                    HStack(alignment: .top, spacing: 0) {
                        VStack(spacing: 2) {
                            Color.clear.frame(height: 36)
                            ForEach(model.rows, id: \.channel.id) { row in
                                HStack(spacing: 8) {
                                    ChannelLogo(url: row.channel.logoUrl, width: Theme.isTV ? 100 : 40)
                                    Text(row.channel.name).font(Theme.caption).lineLimit(2)
                                }
                                .frame(width: nameWidth, height: rowHeight, alignment: .leading)
                            }
                        }
                        ScrollView(.horizontal) {
                            ZStack(alignment: .topLeading) {
                                VStack(alignment: .leading, spacing: 2) {
                                    timeAxis(model)
                                    ForEach(model.rows, id: \.channel.id) { row in
                                        programmeRow(row.channel, row.programs, model)
                                    }
                                }
                                nowLine(model)
                            }
                        }
                    }
                    .padding(.horizontal, Theme.safeH)
                }
            } else {
                ProgressView()
            }
        }
        .screenBackground()
        .navigationTitle(L10n.t("action_guide"))
        .onAppear {
            let m = EpgGridViewModel(env: env)
            m.load(channels: channels)
            model = m
        }
    }

    private func x(_ date: Date, _ model: EpgGridViewModel) -> CGFloat {
        CGFloat(date.timeIntervalSince(model.start) / 1800) * slotWidth
    }

    private func timeAxis(_ model: EpgGridViewModel) -> some View {
        HStack(spacing: 0) {
            ForEach(0..<Int(model.hours * 2), id: \.self) { i in
                Text(env.timeFormatter.time(model.start.addingTimeInterval(Double(i) * 1800)))
                    .font(Theme.caption.monospacedDigit()).foregroundStyle(Theme.textSecondary)
                    .frame(width: slotWidth, height: 36, alignment: .leading)
            }
        }
    }

    private func programmeRow(_ channel: Channel, _ programs: [EpgProgram], _ model: EpgGridViewModel) -> some View {
        let total = CGFloat(model.hours * 2) * slotWidth
        return ZStack(alignment: .leading) {
            Rectangle().fill(Theme.surface.opacity(0.4)).frame(width: total, height: rowHeight)
            ForEach(programs, id: \.start) { p in
                let start = max(0, x(p.start, model))
                let end = min(total, x(p.end, model))
                if end > start {
                    Button { router.play(.channel(channel), channels: channels) } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(p.title).font(Theme.caption.weight(.semibold)).lineLimit(1)
                            Text(env.timeFormatter.range(start: p.start, end: p.end)).font(.caption2).foregroundStyle(Theme.textSecondary)
                        }
                        .padding(.horizontal, 8)
                        .frame(width: max(0, end - start - 2), height: rowHeight - 4, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 6).fill(p.isOnAir(at: Date()) ? Theme.surfaceElevated : Theme.surface))
                    }
                    .buttonStyle(CardButtonStyle())
                    .offset(x: start)
                }
            }
        }
        .frame(width: total, height: rowHeight, alignment: .leading)
    }

    private func nowLine(_ model: EpgGridViewModel) -> some View {
        Rectangle().fill(Theme.live).frame(width: 2)
            .frame(height: 36 + CGFloat(model.rows.count) * (rowHeight + 2))
            .offset(x: x(Date(), model))
    }
}
