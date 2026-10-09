import IPTVKit
import SwiftUI

/// "Added to favorites · Undo" capsule (spec §2): shown while `favorites.pendingUndo` is set
/// (4 s after a ⭐ toggle), announced to VoiceOver. Inserted/removed – never kept at opacity 0
/// (iOS 26 hit testing, see PlayerView).
struct UndoToast: View {
    @Environment(AppEnvironment.self) private var env
    /// tvOS player: lets the info card move the focus to "Undo" (▼ from ⭐).
    var undoFocus: FocusState<Bool>.Binding?

    var body: some View {
        ZStack {
            if let pending = env.favorites.pendingUndo {
                let on = env.favorites.isFavorite(pending.contentKey)
                toast(title: pending.title, on: on)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .onAppear { announce(on) }
                    .onChange(of: "\(pending.contentKey)|\(on)") { announce(on) }
            }
        }
        .animation(.easeOut(duration: 0.2), value: env.favorites.pendingUndo)
    }

    private func toast(title: String, on: Bool) -> some View {
        HStack(spacing: Theme.isTV ? 24 : 12) {
            Image(systemName: on ? "star.fill" : "star.slash").foregroundStyle(Theme.warning)
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.t(on ? "fav_added" : "fav_removed")).font((Theme.isTV ? Theme.caption : .subheadline).weight(.semibold))
                Text(title).font(Theme.isTV ? .system(size: 20) : .caption).foregroundStyle(Theme.textSecondary).lineLimit(1)
            }
            .foregroundStyle(Theme.textPrimary)
            Spacer(minLength: Theme.isTV ? 24 : 8)
            Button(L10n.t("action_undo")) { env.favorites.undo() }
                #if os(tvOS)
                .buttonStyle(SecondaryButtonStyle())
                .modifier(OptionalFocus(binding: undoFocus))
                #else
                .font(.subheadline.weight(.bold))
                .foregroundStyle(Theme.primary)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
                #endif
                .accessibilityIdentifier("action_undo")
        }
        .padding(.leading, Theme.isTV ? 32 : 18)
        .padding(.trailing, Theme.isTV ? 16 : 8)
        .padding(.vertical, Theme.isTV ? 12 : 4)
        .background(Capsule().fill(Theme.surfaceElevated.opacity(0.97)))
        .overlay(Capsule().stroke(Theme.stroke, lineWidth: 1))
        .shadow(color: .black.opacity(0.5), radius: 12, y: 4)
        .frame(maxWidth: Theme.isTV ? 760 : 480)
        .padding(.horizontal, Theme.safeH)
        #if os(tvOS)
        .focusSection()
        #endif
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("undo_toast")
    }

    private func announce(_ on: Bool) {
        AccessibilityNotification.Announcement(L10n.t(on ? "fav_added" : "fav_removed")).post()
    }
}

/// `.focused(binding)` when a binding is given.
private struct OptionalFocus: ViewModifier {
    let binding: FocusState<Bool>.Binding?

    func body(content: Content) -> some View {
        if let binding { content.focused(binding) } else { content }
    }
}

/// "Reloading catalog…" capsule while sources restored from the durable mirror reload after the system deleted
/// the catalog database (tvOS purgeable storage, ARCHITECTURE §3.3). Informational only: nothing focusable or
/// tappable, inserted/removed (never at opacity 0).
struct CatalogRestoreNotice: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        ZStack {
            if env.isRestoringCatalog {
                HStack(spacing: Theme.isTV ? 20 : 10) {
                    ProgressView()
                    Text(L10n.t("catalog_restoring"))
                        .font((Theme.isTV ? Theme.caption : .subheadline).weight(.semibold))
                        .foregroundStyle(Theme.textPrimary)
                }
                .padding(.horizontal, Theme.isTV ? 32 : 18)
                .padding(.vertical, Theme.isTV ? 16 : 10)
                .background(Capsule().fill(Theme.surfaceElevated.opacity(0.97)))
                .overlay(Capsule().stroke(Theme.stroke, lineWidth: 1))
                .shadow(color: .black.opacity(0.5), radius: 12, y: 4)
                .padding(.horizontal, Theme.safeH)
                .allowsHitTesting(false)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("catalog_restoring")
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.2), value: env.isRestoringCatalog)
    }
}
