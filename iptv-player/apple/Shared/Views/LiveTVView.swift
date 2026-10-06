import IPTVCore
import IPTVKit
import SwiftUI

/// Category menu entries shared by Live TV and the TV guide: All · Favorites · favorite categories
/// (⭐) · the other categories; hidden categories removed.
@MainActor
private func channelFilters(_ model: LiveTVViewModel, env: AppEnvironment) -> [(id: ChannelFilter, title: String)] {
    let sourceId = env.currentSource?.id
    let hidden = sourceId.map { HiddenStore.shared.hiddenCategories($0) } ?? []
    let favorite = sourceId.map { env.favorites.favoriteCategoryIds(sourceId: $0) } ?? []
    let visible = model.categories.filter { !hidden.contains($0.id) }
    let ordered = visible.filter { favorite.contains($0.id) } + visible.filter { !favorite.contains($0.id) }
    return [(ChannelFilter.all, L10n.t("all")), (.favorites, L10n.t("nav_favorites"))]
        + ordered.map { (ChannelFilter.category($0.id), $0.name) }
}

/// ⭐ marker of the filter menu / chips: the Favorites entry and favorite categories.
@MainActor
private func isStarred(_ filter: ChannelFilter, env: AppEnvironment) -> Bool {
    switch filter {
    case .favorites: return true
    case .category(let id): return env.currentSource.map { env.favorites.isFavoriteCategory(sourceId: $0.id, categoryId: id) } ?? false
    case .all: return false
    }
}

/// Rows without hidden channels / categories.
@MainActor
private func visibleRows(_ rows: [ChannelRow], sourceId: String?) -> [ChannelRow] {
    guard let sourceId else { return rows }
    let store = HiddenStore.shared
    return rows.filter { !store.isHidden(channelId: $0.channel.id, categoryId: $0.channel.categoryId, sourceId: sourceId) }
}

/// Floating category chip ("🇹🇷 Türkiye ⌄") with the category menu (SCREENS §3.3).
private struct CategoryChipMenu: View {
    @Environment(AppEnvironment.self) private var env
    @Bindable var model: LiveTVViewModel

    var body: some View {
        let items = channelFilters(model, env: env)
        let current = items.first { $0.id == model.filter }?.title ?? L10n.t("all")
        let hiddenCount = env.currentSource.map { HiddenStore.shared.count($0.id) } ?? 0
        Menu {
            // ⭐ for the selected category (device-local, per source): favorite categories come
            // right after "Favorites" here and as sections after the favorite channels in "All".
            if case .category(let categoryId) = model.filter, let sid = env.currentSource?.id {
                let on = env.favorites.isFavoriteCategory(sourceId: sid, categoryId: categoryId)
                Button { env.favorites.toggleCategory(sourceId: sid, categoryId: categoryId) } label: {
                    Label(L10n.t(on ? "fav_category_remove" : "fav_category_add"), systemImage: on ? "star.slash" : "star")
                }
                .accessibilityIdentifier("fav_category_toggle")
                Divider()
            }
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                Button {
                    model.filter = item.id
                } label: {
                    let flag = CountryFlag.emoji(for: item.title).map { "\($0)  " } ?? ""
                    let star = isStarred(item.id, env: env) && item.id != .favorites ? "⭐ " : ""
                    if model.filter == item.id {
                        Label(star + flag + CountryFlag.strippedTitle(item.title), systemImage: "checkmark")
                    } else {
                        Text(star + flag + CountryFlag.strippedTitle(item.title))
                    }
                }
            }
            if hiddenCount > 0, let sid = env.currentSource?.id {
                Divider()
                Button { HiddenStore.shared.showAll(sourceId: sid); model.reload() } label: {
                    Label(L10n.t("hidden_show_all", String(hiddenCount)), systemImage: "eye")
                }
            }
        } label: {
            HStack(spacing: Theme.isTV ? 12 : 6) {
                if isStarred(model.filter, env: env) {
                    Image(systemName: "star.fill").foregroundStyle(Theme.warning)
                }
                if model.filter != .favorites, let flag = CountryFlag.emoji(for: current) {
                    Text(flag)
                }
                Text(CountryFlag.strippedTitle(current)).lineLimit(1)
                Image(systemName: "chevron.down").font(Theme.isTV ? .system(size: 20, weight: .bold) : .caption.weight(.bold))
            }
            .font(Theme.isTV ? Theme.caption.weight(.semibold) : .subheadline.weight(.semibold))
            .foregroundStyle(Theme.textPrimary)
            .padding(.horizontal, Theme.isTV ? 28 : 16).padding(.vertical, Theme.isTV ? 14 : 8)
            .background(Capsule().fill(.ultraThinMaterial))
            .background(Capsule().fill(Theme.surfaceElevated.opacity(0.6)))
            .overlay(Capsule().stroke(Theme.stroke, lineWidth: 1))
        }
        #if os(tvOS)
        .buttonStyle(CardButtonStyle(radius: 40, scale: 1.08))
        #endif
        .accessibilityLabel(L10n.t("category_picker"))
        .accessibilityValue(current)
        .accessibilityIdentifier("category_menu")
    }
}

