import IPTVCore
import IPTVKit
import SwiftUI

/// One-tap ⭐ (spec §2, SCREENS §2 "Favori"): flips immediately (optimistic, no confirmation) and
/// offers a 4 s undo (`UndoToast`). The look comes from the caller's `.buttonStyle`; on tvOS it is
/// an ordinary focusable button (card / round / secondary styles).
struct FavoriteButton: View {
    enum Style {
        /// ☆ / ★ glyph only.
        case icon
        /// Glyph + "Favorite" (hero, player info card).
        case labeled
        /// Glyph over a small caption (iOS hero).
        case stacked
    }

    @Environment(AppEnvironment.self) private var env
    let target: FavoriteTarget
    var style: Style = .icon
    /// Minimum touch target of the `.icon` glyph (iOS: 44 pt in cards, 36 pt in the player tools).
    var minTapSize: CGFloat = 0

    var body: some View {
        let on = env.favorites.isFavorite(target.contentKey)
        Button { env.favorites.toggle(target) } label: { label(on) }
            .accessibilityLabel(L10n.t(on ? "action_remove_favorite" : "action_add_favorite"))
            .accessibilityValue(target.title)
            .accessibilityAddTraits(on ? .isSelected : [])
            .accessibilityIdentifier("fav_\(target.contentKey)")
            #if os(iOS)
            .sensoryFeedback(.selection, trigger: on)
            #endif
    }

    @ViewBuilder
    private func label(_ on: Bool) -> some View {
        switch style {
        case .icon:
            glyph(on)
                .frame(minWidth: minTapSize, minHeight: minTapSize)
                .contentShape(Rectangle())
        case .labeled:
            Label { Text(L10n.t("action_favorite_short")) } icon: { glyph(on) }
        case .stacked:
            VStack(spacing: 4) {
                glyph(on).font(.title3)
                Text(L10n.t("action_favorite_short")).font(.caption2.weight(.medium)).lineLimit(1)
            }
            .foregroundStyle(.white)
            .frame(minWidth: 64, minHeight: 44)
            .contentShape(Rectangle())
        }
    }

    @ViewBuilder
    private func glyph(_ on: Bool) -> some View {
        if on {
            Image(systemName: "star.fill").foregroundStyle(Theme.warning)
        } else {
            Image(systemName: "star")
        }
    }
}

extension AppEnvironment {
    func favoriteTarget(_ channel: Channel) -> FavoriteTarget? {
        favoriteTarget(sourceId: channel.sourceId, kind: .live, itemId: channel.id, title: channel.name, posterUrl: channel.logoUrl)
    }

    func favoriteTarget(_ movie: Movie) -> FavoriteTarget? {
        favoriteTarget(sourceId: movie.sourceId, kind: .movie, itemId: movie.id, title: movie.name, posterUrl: movie.posterUrl)
    }

    func favoriteTarget(_ series: Series) -> FavoriteTarget? {
        favoriteTarget(sourceId: series.sourceId, kind: .series, itemId: series.id, title: series.name, posterUrl: series.posterUrl)
    }

    func favoriteTarget(_ item: CatalogItem) -> FavoriteTarget? {
        switch item {
        case .movie(let m): return favoriteTarget(m)
        case .series(let s): return favoriteTarget(s)
        }
    }
}

#if os(iOS)
/// Small round ⭐ in a poster's corner: 30 pt glyph disc, 44 pt touch target.
struct FavoriteBadgeButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 30, height: 30)
            .background(Circle().fill(.black.opacity(0.55)))
            .overlay(Circle().stroke(.white.opacity(0.25), lineWidth: 1))
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}
#endif

/// Long-press menu item "Add to / Remove from favorites" – always the first item of card menus.
struct FavoriteMenuItem: View {
    @Environment(AppEnvironment.self) private var env
    let target: FavoriteTarget

    var body: some View {
        let on = env.favorites.isFavorite(target.contentKey)
        Button { env.favorites.toggle(target) } label: {
            Label(L10n.t(on ? "action_remove_favorite" : "action_add_favorite"), systemImage: on ? "star.slash" : "star")
        }
    }
}

/// A poster link with the iOS corner ⭐ and the long-press favorite menu (SCREENS §3.2, §3.6).
struct FavoritePosterLink<Value: Hashable, Label: View>: View {
    @Environment(AppEnvironment.self) private var env
    let value: Value
    let target: FavoriteTarget?
    /// Id of the link itself (the corner ⭐ keeps `fav_<contentKey>`).
    let identifier: String
    @ViewBuilder var label: () -> Label

    var body: some View {
        NavigationLink(value: value, label: label)
            .buttonStyle(ArtworkButtonStyle())
            .contextMenu { if let target { FavoriteMenuItem(target: target) } }
            .accessibilityIdentifier(identifier)
            #if os(iOS)
            .overlay(alignment: .topTrailing) {
                if let target {
                    FavoriteButton(target: target).buttonStyle(FavoriteBadgeButtonStyle())
                }
            }
            #endif
    }
}
