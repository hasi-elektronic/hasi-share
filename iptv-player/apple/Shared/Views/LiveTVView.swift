import IPTVCore
import IPTVKit
import SwiftUI

/// Category menu entries shared by Live TV and the TV guide: All · Favorites · favorite categories
/// (⭐) · the other categories; hidden categories removed.
@MainActor
func channelFilters(_ model: LiveTVViewModel, env: AppEnvironment) -> [(id: ChannelFilter, title: String)] {
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
func isStarred(_ filter: ChannelFilter, env: AppEnvironment) -> Bool {
    switch filter {
    case .favorites: return true
    case .category(let id): return env.currentSource.map { env.favorites.isFavoriteCategory(sourceId: $0.id, categoryId: id) } ?? false
    case .all: return false
    }
}

/// Rows without hidden channels / categories.
@MainActor
func visibleRows(_ rows: [ChannelRow], sourceId: String?) -> [ChannelRow] {
    guard let sourceId else { return rows }
    let store = HiddenStore.shared
    return rows.filter { !store.isHidden(channelId: $0.channel.id, categoryId: $0.channel.categoryId, sourceId: sourceId) }
}

/// Channel shown in the Live info panel. Its own observable, read only by the panel (and by iPad rows
/// for the selection mark), so a tvOS focus move does not re-render the whole list.
@MainActor
@Observable
final class LiveSelection {
    var channel: Channel?
}

/// Live TV (SCREENS §3.3): a channel LIST (more channels on screen than the old card grid).
/// iPhone portrait: sticky category chips + list. Wide (iPad, iPhone landscape): list + info panel.
/// Apple TV: category column | list | info panel (focus drives the panel, 150 ms debounce).
struct LiveTVView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(Router.self) private var router
    #if !os(tvOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif
    @State private var model: LiveTVViewModel?
    @State private var archiveChannel: Channel?
    @State private var selection = LiveSelection()
    @State private var selectTask: Task<Void, Never>?

    var body: some View {
        Group {
            if let model {
                content(model)
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
            applyLiveCategory()
        }
        .onChange(of: router.liveCategory) { applyLiveCategory() }
        .onChange(of: env.catalogVersion) { model?.reload() }
        .onChange(of: env.libraryVersion) { model?.reloadFavorites() }
        .onChange(of: model?.filter) { selection.channel = nil }
    }

    /// Search → live category (SCREENS §3.6): show that category.
    private func applyLiveCategory() {
        guard let id = router.liveCategory, let model else { return }
        router.liveCategory = nil
        model.filter = .category(id)
    }

    @ViewBuilder
    private func content(_ model: LiveTVViewModel) -> some View {
        #if os(tvOS)
        HStack(alignment: .top, spacing: 30) {
            LiveCategoryColumn(model: model).frame(width: 360)
            list(model, selectFirst: false)
            LivePanel(selection: selection, model: model, onArchive: { archiveChannel = $0 }).frame(width: 500)
        }
        .padding(.leading, Theme.safeH)
        .padding(.trailing, Theme.safeH)
        #else
        VStack(spacing: 0) {
            LiveCategoryChips(model: model)
            GeometryReader { geo in
                let wide = geo.size.width >= 700
                // Select-first only on iPad (regular width); iPhone landscape plays on the first tap.
                let selectFirst = wide && sizeClass == .regular && UIDevice.current.userInterfaceIdiom == .pad
                HStack(alignment: .top, spacing: 16) {
                    list(model, selectFirst: selectFirst)
                        .frame(width: wide ? geo.size.width * 0.55 : geo.size.width)
                    if wide {
                        LivePanel(selection: selection, model: model, onArchive: { archiveChannel = $0 })
                            .padding(.trailing, Theme.safeH).padding(.vertical, 8)
                    }
                }
            }
        }
        #endif
    }

    /// iPad: a tap selects (panel), a tap on the selected row plays. Elsewhere a tap plays.
    private func list(_ model: LiveTVViewModel, selectFirst: Bool) -> some View {
        let sid = env.currentSource?.id
        let rows = visibleRows(model.rows, sourceId: sid)
        let favorites = model.filter == .all ? visibleRows(model.favoriteRows, sourceId: sid) : []
        // "● Watching": the channel playing now, else the last one played from this source (the
        // player is closed while the list is visible on iPhone).
        let last = env.settings.lastSession
        let playing = env.player.currentChannel?.id ?? (last?.sourceId == sid ? last?.channelId : nil)
        let zapAll = model.channels   // once per update, not per row
        return ScrollView {
            if rows.isEmpty && favorites.isEmpty {
                EmptyStateView(icon: model.filter == .favorites ? "star" : "tv",
                               text: L10n.t(model.filter == .favorites ? "favorites_empty" : "live_empty"))
                    .frame(height: 400)
            }
            // Favorites are a plain VStack above the lazy rows: a section inserted at the top of a lazy
            // stack after a ⭐ toggle was not rendered until the view was rebuilt.
            VStack(alignment: .leading, spacing: Theme.isTV ? 12 : 0) {
                if !favorites.isEmpty {
                    sectionHeader(L10n.t("nav_favorites"), icon: "star.fill", id: "live_section_favorites")
                    let zap = favorites.map(\.channel)
                    ForEach(favorites) { row in
                        rowView(row, zap: zap, selectFirst: selectFirst, playing: playing, id: "live_favorite_\(row.channel.id)")
                    }
                    if !rows.isEmpty { sectionHeader(L10n.t("live_all_channels"), icon: nil, id: "live_section_all") }
                }
                LazyVStack(alignment: .leading, spacing: Theme.isTV ? 12 : 0) {
                    ForEach(rows) { row in
                        rowView(row, zap: zapAll, selectFirst: selectFirst, playing: playing, id: "channel_\(row.channel.id)")
                            .onAppear { model.loadMoreIfNeeded(current: row) }
                    }
                }
            }
            .padding(.bottom, Theme.isTV ? 60 : 30)
        }
        #if os(tvOS)
        .scrollClipDisabled()
        .focusSection()
        #endif
        .accessibilityIdentifier("live_list")
    }

    private func rowView(_ row: ChannelRow, zap: [Channel], selectFirst: Bool, playing: String?, id: String) -> some View {
        let channel = row.channel
        let selection = selection
        return LiveChannelRow(row: row, isPlaying: playing == channel.id, selection: selectFirst ? selection : nil,
                              identifier: id,
                              onTap: {
                                  if selectFirst && selection.channel?.id != channel.id { selection.channel = channel } else { router.play(.channel(channel), channels: zap) }
                              },
                              onFocus: { focusSelect(channel) },
                              onArchive: { archiveChannel = channel },
                              onGuide: { router.showInGuide(channel) })
    }

    /// tvOS: the panel follows the focus after 150 ms (fast D-pad runs do not reload it per row).
    private func focusSelect(_ channel: Channel) {
        selectTask?.cancel()
        let selection = selection
        selectTask = Task {
            try? await Task.sleep(for: .milliseconds(150))
            if !Task.isCancelled { selection.channel = channel }
        }
    }

    private func sectionHeader(_ title: String, icon: String?, id: String) -> some View {
        HStack(spacing: Theme.isTV ? 12 : 6) {
            if let icon { Image(systemName: icon).foregroundStyle(Theme.warning) }
            Text(title).font(Theme.isTV ? Theme.caption.weight(.heavy) : .footnote.weight(.heavy)).textCase(.uppercase)
                .foregroundStyle(Theme.textSecondary).lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.isTV ? 4 : Theme.safeH)
        .padding(.top, Theme.isTV ? 16 : 10)
        .padding(.bottom, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.bg)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
        .accessibilityIdentifier(id)
    }
}

/// Info panel of the Live list: the selected / focused channel, else the one playing / played last
/// from this source (iPhone landscape: a tap plays, so the panel follows what was watched), else the
/// first row.
private struct LivePanel: View {
    @Environment(AppEnvironment.self) private var env
    let selection: LiveSelection
    let model: LiveTVViewModel
    let onArchive: (Channel) -> Void

    var body: some View {
        let sid = env.currentSource?.id
        let shown = selection.channel ?? watched(sourceId: sid)
            ?? visibleRows(model.favoriteRows, sourceId: sid).first?.channel
            ?? visibleRows(model.rows, sourceId: sid).first?.channel
        GuidePanel(channel: shown, zapList: model.channels, onArchive: onArchive, liveActions: true, identifier: "live_info_panel")
    }

    /// The channel playing now, else the last one played from this source – if the shown list has it.
    private func watched(sourceId: String?) -> Channel? {
        guard let sourceId else { return nil }
        let last = env.settings.lastSession
        guard let id = env.player.currentChannel?.id ?? (last?.sourceId == sourceId ? last?.channelId : nil) else { return nil }
        return visibleRows(model.favoriteRows + model.rows, sourceId: sourceId).first { $0.channel.id == id }?.channel
    }
}

/// One channel row (~76 pt iOS): number · logo tile · name + quality + ⟲ · NOW (time, title, progress)
/// · NEXT line · ⭐ (iOS; tvOS: one focus target per row, favorite via long OK / player ▲ card).
private struct LiveChannelRow: View {
    @Environment(AppEnvironment.self) private var env
    let row: ChannelRow
    let isPlaying: Bool
    /// iPad select-first: the row reads the selection itself (only then); tvOS rows never do.
    let selection: LiveSelection?
    let identifier: String
    let onTap: () -> Void
    let onFocus: () -> Void
    let onArchive: () -> Void
    let onGuide: () -> Void

    private var channel: Channel { row.channel }
    private var isSelected: Bool { selection?.channel?.id == channel.id }

    var body: some View {
        let target = env.favoriteTarget(channel)
        HStack(spacing: 0) {
            Button(action: onTap) { label(isFavorite: target.map { env.favorites.isFavorite($0.contentKey) } ?? false) }
                #if os(tvOS)
                .buttonStyle(CardButtonStyle(radius: 14, scale: 1.02))
                #else
                .buttonStyle(.plain)
                #endif
                .contextMenu {
                    ChannelMenuItems(channel: channel)
                    if channel.catchup.isAvailable {
                        Button(action: onArchive) { Label(L10n.t("catchup_title"), systemImage: "clock.arrow.circlepath") }
                    }
                    Button(action: onGuide) { Label(L10n.t("live_open_guide"), systemImage: "calendar") }
                }
                .accessibilityLabel(accessibilityText)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
                .accessibilityIdentifier(identifier)
            #if !os(tvOS)
            if let target {
                FavoriteButton(target: target, minTapSize: 44)
                    .foregroundStyle(Theme.textSecondary)
                    .buttonStyle(.plain)
                    .padding(.trailing, Theme.safeH - 6)
            }
            #endif
        }
        .background(isSelected ? Theme.surfaceElevated : Color.clear)
        .overlay(alignment: .leading) {
            if isPlaying { Rectangle().fill(Theme.primary).frame(width: 3) }
        }
        #if !os(tvOS)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.stroke).frame(height: 0.5).padding(.leading, Theme.safeH + 88) }
        #endif
    }

    private var accessibilityText: String {
        var parts = [channel.name]
        if isPlaying { parts.append(L10n.t("live_watching")) }
        if let now = row.nowNext?.now { parts.append(now.title) }
        if let next = row.nowNext?.next { parts.append(L10n.t("live_next_at", env.timeFormatter.time(next.start), next.title)) }
        return parts.joined(separator: ", ")
    }

    private func label(isFavorite: Bool) -> some View {
        let tile: CGFloat = Theme.isTV ? 84 : 48
        let now = row.nowNext?.now
        return RowFocusReporter(onFocus: onFocus) {
            HStack(alignment: .center, spacing: Theme.isTV ? 20 : 12) {
                Text(channel.number.map(String.init) ?? "")
                    .font((Theme.isTV ? Theme.caption : .caption).monospacedDigit())
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: Theme.isTV ? 56 : 28, alignment: .trailing)
                ChannelTile(channel: channel, width: tile, height: tile, radius: Theme.isTV ? 12 : 9)
                VStack(alignment: .leading, spacing: Theme.isTV ? 4 : 2) {
                    HStack(spacing: 6) {
                        Text(channel.name).font(Theme.isTV ? Theme.body.weight(.semibold) : .subheadline.weight(.semibold))
                            .foregroundStyle(Theme.textPrimary).lineLimit(1)
                        if let q = MediaTags.quality(in: channel.name) {
                            Text(q).font(.system(size: Theme.isTV ? 15 : 9, weight: .heavy)).foregroundStyle(Theme.textSecondary)
                                .padding(.horizontal, 4).padding(.vertical, 1)
                                .overlay(RoundedRectangle(cornerRadius: 3).stroke(Theme.textSecondary, lineWidth: 1))
                                .fixedSize()
                        }
                        if channel.catchup.isAvailable {
                            Image(systemName: "clock.arrow.circlepath").font(Theme.isTV ? .system(size: 18) : .caption2).foregroundStyle(Theme.textSecondary)
                                .accessibilityLabel(L10n.t("epg_catchup_available"))   // IOS-18
                        }
                        #if os(tvOS)
                        if isFavorite { Image(systemName: "star.fill").font(.system(size: 18)).foregroundStyle(Theme.warning) }
                        #endif
                        if isPlaying {
                            Text("● " + L10n.t("live_watching")).font(.system(size: Theme.isTV ? 16 : 10, weight: .heavy))
                                .foregroundStyle(Theme.live).lineLimit(1).fixedSize()
                        }
                    }
                    if let now {
                        HStack(spacing: 6) {
                            Text(env.timeFormatter.range(start: now.start, end: now.end))
                                .font((Theme.isTV ? Font.system(size: 20) : .caption2).monospacedDigit()).foregroundStyle(Theme.textSecondary)
                                .lineLimit(1).fixedSize()
                            Text(now.title).font(Theme.isTV ? .system(size: 22, weight: .medium) : .caption.weight(.medium))
                                .foregroundStyle(Theme.textPrimary).lineLimit(1)
                        }
                        ProgressBar(value: EpgSchedule.progress(of: now, at: Date())).frame(maxWidth: Theme.isTV ? 360 : 160).frame(height: Theme.isTV ? 4 : 2.5)
                    } else {
                        LText("epg_no_info").font(Theme.isTV ? .system(size: 20) : .caption).foregroundStyle(Theme.textSecondary).lineLimit(1)
                    }
                    if let next = row.nowNext?.next {
                        Text(L10n.t("live_next_at", env.timeFormatter.time(next.start), next.title))
                            .font(Theme.isTV ? .system(size: 19) : .caption2).foregroundStyle(Theme.textSecondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.leading, Theme.isTV ? 12 : Theme.safeH - 12)
            .padding(.trailing, Theme.isTV ? 16 : 0)
            .padding(.vertical, Theme.isTV ? 12 : 8)
            .frame(minHeight: Theme.isTV ? 108 : 76)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
    }
}

/// Reports focus (tvOS) of the row label to its parent.
private struct RowFocusReporter<Content: View>: View {
    @Environment(\.isFocused) private var isFocused
    let onFocus: () -> Void
    @ViewBuilder var content: () -> Content

    var body: some View {
        content().onChange(of: isFocused) { _, focused in if focused { onFocus() } }
    }
}

/// Chip title: flag + name (+ count).
@MainActor
func chipTitle(_ title: String, count: Int?) -> String {
    let flag = CountryFlag.emoji(for: title).map { "\($0) " } ?? ""
    return flag + CountryFlag.strippedTitle(title) + (count.map { "  \($0)" } ?? "")
}

#if !os(tvOS)
/// iOS: sticky horizontal category chips – ★ Favorites · All · favorite categories (⭐) · the rest,
/// with channel counts. Long press on a category chip: add/remove favorite category; "show hidden".
private struct LiveCategoryChips: View {
    @Environment(AppEnvironment.self) private var env
    @Bindable var model: LiveTVViewModel

    var body: some View {
        let items = chipItems(model, env: env)
        let sid = env.currentSource?.id
        let hiddenCount = sid.map { HiddenStore.shared.count($0) } ?? 0
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                        chip(item, index: index)
                    }
                    if hiddenCount > 0, let sid {
                        Button { HiddenStore.shared.showAll(sourceId: sid); model.reload() } label: {
                            Label(L10n.t("hidden_show_all", String(hiddenCount)), systemImage: "eye")
                                .font(.subheadline.weight(.medium)).foregroundStyle(Theme.textSecondary)
                                .padding(.horizontal, 12).frame(minHeight: 36)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("live_show_hidden")
                    }
                }
                .padding(.horizontal, Theme.safeH)
                .padding(.vertical, 8)
            }
            .onChange(of: model.filter) { _, filter in
                if let index = items.firstIndex(where: { $0.id == filter }) { withAnimation { proxy.scrollTo(index, anchor: .center) } }
            }
        }
        .background(Theme.bg)
        .accessibilityIdentifier("live_category_chips")
    }

    private func chip(_ item: ChipItem, index: Int) -> some View {
        let selected = model.filter == item.id
        return Button { model.filter = item.id } label: {
            HStack(spacing: 5) {
                if item.starred { Image(systemName: "star.fill").font(.caption.weight(.bold)).foregroundStyle(selected ? Color.black : Theme.warning) }
                Text(item.title).lineLimit(1)
            }
            .font(.subheadline.weight(selected ? .semibold : .medium))
            .foregroundStyle(selected ? Color.black : Theme.textPrimary)
            .padding(.horizontal, 14).frame(minHeight: 36)
            .background(Capsule().fill(selected ? Color.white : Theme.surface))
            .overlay(Capsule().stroke(selected ? Color.clear : Theme.stroke, lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .contextMenu { CategoryFavoriteMenuItem(filter: item.id) }
        .id(index)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("live_chip_\(index)")
    }
}
#endif

#if os(tvOS)
/// tvOS: categories as a left column (vertical list with counts); OK selects, long OK = ⭐ category.
private struct LiveCategoryColumn: View {
    @Environment(AppEnvironment.self) private var env
    @Bindable var model: LiveTVViewModel

    var body: some View {
        let items = chipItems(model, env: env)
        let hiddenCount = env.currentSource.map { HiddenStore.shared.count($0.id) } ?? 0
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    let selected = model.filter == item.id
                    Button { model.filter = item.id } label: {
                        HStack(spacing: 10) {
                            if item.starred { Image(systemName: "star.fill").font(.system(size: 20)).foregroundStyle(Theme.warning) }
                            Text(item.title).lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .font(Theme.caption.weight(selected ? .bold : .medium))
                        .foregroundStyle(selected ? Theme.textPrimary : Theme.textSecondary)
                        .padding(.horizontal, 20).padding(.vertical, 14)
                        .background(RoundedRectangle(cornerRadius: 12).fill(selected ? Theme.surfaceElevated : Color.clear))
                    }
                    .buttonStyle(CardButtonStyle(radius: 12, scale: 1.03))
                    .contextMenu { CategoryFavoriteMenuItem(filter: item.id) }
                    .accessibilityAddTraits(selected ? .isSelected : [])
                    .accessibilityIdentifier("live_chip_\(index)")
                }
                // Last row: bring hidden channels / categories back (long OK on a row hides them).
                if hiddenCount > 0, let sid = env.currentSource?.id {
                    Button { HiddenStore.shared.showAll(sourceId: sid); model.reload() } label: {
                        Label(L10n.t("hidden_show_all", String(hiddenCount)), systemImage: "eye")
                            .font(Theme.caption.weight(.medium)).foregroundStyle(Theme.textSecondary)
                            .padding(.horizontal, 20).padding(.vertical, 14)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(CardButtonStyle(radius: 12, scale: 1.03))
                    .accessibilityIdentifier("live_show_hidden")
                }
            }
            .padding(.vertical, 20)
        }
        .scrollClipDisabled()
        .tvTopClipped()
        .focusSection()
        .accessibilityIdentifier("live_category_chips")
    }
}
#endif

private struct ChipItem {
    let id: ChannelFilter
    let title: String
    let starred: Bool
}

/// ★ Favorites · All · favorite categories · other categories (hidden ones removed), with counts.
@MainActor
private func chipItems(_ model: LiveTVViewModel, env: AppEnvironment) -> [ChipItem] {
    let items = channelFilters(model, env: env).map { item in
        switch item.id {
        case .favorites: return ChipItem(id: .favorites, title: chipTitle(item.title, count: model.favoriteCount), starred: true)
        case .all: return ChipItem(id: .all, title: chipTitle(item.title, count: model.allCount), starred: false)
        case .category(let id):
            return ChipItem(id: item.id, title: chipTitle(item.title, count: model.categoryCounts[id]), starred: isStarred(item.id, env: env))
        }
    }
    return items.filter { $0.id == .favorites } + items.filter { $0.id != .favorites }
}

/// Long press on a category chip: ⭐ add/remove the category (per source, this device only).
private struct CategoryFavoriteMenuItem: View {
    @Environment(AppEnvironment.self) private var env
    let filter: ChannelFilter

    var body: some View {
        if case .category(let categoryId) = filter, let sid = env.currentSource?.id {
            let on = env.favorites.isFavoriteCategory(sourceId: sid, categoryId: categoryId)
            Button { env.favorites.toggleCategory(sourceId: sid, categoryId: categoryId) } label: {
                Label(L10n.t(on ? "fav_category_remove" : "fav_category_add"), systemImage: on ? "star.slash" : "star")
            }
        }
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
    /// Row the EPG list scrolls to ("Show in TV guide").
    @State private var scrollTarget: String?

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
                                    onSelect: showsPanel ? { selected = $0 } : nil, scrollTarget: scrollTarget) { model.loadMoreIfNeeded(current: $0) }
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
            applyFocusRequest()
        }
        .onChange(of: router.guideFocus?.id) { applyFocusRequest() }
        .onChange(of: env.catalogVersion) { model?.reload() }
        .onChange(of: env.libraryVersion) { model?.reloadFavorites() }
    }

    /// Live → "Show in TV guide": the channel's category (or All), its row loaded, scrolled to and in the panel.
    private func applyFocusRequest() {
        guard let channel = router.guideFocus, let model else { return }
        router.guideFocus = nil
        let filter = channel.categoryId.map(ChannelFilter.category) ?? .all
        if model.filter != filter { model.filter = filter }
        if !model.reveal(channelId: channel.id), filter != .all {
            model.filter = .all
            model.reveal(channelId: channel.id)
        }
        selected = channel
        scrollTarget = nil
        Task { @MainActor in scrollTarget = channel.id }   // after the rows are laid out
    }
}

/// Side panel: "Now on air" + "Today" upcoming programmes of the selected channel.
private struct GuidePanel: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(Router.self) private var router
    let channel: Channel?
    let zapList: [Channel]
    let onArchive: (Channel) -> Void
    /// Live list panel: ▶ Play · ⭐ · Guide · ⟲ (iOS; tvOS keeps one focus target per list row).
    var liveActions = false
    var identifier = "guide_panel"

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
                            .accessibilityIdentifier(liveActions ? "live_panel_play" : "guide_play")
                        if liveActions, let target = env.favoriteTarget(channel) {
                            FavoriteButton(target: target).buttonStyle(RoundIconButtonStyle(size: 40))
                        }
                        if liveActions {
                            Button { router.section = .guide } label: { Image(systemName: "calendar") }
                                .buttonStyle(RoundIconButtonStyle(size: 40))
                                .accessibilityLabel(L10n.t("live_open_guide"))
                                .accessibilityIdentifier("live_panel_guide")
                        }
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
        .accessibilityIdentifier(identifier)
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

    /// Xtream timeshift URL (CONTRACT §4); `nil` for M3U sources ("" = replay possible, no programme given).
    private func replayURL(for p: EpgProgram?) -> String? {
        guard case .xtream? = env.secrets(for: channel.sourceId) else { return nil }
        guard let p else { return "" }
        return env.catchupURL(channel: channel, program: p)
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
    /// Channel id to scroll to (set → scrolls once).
    var scrollTarget: String? = nil
    var onRowAppear: (ChannelRow) -> Void = { _ in }
    @State private var scrollX: CGFloat = 0
    @State private var now = Date()
    @State private var timeline = EpgTimeline(now: Date(), tileWidth: EpgMetrics.tileWidth, pointsPerMinute: EpgMetrics.pointsPerMinute)

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                timeAxis
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: !Theme.isTV) {
                        LazyVStack(alignment: .leading, spacing: EpgMetrics.rowSpacing) {
                            ForEach(rows) { row in
                                EpgRowView(row: row, zapList: zapList, timeline: timeline, scrollX: scrollX, now: now, onSelect: onSelect)
                                    .id(row.id)
                                    .onAppear { onRowAppear(row) }
                            }
                        }
                        .padding(.top, 4)
                        .padding(.bottom, Theme.isTV ? 60 : 24)
                    }
                    .onChange(of: scrollTarget) { _, id in if let id { proxy.scrollTo(id, anchor: .center) } }
                    .onAppear { if let scrollTarget { proxy.scrollTo(scrollTarget, anchor: .center) } }
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
                    if channel.catchup.isAvailable {
                        Image(systemName: "clock.arrow.circlepath").foregroundStyle(.white).accessibilityLabel(L10n.t("epg_catchup_available"))
                    }
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