/// Live TV (SCREENS §3.3): grid of channel cards with a floating category chip.
struct LiveTVView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(Router.self) private var router
    @State private var model: LiveTVViewModel?
    @State private var archiveChannel: Channel?

    private var columns: [GridItem] {
        #if os(tvOS)
        Array(repeating: GridItem(.flexible(), spacing: 40, alignment: .top), count: 4)
        #else
        [GridItem(.adaptive(minimum: 160, maximum: 320), spacing: 10, alignment: .top)]
        #endif
    }

    var body: some View {
        ZStack(alignment: .top) {
            if let model {
                let sid = env.currentSource?.id
                let rows = visibleRows(model.rows, sourceId: sid)
                let favorites = visibleRows(model.favoriteRows, sourceId: sid)
                let categorySections = model.favoriteCategorySections
                let hasSections = !favorites.isEmpty || !categorySections.isEmpty
                ScrollView {
                    #if os(tvOS)
                    CategoryChipMenu(model: model).padding(.top, 20).padding(.bottom, 10)
                    #endif
                    if rows.isEmpty && !hasSections {
                        EmptyStateView(icon: model.filter == .favorites ? "star" : "tv",
                                       text: L10n.t(model.filter == .favorites ? "favorites_empty" : "live_empty"))
                            .frame(height: 400)
                    }
                    // "All": favorite channels first (manual order), then favorite categories, then the rest.
                    // Separate grids per section: a Section inserted above existing LazyVGrid content
                    // was not rendered until the view was rebuilt.
                    VStack(alignment: .leading, spacing: Theme.isTV ? 40 : 10) {
                        if !favorites.isEmpty {
                            sectionHeader(L10n.t("nav_favorites"), icon: "star.fill", id: "live_section_favorites")
                            let zap = favorites.map(\.channel)
                            LazyVGrid(columns: columns, spacing: Theme.isTV ? 40 : 10) {
                                ForEach(favorites) { row in
                                    LiveChannelCard(row: row, zapList: zap, identifier: "live_favorite_\(row.channel.id)",
                                                    onArchive: { archiveChannel = row.channel })
                                }
                            }
                        }
                        ForEach(categorySections) { section in
                            let title = [CountryFlag.emoji(for: section.category.name), CountryFlag.strippedTitle(section.category.name)]
                                .compactMap { $0 }.joined(separator: " ")
                            sectionHeader(title, icon: "star", id: "live_section_category_\(section.category.id)",
                                          seeAll: section.total > section.rows.count ? { model.filter = .category(section.category.id) } : nil)
                            let sectionRows = visibleRows(section.rows, sourceId: sid)
                            let zap = sectionRows.map(\.channel)
                            LazyVGrid(columns: columns, spacing: Theme.isTV ? 40 : 10) {
                                ForEach(sectionRows) { row in
                                    LiveChannelCard(row: row, zapList: zap, identifier: "live_category_channel_\(row.channel.id)",
                                                    onArchive: { archiveChannel = row.channel })
                                }
                            }
                        }
                        if hasSections, !rows.isEmpty { sectionHeader(L10n.t("live_all_channels"), icon: nil, id: "live_section_all") }
                        LazyVGrid(columns: columns, spacing: Theme.isTV ? 40 : 10) {
                            ForEach(rows) { row in
                                LiveChannelCard(row: row, zapList: model.channels, onArchive: { archiveChannel = row.channel })
                                    .onAppear { model.loadMoreIfNeeded(current: row) }
                            }
                        }
                    }
                    .padding(.horizontal, Theme.safeH)
                    .padding(.top, Theme.isTV ? 10 : 56)
                    .padding(.bottom, Theme.isTV ? 60 : 30)
                }
                #if os(tvOS)
                .scrollClipDisabled()
                #endif
                #if !os(tvOS)
                CategoryChipMenu(model: model).padding(.top, 6)
                #endif
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .screenBackground()
        .sheet(item: $archiveChannel) { CatchupSheet(channel: $0).environment(env).environment(router) }
        .onAppear {
            if model == nil {
                let m = LiveTVViewModel(env: env)
                m.showsFavoriteSections = true
                model = m
                m.reload()
            }
        }
        .onChange(of: env.catalogVersion) { model?.reload() }
        .onChange(of: env.libraryVersion) { model?.reloadFavorites() }
    }

    /// Section title of the grid ("Favorites", favorite categories with "See all", "All channels").
    private func sectionHeader(_ title: String, icon: String?, id: String, seeAll: (() -> Void)? = nil) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.isTV ? 12 : 6) {
            if let icon { Image(systemName: icon).foregroundStyle(Theme.warning) }
            Text(title).font(Theme.rowTitle).foregroundStyle(Theme.textPrimary).lineLimit(1)
            Spacer(minLength: 12)
            if let seeAll {
                Button(action: seeAll) {
                    LText("action_see_all").font(Theme.isTV ? Theme.caption.weight(.semibold) : .subheadline.weight(.semibold))
                        .foregroundStyle(Theme.primary)
                        #if os(tvOS)
                        .padding(.horizontal, 20).padding(.vertical, 8)
                        #endif
                }
                #if os(tvOS)
                .buttonStyle(CardButtonStyle(radius: 30, scale: 1.08))
                #else
                .buttonStyle(.plain)
                #endif
                .accessibilityIdentifier("\(id)_see_all")
            }
        }
        .padding(.top, Theme.isTV ? 20 : 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isHeader)
        .accessibilityIdentifier(id)
    }
}

