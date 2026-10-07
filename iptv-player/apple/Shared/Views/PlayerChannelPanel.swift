import IPTVCore
import IPTVKit
import SwiftUI

/// In-player channel panel (SCREENS §3.7): category picker on top, favorites first, rows with logo +
/// name + the programme on air. A row zaps through the player's zap path – playback continues behind
/// the panel, and the shown list becomes the zap list (▲▼ / swipes continue in it).
/// Layout: leading side – iOS landscape 40 % of the width, iOS portrait the full screen (sheet-like),
/// tvOS 600 pt. Opens on the playing channel's category, scrolled (tvOS: focused) to that channel.
struct PlayerChannelPanel: View {
    @Environment(AppEnvironment.self) private var env
    let player: PlayerController
    let onClose: () -> Void
    @State private var model: LiveTVViewModel?
    private static let topId = "panel_top"
    /// Channel to scroll to / focus (the playing one on open, nil after the category changes).
    @State private var anchorId: String?
    #if os(tvOS)
    @FocusState private var focusedRow: String?
    @FocusState private var categoryFocused: Bool
    /// First row shown (▲ from it moves to the category picker).
    @State private var firstRowId: String?
    #endif

    var body: some View {
        GeometryReader { geo in
            let width = panelWidth(geo.size)
            HStack(spacing: 0) {
                panel
                    .frame(width: width)
                    .frame(maxHeight: .infinity)
                    .background(Theme.surface.opacity(0.96).ignoresSafeArea())
                    #if os(iOS)
                    .simultaneousGesture(DragGesture(minimumDistance: 30).onEnded { value in
                        // Swipe back to the left edge closes (mirror of the left-edge swipe that opens it).
                        if value.translation.width < -60, abs(value.translation.width) > abs(value.translation.height) { onClose() }
                    })
                    #endif
                #if os(iOS)
                // The picture beside the panel: a tap there closes the panel.
                Color.black.opacity(0.001)
                    .contentShape(Rectangle())
                    .onTapGesture { onClose() }
                    .accessibilityHidden(true)
                #else
                Spacer(minLength: 0)
                #endif
            }
        }
        .transition(.move(edge: .leading).combined(with: .opacity))
        .onAppear(perform: load)
        .onChange(of: env.libraryVersion) { model?.reloadFavorites() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("player_channel_panel")
    }

    private func panelWidth(_ size: CGSize) -> CGFloat {
        #if os(tvOS)
        600
        #else
        size.width > size.height ? max(300, size.width * 0.4) : size.width
        #endif
    }

    @ViewBuilder
    private var panel: some View {
        VStack(alignment: .leading, spacing: Theme.isTV ? 20 : 8) {
            header
            if let model {
                list(model)
            } else {
                Spacer()
            }
        }
        .padding(.top, Theme.isTV ? Theme.safeV : 8)
        #if os(tvOS)
        .focusSection()
        #endif
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text(L10n.t("player_channels")).font(Theme.headline).foregroundStyle(.white)
            Spacer(minLength: 8)
            if let model { categoryMenu(model) }
            #if os(iOS)
            Button(action: onClose) {
                Image(systemName: "xmark").font(.body.weight(.semibold)).foregroundStyle(.white)
                    .frame(width: 44, height: 44).contentShape(Rectangle())
            }
            .accessibilityLabel(L10n.t("action_close"))
            .accessibilityIdentifier("player_channel_panel_close")
            #endif
        }
        .padding(.horizontal, Theme.isTV ? 40 : Theme.safeH)
    }

    /// Category picker: All · ★ Favorites · favorite categories · the rest (hidden ones removed).
    private func categoryMenu(_ model: LiveTVViewModel) -> some View {
        let filters = channelFilters(model, env: env)
        let current = filters.first { $0.id == model.filter }?.title ?? L10n.t("all")
        return Menu {
            Picker(L10n.t("category_picker"), selection: Binding(get: { model.filter }, set: { filter in
                anchorId = nil
                model.filter = filter
            })) {
                ForEach(filters, id: \.id) { item in
                    let starred = isStarred(item.id, env: env)
                    Label(chipTitle(item.title, count: nil), systemImage: starred ? "star.fill" : "").tag(item.id)
                }
            }
        } label: {
            HStack(spacing: 6) {
                Text(chipTitle(current, count: nil)).lineLimit(1)
                Image(systemName: "chevron.down").font(.caption.weight(.bold))
            }
            .font(Theme.isTV ? Theme.caption.weight(.semibold) : .subheadline.weight(.semibold))
            .foregroundStyle(Theme.textPrimary)
            .padding(.horizontal, Theme.isTV ? 24 : 12)
            .frame(minHeight: Theme.isTV ? 60 : 36)
            .background(Capsule().fill(Theme.surfaceElevated))
            .contentShape(Capsule())
        }
        .buttonStyle(.borderless)   // no tinted platter; the capsule is the control
        #if os(tvOS)
        // The player's focus handling does not move between the header and the list by itself.
        .focused($categoryFocused)
        .onMoveCommand { direction in
            if direction == .down, let firstRowId { focusedRow = firstRowId }
        }
        #endif
        .accessibilityLabel(L10n.t("category_picker"))
        .accessibilityValue(chipTitle(current, count: nil))
        .accessibilityIdentifier("player_channel_category")
    }