/// Live channel card: logo tile, name, quality badge, programme time + title, progress, action icons.
private struct LiveChannelCard: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(Router.self) private var router
    let row: ChannelRow
    let zapList: [Channel]
    /// Play button id; favorites / category sections use their own ids (same channel twice in the grid).
    var identifier: String?
    let onArchive: () -> Void

    private var channel: Channel { row.channel }

    var body: some View {
        let target = env.favoriteTarget(channel)
        let fav = target.map { env.favorites.isFavorite($0.contentKey) } ?? false
        VStack(alignment: .leading, spacing: Theme.isTV ? 14 : 8) {
            Button { router.play(.channel(channel), channels: zapList) } label: { main }
                .buttonStyle(CardButtonStyle(radius: Theme.cardRadius, scale: 1.05))
                .contextMenu {
                    ChannelMenuItems(channel: channel)
                    if channel.catchup.isAvailable {
                        Button(action: onArchive) { Label(L10n.t("catchup_title"), systemImage: "clock.arrow.circlepath") }
                    }
                }
                .accessibilityLabel([channel.name, row.nowNext?.now?.title].compactMap { $0 }.joined(separator: ", "))
                .accessibilityIdentifier(identifier ?? "channel_\(channel.id)")
            #if os(tvOS)
            // TV: one focus target per card (D-pad stays on the cards); the icons are indicators,
            // favorite / archive are in the long-press menu.
            HStack(spacing: 24) {
                Image(systemName: fav ? "star.fill" : "star").foregroundStyle(fav ? Theme.warning : Theme.textSecondary)
                if channel.catchup.isAvailable { Image(systemName: "clock.arrow.circlepath").foregroundStyle(Theme.textSecondary) }
                Spacer(minLength: 0)
            }
            .font(.system(size: 26))
            .padding(.horizontal, 18)
            .padding(.bottom, 12)
            .accessibilityHidden(true)
            #else
            // One tap ⭐ (spec §2) and ⟲ archive: 44 pt targets.
            HStack(spacing: 4) {
                if let target {
                    FavoriteButton(target: target, minTapSize: 44)
                        .foregroundStyle(Theme.textSecondary)
                }
                if channel.catchup.isAvailable {
                    Button(action: onArchive) {
                        Image(systemName: "clock.arrow.circlepath").foregroundStyle(Theme.textSecondary)
                            .frame(minWidth: 44, minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel(L10n.t("catchup_title"))
                    .accessibilityIdentifier("live_archive_\(channel.id)")
                }
                Spacer(minLength: 0)
            }
            .font(.subheadline)
            .buttonStyle(.plain)
            .padding(.horizontal, 2)
            .padding(.bottom, 0)
            #endif
        }
        .background(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous).fill(Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous).stroke(Theme.stroke, lineWidth: 1))
    }

    private var main: some View {
        let now = row.nowNext?.now
        let tile: CGFloat = Theme.isTV ? 80 : 46
        return VStack(alignment: .leading, spacing: Theme.isTV ? 10 : 6) {
            HStack(spacing: Theme.isTV ? 16 : 10) {
                ChannelTile(channel: channel, width: tile, height: tile, radius: Theme.isTV ? 12 : 9)
                VStack(alignment: .leading, spacing: 4) {
                    Text(channel.name).font(Theme.isTV ? Theme.caption.weight(.bold) : .subheadline.weight(.bold))
                        .foregroundStyle(Theme.textPrimary).lineLimit(1).minimumScaleFactor(0.75)
                    if let q = MediaTags.quality(in: channel.name) {
                        Text(q).font(.system(size: Theme.isTV ? 16 : 9, weight: .heavy)).foregroundStyle(Theme.textSecondary)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.textSecondary, lineWidth: 1))
                    }
                }
                Spacer(minLength: 0)
            }
            if let now {
                Text(env.timeFormatter.range(start: now.start, end: now.end))
                    .font(Theme.isTV ? .system(size: 20).monospacedDigit() : .caption2.monospacedDigit()).foregroundStyle(Theme.textSecondary)
                Text(now.title).font(Theme.isTV ? .system(size: 23, weight: .medium) : .caption.weight(.medium))
                    .foregroundStyle(Theme.textPrimary).lineLimit(1)
                ProgressBar(value: EpgSchedule.progress(of: now, at: Date())).frame(height: Theme.isTV ? 4 : 3)
            } else {
                Text(" ").font(Theme.isTV ? .system(size: 20) : .caption2)
                LText("epg_no_info").font(Theme.isTV ? .system(size: 23) : .caption).foregroundStyle(Theme.textSecondary).lineLimit(1)
                ProgressBar(value: 0).frame(height: Theme.isTV ? 4 : 3).opacity(0.4)
            }
        }
        .padding(.horizontal, Theme.isTV ? 18 : 12)
        .padding(.top, Theme.isTV ? 18 : 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

/// TV guide (SCREENS §3.4): category chips + EPG list; iPad / Apple TV add the "Now on air" + "Today" panel.
struct GuideView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(Router.self) private var router
    #if !os(tvOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif
    @State private var model: LiveTVViewModel?
    @State private var selected: Channel?
    @State private var archiveChannel: Channel?

    private var showsPanel: Bool {
        #if os(tvOS)
        true
        #else
        sizeClass == .regular
        #endif
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let model {
                let rows = visibleRows(model.rows, sourceId: env.currentSource?.id)
                ChipBar(items: channelFilters(model, env: env),
                        selection: Binding(get: { model.filter }, set: { model.filter = $0 }),
                        showFlags: true, leadingIcon: { isStarred($0, env: env) ? "star.fill" : nil }, identifierPrefix: "guide_filter")
                    .padding(.bottom, Theme.isTV ? 4 : 8)
                if rows.isEmpty {
                    EmptyStateView(icon: model.filter == .favorites ? "star" : "tv",
                                   text: L10n.t(model.filter == .favorites ? "favorites_empty" : "live_empty"))
                } else {
                    HStack(alignment: .top, spacing: Theme.isTV ? 30 : 16) {
                        EpgListView(rows: rows, zapList: model.channels,
                                    onSelect: showsPanel ? { selected = $0 } : nil) { model.loadMoreIfNeeded(current: $0) }
                        if showsPanel {
                            GuidePanel(channel: selected ?? rows.first?.channel, zapList: model.channels,
                                       onArchive: { archiveChannel = $0 })
                                .frame(width: Theme.isTV ? 520 : 320)
                                .padding(.trailing, Theme.safeH)
                        }
                    }
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .screenBackground()
        .sheet(item: $archiveChannel) { CatchupSheet(channel: $0).environment(env).environment(router) }
        .onAppear {
            if model == nil {
                let m = LiveTVViewModel(env: env)
                model = m
                m.reload()
            }
        }
        .onChange(of: env.catalogVersion) { model?.reload() }
        .onChange(of: env.libraryVersion) { model?.reloadFavorites() }
    }
}

/// Side panel: "Now on air" + "Today" upcoming programmes of the selected channel.
private struct GuidePanel: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(Router.self) private var router
    let channel: Channel?
    let zapList: [Channel]
    let onArchive: (Channel) -> Void

    var body: some View {
        let programs = channel.map(load) ?? []
        let now = Date()
        let current = programs.first { $0.isOnAir(at: now) }
        let upcoming = programs.filter { $0.start > now }.prefix(Theme.isTV ? 6 : 10)
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.isTV ? 18 : 12) {
                header("epg_now_on_air")
                if let channel {
                    HStack(spacing: 12) {
                        ChannelTile(channel: channel, width: Theme.isTV ? 96 : 56, height: Theme.isTV ? 96 : 56, radius: 10)
                        Text(channel.name).font(Theme.isTV ? Theme.headline : .headline).foregroundStyle(Theme.textPrimary).lineLimit(2)
                    }
                    if let current {
                        Text(current.title).font(Theme.isTV ? Theme.body.weight(.bold) : .subheadline.weight(.bold)).foregroundStyle(Theme.textPrimary)
                        Text(env.timeFormatter.range(start: current.start, end: current.end))
                            .font(Theme.isTV ? Theme.caption : .caption).foregroundStyle(Theme.textSecondary)
                        ProgressBar(value: EpgSchedule.progress(of: current, at: now)).frame(height: 4)
                        if let d = current.description {
                            Text(d).font(Theme.isTV ? .system(size: 22) : .caption).foregroundStyle(Theme.textSecondary).lineLimit(4)
                        }
                    } else {
                        LText("epg_no_info").font(Theme.caption).foregroundStyle(Theme.textSecondary)
                    }
                    #if !os(tvOS)
                    HStack(spacing: 10) {
                        Button { router.play(.channel(channel), channels: zapList) } label: { Label(L10n.t("action_play"), systemImage: "play.fill") }
                            .buttonStyle(WhitePillButtonStyle())
                            .accessibilityIdentifier("guide_play")
                        if channel.catchup.isAvailable {
                            Button { onArchive(channel) } label: { Image(systemName: "clock.arrow.circlepath") }
                                .buttonStyle(RoundIconButtonStyle(size: 40))
                                .accessibilityLabel(L10n.t("catchup_title"))
                                .accessibilityIdentifier("guide_archive")
                        }
                    }
                    #endif
                    if !upcoming.isEmpty {
                        header("epg_today").padding(.top, 8)
                        ForEach(Array(upcoming), id: \.start) { p in
                            HStack(alignment: .top, spacing: 12) {
                                Text(env.timeFormatter.time(p.start)).font((Theme.isTV ? Theme.caption : .footnote).monospacedDigit().weight(.semibold))
                                    .foregroundStyle(Theme.textPrimary).lineLimit(1).fixedSize().frame(minWidth: Theme.isTV ? 120 : 52, alignment: .leading)
                                Text(p.title).font(Theme.isTV ? Theme.caption : .footnote).foregroundStyle(Theme.textPrimary).lineLimit(1)
                                Spacer(minLength: 4)
                                Text(L10n.t("minutes_short", String(Int(p.duration / 60))))
                                    .font(Theme.isTV ? .system(size: 20) : .caption2).foregroundStyle(Theme.textSecondary)
                            }
                            .padding(Theme.isTV ? 14 : 10)
                            .background(RoundedRectangle(cornerRadius: 10).fill(Theme.surfaceElevated.opacity(0.6)))
                        }
                    }
                }
            }
            .padding(Theme.isTV ? 28 : 16)
        }
        .background(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous).fill(Theme.surface))
        .accessibilityIdentifier("guide_panel")
    }

    private func header(_ key: String) -> some View {
        HStack(spacing: 8) {
            Capsule().fill(Theme.primary).frame(width: 4, height: Theme.isTV ? 26 : 16)
            LText(key).font((Theme.isTV ? Theme.caption : .caption).weight(.heavy)).textCase(.uppercase).foregroundStyle(Theme.textPrimary)
        }
        .accessibilityAddTraits(.isHeader)
    }

    private func load(_ channel: Channel) -> [EpgProgram] {
        guard let epgId = channel.epgId else { return [] }
        let now = Date()
        return (try? env.epg.programs(sourceId: channel.sourceId, epgId: epgId,
                                      in: DateInterval(start: now.addingTimeInterval(-4 * 3600), duration: 28 * 3600))) ?? []
    }
}

/// Catch-up archive (SCREENS §3.4): past programmes per day; replay via the Xtream timeshift URL.
struct CatchupSheet: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(Router.self) private var router
    @Environment(\.dismiss) private var dismiss
    let channel: Channel

    var body: some View {
        let days = days()
        let canReplay = replayURL(for: nil) != nil
        NavigationStack {
            List {
                if !canReplay {
                    LText("catchup_xtream_only").font(Theme.caption).foregroundStyle(Theme.textSecondary)
                        .listRowBackground(Theme.surface)
                }
                if days.allSatisfy({ $0.programs.isEmpty }) {
                    LText("catchup_empty").foregroundStyle(Theme.textSecondary).listRowBackground(Theme.surface)
                }
                ForEach(days, id: \.day) { day in
                    if !day.programs.isEmpty {
                        Section {
                            ForEach(day.programs, id: \.start) { p in row(p, canReplay: canReplay) }
                        } header: {
                            Text(day.day.formatted(.dateTime.weekday(.wide).day().month(.wide).locale(L10n.locale)))
                                .font((Theme.isTV ? Theme.caption : .subheadline).weight(.bold)).foregroundStyle(Theme.primary)
                                .textCase(nil)
                        }
                    }
                }
            }
            .hiddenListBackground()
            .screenBackground()
            .navigationTitle(L10n.t("catchup_title"))
            #if !os(tvOS)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                        .accessibilityLabel(L10n.t("action_close"))
                }
            }
            #endif
        }
        .accessibilityIdentifier("catchup_sheet")
    }

    @ViewBuilder
    private func row(_ p: EpgProgram, canReplay: Bool) -> some View {
        let onAir = p.isOnAir(at: Date())
        let content = HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(onAir ? "\(env.timeFormatter.time(p.start)) · \(L10n.t("catchup_on_air"))" : env.timeFormatter.time(p.start))
                    .font((Theme.isTV ? Theme.caption : .caption).weight(.bold).monospacedDigit())
                    .foregroundStyle(onAir ? Theme.live : Theme.primary)
                Text(p.title).font(Theme.isTV ? Theme.body.weight(.semibold) : .subheadline.weight(.semibold)).foregroundStyle(Theme.textPrimary).lineLimit(1)
                if let d = p.description {
                    Text(d).font(Theme.isTV ? .system(size: 21) : .caption).foregroundStyle(Theme.textSecondary).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if canReplay {
                Image(systemName: "play.circle").font(Theme.isTV ? .system(size: 36) : .title2).foregroundStyle(Theme.textPrimary)
            }
        }
        if canReplay, let url = replayURL(for: p) {
            Button {
                dismiss()
                router.play(.url(url, title: "\(channel.name) · \(p.title)"))
            } label: { content }
            .accessibilityLabel("\(L10n.t("catchup_replay")): \(p.title)")
            .listRowBackground(Theme.surface)
        } else {
            content.listRowBackground(Theme.surface)
        }
    }

    /// Days of the archive (today first, back to `catchup.days`), past and on-air programmes newest first.
    private func days() -> [(day: Date, programs: [EpgProgram])] {
        guard let epgId = channel.epgId else { return [] }
        let cal = Calendar.current
        let now = Date()
        let count = min(max(channel.catchup.days, 1), 7)
        return (0..<count).compactMap { offset in
            guard let day = cal.date(byAdding: .day, value: -offset, to: cal.startOfDay(for: now)),
                  let end = cal.date(byAdding: .day, value: 1, to: day) else { return nil }
            let programs = (try? env.epg.programs(sourceId: channel.sourceId, epgId: epgId, in: DateInterval(start: day, end: min(end, now)))) ?? []
            return (day, programs.filter { $0.start <= now }.sorted { $0.start > $1.start })
        }
    }

    /// Xtream timeshift URL (CONTRACT §4); `nil` for M3U sources.
    private func replayURL(for p: EpgProgram?) -> String? {
        guard case .xtream(let secrets)? = env.secrets(for: channel.sourceId), let builder = XtreamURLBuilder(secrets: secrets) else { return nil }
        guard let p else { return "" }
        let account = env.sources.first { $0.id == channel.sourceId }?.xtreamAccount
        let ext = (account?.allowedOutputFormats.contains("m3u8") ?? true) ? "m3u8" : "ts"
        return builder.timeshiftURL(streamId: channel.id, start: p.start, end: p.end, serverTimezone: account?.serverTimezone, ext: ext).absoluteString
    }
}