    /// Favorites first: "All" → the favorites section, then every other channel; a category / the
    /// favorites filter → its favorite channels on top of the loaded rows.
    private func orderedRows(_ model: LiveTVViewModel) -> [ChannelRow] {
        let sid = env.currentSource?.id
        let rows = visibleRows(model.rows, sourceId: sid)
        if model.filter == .all {
            let favorites = visibleRows(model.favoriteRows, sourceId: sid)
            let ids = Set(favorites.map(\.id))
            return favorites + rows.filter { !ids.contains($0.id) }
        }
        let isFavorite: (ChannelRow) -> Bool = { row in env.favoriteTarget(row.channel).map { env.favorites.isFavorite($0.contentKey) } ?? false }
        return rows.filter(isFavorite) + rows.filter { !isFavorite($0) }
    }

    private func list(_ model: LiveTVViewModel) -> some View {
        let rows = orderedRows(model)
        let zapList = rows.map(\.channel)
        let playingId = player.currentChannel?.id
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: Theme.isTV ? 8 : 2) {
                    Color.clear.frame(height: 0).id(Self.topId)
                    if rows.isEmpty {
                        LText(model.filter == .favorites ? "favorites_empty" : "live_empty")
                            .font(Theme.caption).foregroundStyle(Theme.textSecondary)
                            .padding(Theme.isTV ? 40 : 20)
                    }
                    ForEach(rows) { row in
                        rowButton(row, playing: row.id == playingId, zapList: zapList)
                            .id(row.id)
                            .onAppear { model.loadMoreIfNeeded(current: row) }
                    }
                }
                .padding(.horizontal, Theme.isTV ? 40 : 8)
                .padding(.bottom, Theme.isTV ? 60 : 24)
            }
            #if os(tvOS)
            .scrollClipDisabled()
            .defaultFocus($focusedRow, anchorId ?? rows.first?.id)
            .onMoveCommand { direction in
                if direction == .up, focusedRow != nil, focusedRow == rows.first?.id { categoryFocused = true }
            }
            .onChange(of: rows.first?.id, initial: true) { _, id in firstRowId = id }
            #endif
            .onAppear { scrollToAnchor(proxy) }
            .onChange(of: model.filter) { proxy.scrollTo(Self.topId, anchor: .top) }
        }
    }

    private func scrollToAnchor(_ proxy: ScrollViewProxy) {
        guard let anchorId else { return }
        Task { @MainActor in
            proxy.scrollTo(anchorId, anchor: .center)
            #if os(tvOS)
            focusedRow = anchorId
            #endif
        }
    }

    private func rowButton(_ row: ChannelRow, playing: Bool, zapList: [Channel]) -> some View {
        let channel = row.channel
        let favorite = env.favoriteTarget(channel).map { env.favorites.isFavorite($0.contentKey) } ?? false
        return Button {
            if !playing { player.zap(to: channel, channels: zapList) }
            onClose()
        } label: {
            HStack(spacing: Theme.isTV ? 20 : 10) {
                Text(channel.number.map(String.init) ?? "")
                    .font(Theme.caption.monospacedDigit())
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: Theme.isTV ? 64 : 34, alignment: .trailing)
                ChannelLogo(url: channel.logoUrl, width: Theme.isTV ? 96 : 52)
                VStack(alignment: .leading, spacing: Theme.isTV ? 4 : 2) {
                    HStack(spacing: 6) {
                        if playing { Image(systemName: "speaker.wave.2.fill").font(.caption).foregroundStyle(Theme.primary) }
                        Text(channel.name)
                            .font(Theme.isTV ? Theme.body.weight(.semibold) : .subheadline.weight(.semibold))
                            .foregroundStyle(playing ? Theme.primary : .white)
                            .lineLimit(1)
                    }
                    if let now = row.nowNext?.now {
                        Text(now.title).font(Theme.isTV ? Theme.caption : .caption).foregroundStyle(Theme.textSecondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
                if favorite {
                    Image(systemName: "star.fill").font(Theme.isTV ? Theme.caption : .caption).foregroundStyle(Theme.warning)
                        .accessibilityHidden(true)
                }
            }
            .padding(.vertical, Theme.isTV ? 10 : 6)
            .padding(.horizontal, Theme.isTV ? 16 : 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Theme.cardRadius).fill(playing ? Theme.primary.opacity(0.14) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(CardButtonStyle(scale: 1.03))
        #if os(tvOS)
        .focused($focusedRow, equals: channel.id)
        #endif
        .accessibilityIdentifier("panel_channel_\(channel.id)")
        .accessibilityAddTraits(playing ? .isSelected : [])
    }

    /// Opens on the playing channel's category (else "All") with that channel loaded.
    private func load() {
        guard model == nil else { return }
        let m = LiveTVViewModel(env: env)
        m.showsFavoriteSections = true
        let current = player.currentChannel
        let hidden = env.currentSource.map { HiddenStore.shared.hiddenCategories($0.id) } ?? []
        if let categoryId = current?.categoryId, !hidden.contains(categoryId) {
            m.filter = .category(categoryId)   // loads
        } else {
            m.reload()
        }
        if let current, m.filter != .favorites {
            // Bounded: a channel deep in a huge "All" list is not paged in (open ≤ 100 ms budget).
            if m.reveal(channelId: current.id, maxRows: 600) || m.favoriteRows.contains(where: { $0.id == current.id }) {
                anchorId = current.id
            }
        }
        model = m
    }
}