/// Time window of the EPG list: "now" sits right after the channel tile when the list opens.
struct EpgTimeline {
    let start: Date
    let end: Date
    let pointsPerMinute: CGFloat

    init(now: Date, tileWidth: CGFloat, pointsPerMinute: CGFloat, hours: Double = 12) {
        self.pointsPerMinute = pointsPerMinute
        let leadMinutes = Double(tileWidth / pointsPerMinute) + 20
        let raw = now.addingTimeInterval(-leadMinutes * 60)
        start = Date(timeIntervalSince1970: (raw.timeIntervalSince1970 / 60).rounded(.down) * 60)
        end = start.addingTimeInterval(hours * 3600)
    }

    func x(_ date: Date) -> CGFloat {
        CGFloat(min(max(date.timeIntervalSince(start), 0), end.timeIntervalSince(start)) / 60) * pointsPerMinute
    }

    var width: CGFloat { x(end) }
    var interval: DateInterval { DateInterval(start: start, end: end) }

    /// Half-hour ticks inside the window.
    var ticks: [Date] {
        var t = Date(timeIntervalSince1970: (start.timeIntervalSince1970 / 1800).rounded(.up) * 1800)
        var out: [Date] = []
        while t < end { out.append(t); t = t.addingTimeInterval(1800) }
        return out
    }
}

/// Layout constants of the EPG list.
private enum EpgMetrics {
    #if os(tvOS)
    static let tileWidth: CGFloat = 250
    static let rowHeight: CGFloat = 112
    static let rowSpacing: CGFloat = 14
    static let pointsPerMinute: CGFloat = 8      // 30 min = 240 pt
    static let axisHeight: CGFloat = 64
    static let gap: CGFloat = 6
    #else
    static let tileWidth: CGFloat = 92
    static let rowHeight: CGFloat = 56
    static let rowSpacing: CGFloat = 8
    static let pointsPerMinute: CGFloat = 4      // 30 min = 120 pt
    static let axisHeight: CGFloat = 36
    static let gap: CGFloat = 4
    #endif
}

/// iOS/tvOS 18+: exact horizontal offset (focus-driven scrolling on tvOS does not always
/// re-run the GeometryReader preference); iOS/tvOS 17 rely on the preference only.
private struct ScrollOffsetObserver: ViewModifier {
    let onChange: (CGFloat) -> Void

    func body(content: Content) -> some View {
        if #available(iOS 18.0, tvOS 18.0, *) {
            content.onScrollGeometryChange(for: CGFloat.self, of: { $0.contentOffset.x + $0.contentInsets.leading }) { _, x in onChange(x) }
        } else {
            content
        }
    }
}

private struct EpgScrollKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

/// The reinvented EPG list (shared iOS + tvOS). Rows share one horizontal scroll position, so the
/// time axis stays in sync; the channel tile stays pinned on the left while programmes slide under it.
struct EpgListView: View {
    @Environment(AppEnvironment.self) private var env
    let rows: [ChannelRow]
    let zapList: [Channel]
    /// iPad: tile tap selects the channel for the side panel; tvOS: called on focus.
    var onSelect: ((Channel) -> Void)? = nil
    var onRowAppear: (ChannelRow) -> Void = { _ in }
    @State private var scrollX: CGFloat = 0
    @State private var now = Date()
    @State private var timeline = EpgTimeline(now: Date(), tileWidth: EpgMetrics.tileWidth, pointsPerMinute: EpgMetrics.pointsPerMinute)

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                timeAxis
                ScrollView(.vertical, showsIndicators: !Theme.isTV) {
                    LazyVStack(alignment: .leading, spacing: EpgMetrics.rowSpacing) {
                        ForEach(rows) { row in
                            EpgRowView(row: row, zapList: zapList, timeline: timeline, scrollX: scrollX, now: now, onSelect: onSelect)
                                .onAppear { onRowAppear(row) }
                        }
                    }
                    .padding(.top, 4)
                    .padding(.bottom, Theme.isTV ? 60 : 24)
                }
                .frame(width: timeline.width)
                .overlay(alignment: .topLeading) { nowLine }
            }
            .padding(.leading, Theme.isTV ? Theme.safeH : Theme.safeH)
            .background(GeometryReader { g in
                Color.clear.preference(key: EpgScrollKey.self, value: -g.frame(in: .named("epg_h")).minX)
            })
        }
        .coordinateSpace(name: "epg_h")
        .onPreferenceChange(EpgScrollKey.self) { value in updateScrollX(value) }
        .modifier(ScrollOffsetObserver { updateScrollX($0) })
        .overlay(alignment: .topLeading) { todayLabel }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                now = Date()
            }
        }
    }

    private func updateScrollX(_ value: CGFloat) {
        let clamped = max(0, value)
        if abs(clamped - scrollX) > 0.5 { scrollX = clamped }
    }

    /// "Today" pinned above the tile column.
    private var todayLabel: some View {
        LText("epg_today").font(Theme.isTV ? Theme.headline : .title3.bold()).foregroundStyle(Theme.textPrimary)
            .frame(width: EpgMetrics.tileWidth + (Theme.isTV ? 0 : 6), height: EpgMetrics.axisHeight, alignment: .leading)
            .padding(.leading, Theme.safeH)
            .background(Theme.bg)
            .accessibilityAddTraits(.isHeader)
    }

    private var timeAxis: some View {
        ZStack(alignment: .topLeading) {
            Color.clear.frame(width: timeline.width, height: EpgMetrics.axisHeight)
            ForEach(timeline.ticks.filter { abs(timeline.x($0) - timeline.x(now)) > (Theme.isTV ? 200 : 100) || $0 < now }
                        .filter { timeline.x(now) - timeline.x($0) > (Theme.isTV ? 140 : 70) || $0 > now }, id: \.self) { tick in
                Text(env.timeFormatter.time(tick))
                    .font(Theme.isTV ? Theme.caption.monospacedDigit() : .footnote.monospacedDigit())
                    .foregroundStyle(Theme.textSecondary)
                    .frame(height: EpgMetrics.axisHeight)
                    .padding(.leading, timeline.x(tick) + 4)
            }
            // "now" marker
            HStack(spacing: 4) {
                Image(systemName: "arrowtriangle.down.fill").font(.system(size: Theme.isTV ? 16 : 9))
                Text(env.timeFormatter.time(now)).font(Theme.isTV ? Theme.caption.weight(.bold).monospacedDigit() : .footnote.weight(.bold).monospacedDigit())
            }
            .foregroundStyle(Theme.textPrimary)
            .padding(.horizontal, 6)
            .frame(height: EpgMetrics.axisHeight)
            .background(Theme.bg)
            .padding(.leading, timeline.x(now) - (Theme.isTV ? 12 : 6))
        }
        .frame(width: timeline.width, height: EpgMetrics.axisHeight, alignment: .leading)
        .accessibilityHidden(true)
    }

    private var nowLine: some View {
        let x = timeline.x(now)
        let rowsHeight = CGFloat(rows.count) * (EpgMetrics.rowHeight + EpgMetrics.rowSpacing) + 4
        return Rectangle().fill(Theme.live.opacity(0.75)).frame(width: 1.5)
            .frame(maxHeight: rowsHeight)
            .padding(.leading, x)
            .opacity(x - scrollX > EpgMetrics.tileWidth + 4 ? 1 : 0)
            .allowsHitTesting(false)
    }
}

/// One channel of the EPG list.
private struct EpgRowView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(Router.self) private var router
    let row: ChannelRow
    let zapList: [Channel]
    let timeline: EpgTimeline
    let scrollX: CGFloat
    let now: Date
    var onSelect: ((Channel) -> Void)?
    @State private var programs: [EpgProgram]?

    private var channel: Channel { row.channel }

    var body: some View {
        let isFavorite = env.favoriteTarget(channel).map { env.favorites.isFavorite($0.contentKey) } ?? false
        ZStack(alignment: .topLeading) {
            blocks(isFavorite: isFavorite)
            tile(isFavorite: isFavorite)
                .offset(x: scrollX)
                .zIndex(1)
        }
        .frame(width: timeline.width, height: EpgMetrics.rowHeight, alignment: .topLeading)
        // catalogVersion also bumps when the background XMLTV load finishes.
        .task(id: "\(channel.id)|\(timeline.start.timeIntervalSince1970)|\(env.catalogVersion)") { load() }
    }

    private func load() {
        guard let epgId = channel.epgId else { programs = []; return }
        programs = (try? env.epg.programs(sourceId: channel.sourceId, epgId: epgId, in: timeline.interval)) ?? []
    }

    private func play() {
        router.play(.channel(channel), channels: zapList)
    }

    @ViewBuilder
    private func tile(isFavorite: Bool) -> some View {
        let content = ChannelTile(channel: channel, width: EpgMetrics.tileWidth, height: EpgMetrics.rowHeight)
            .overlay(alignment: .bottomLeading) {
                HStack(spacing: 3) {
                    if isFavorite { Image(systemName: "star.fill").foregroundStyle(Theme.warning) }
                    if channel.catchup.isAvailable { Image(systemName: "clock.arrow.circlepath").foregroundStyle(.white) }
                }
                .font(.system(size: Theme.isTV ? 18 : 9, weight: .bold))
                .shadow(color: .black.opacity(0.6), radius: 2)
                .padding(Theme.isTV ? 8 : 4)
            }
            // Mask the gutter left of the tile and the gap right of it while programmes slide under it.
            .background(alignment: .trailing) {
                // ×2 on TV: the scroll view adds the system safe-area inset on top of our padding.
                Theme.bg.frame(width: EpgMetrics.tileWidth + Theme.safeH * (Theme.isTV ? 2 : 1) + EpgMetrics.gap).offset(x: EpgMetrics.gap)
            }
        #if os(tvOS)
        content   // focus lives on the programme blocks (D-pad ◀▶ programmes, ▲▼ channels)
        #else
        Button { if let onSelect { onSelect(channel) } else { play() } } label: { content }
            .buttonStyle(.plain)
            .accessibilityLabel(channel.name)
            .accessibilityHint(L10n.t("action_play"))
            .accessibilityIdentifier("channel_\(channel.id)")
            .contextMenu { ChannelMenuItems(channel: channel) }
        #endif
    }

    @ViewBuilder
    private func blocks(isFavorite: Bool) -> some View {
        let visible = (programs ?? []).filter { $0.end > timeline.start && $0.start < timeline.end }
        ZStack(alignment: .topLeading) {
            if visible.isEmpty {
                block(nil, from: 0, to: timeline.width, isFirst: true, isFavorite: isFavorite)
            } else {
                ForEach(Array(visible.enumerated()), id: \.element.start) { index, p in
                    let x0 = timeline.x(p.start)
                    let x1 = timeline.x(p.end)
                    if x1 - x0 > 2 {
                        block(p, from: x0, to: x1, isFirst: index == 0, isFavorite: isFavorite)
                    }
                }
            }
        }
    }

    private func block(_ p: EpgProgram?, from x0: CGFloat, to x1: CGFloat, isFirst: Bool, isFavorite: Bool) -> some View {
        let width = max(0, x1 - x0 - EpgMetrics.gap)
        // Sticky label: keeps the text readable when the block slides under the pinned tile.
        let visibleLeft = scrollX + EpgMetrics.tileWidth + EpgMetrics.gap
        let inset = min(max(0, visibleLeft - x0), max(0, width - (Theme.isTV ? 120 : 56)))
        let onAir = p?.isOnAir(at: now) ?? true
        let isPast = p.map { $0.end <= now } ?? false
        let elapsed = p.map { CGFloat(EpgSchedule.progress(of: $0, at: now)) } ?? 0
        return EpgBlockButton(action: play) {
            EpgBlockLabel(channel: channel, program: p, onAir: onAir, isPast: isPast, elapsed: elapsed,
                          inset: inset, timeText: p.map { env.timeFormatter.time($0.start) }, isFirst: isFirst,
                          onFocus: { onSelect?(channel) })
                .frame(width: width, height: EpgMetrics.rowHeight, alignment: .leading)
        }
        .contextMenu { ChannelMenuItems(channel: channel) }
        .accessibilityLabel([channel.name, p?.title ?? L10n.t("epg_no_info"),
                             p.map { env.timeFormatter.range(start: $0.start, end: $0.end) }].compactMap { $0 }.joined(separator: ", "))
        .accessibilityIdentifier(onAir ? "epg_now_\(channel.id)" : "epg_block")
        .padding(.leading, x0)
    }
}

/// Programme block button: plain on iOS; on tvOS the block brightens, scales slightly and gets the ring.
private struct EpgBlockButton<Label: View>: View {
    let action: () -> Void
    @ViewBuilder var label: () -> Label

    var body: some View {
        Button(action: action, label: label)
            #if os(tvOS)
            .buttonStyle(CardButtonStyle(radius: 12, scale: 1.03))
            #else
            .buttonStyle(.plain)
            #endif
    }
}

private struct EpgBlockLabel: View {
    @Environment(\.isFocused) private var isFocused
    let channel: Channel
    let program: EpgProgram?
    let onAir: Bool
    let isPast: Bool
    let elapsed: CGFloat
    let inset: CGFloat
    let timeText: String?
    let isFirst: Bool
    var onFocus: () -> Void = {}

    var body: some View {
        let color = Theme.channelColor(channel.name)
        let radius: CGFloat = Theme.isTV ? 12 : 9
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(onAir ? color.opacity(0.42) : (isPast ? Theme.surface : color.opacity(0.2)))
            if onAir, program != nil {
                GeometryReader { g in
                    Rectangle().fill(color.opacity(0.38)).frame(width: g.size.width * elapsed)
                }
                .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            }
            if isFocused {
                RoundedRectangle(cornerRadius: radius, style: .continuous).fill(Color.white.opacity(0.14))
            }
            VStack(alignment: .leading, spacing: Theme.isTV ? 4 : 1) {
                HStack(spacing: Theme.isTV ? 8 : 4) {
                    if onAir || program == nil {
                        Text(channel.name.uppercased()).lineLimit(1)
                        if let q = MediaTags.quality(in: channel.name) {
                            Text(q).font(.system(size: Theme.isTV ? 15 : 8, weight: .heavy))
                                .fixedSize()
                                .padding(.horizontal, 3)
                                .overlay(RoundedRectangle(cornerRadius: 3).stroke(Theme.textSecondary, lineWidth: 1))
                        }
                    }
                    if let timeText { Text(timeText).monospacedDigit().fixedSize() }
                }
                .font(Theme.isTV ? .system(size: 20, weight: .semibold) : .system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)
                Text(program?.title ?? L10n.t("epg_no_info"))
                    .font(Theme.isTV ? .system(size: 27, weight: .semibold) : .system(size: 15, weight: .semibold))
                    .foregroundStyle(isPast ? Theme.textSecondary : Theme.textPrimary)
                    .lineLimit(1)
            }
            .padding(.leading, inset + (Theme.isTV ? 14 : 8))
            .padding(.trailing, Theme.isTV ? 10 : 6)
        }
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .onChange(of: isFocused) { _, focused in if focused { onFocus() } }
    }
}
