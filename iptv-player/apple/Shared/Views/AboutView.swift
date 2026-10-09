import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Settings → About (SCREENS §3.9): app icon, name, version/build, the maker (Hasi Elektronic) and the
/// open-source licences. tvOS: one focusable control per row, the list scrolls with the focus; no links
/// (tvOS has no browser / mail app).
struct AboutView: View {
    /// Hasi blue – only for the maker block (brand of the developer, not the app theme).
    static let hasiBlue = Color(red: 0x3A / 255, green: 0xBA / 255, blue: 0xDF / 255)
    static let website = "hasi-elektronic.de"
    static let email = "info@hasi-elektronic.de"

    private var displayName: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String) ?? "NovaPlayer"
    }

    private var versionText: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "–"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "–"
        return L10n.t("about_version_build", version, build)
    }

    var body: some View {
        Form {
            Section {
                HStack(spacing: Theme.isTV ? 32 : 16) {
                    AppIconImage().frame(width: Theme.isTV ? 120 : 64, height: Theme.isTV ? 120 : 64)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(verbatim: displayName).font(Theme.body.weight(.bold)).foregroundStyle(Theme.textPrimary)
                            .accessibilityIdentifier("about_app_name")
                        Text(verbatim: versionText).font(Theme.caption).foregroundStyle(Theme.textSecondary)
                            .accessibilityIdentifier("about_version")
                    }
                }
                .padding(.vertical, 6)
                .accessibilityElement(children: .combine)
                .tvFocusableRow()
            }

            Section(L10n.t("about_developed_by")) {
                VStack(alignment: .leading, spacing: Theme.isTV ? 12 : 6) {
                    Image("HasiLogo")
                        .resizable()
                        .scaledToFit()
                        .frame(width: Theme.isTV ? 360 : 200)
                        .accessibilityLabel(Text(verbatim: "Hasi Elektronic"))
                        .accessibilityIdentifier("about_logo")
                    Text(verbatim: "Hamdi Güncavdı").font(Theme.body.weight(.bold)).foregroundStyle(Self.hasiBlue)
                        .accessibilityIdentifier("about_maker")
                    Text(verbatim: "Hasi Elektronic").font(Theme.body).foregroundStyle(Theme.textPrimary)
                    Text(verbatim: "Grabenstraße 18, 71665 Vaihingen/Enz").font(Theme.caption).foregroundStyle(Theme.textSecondary)
                }
                .padding(.vertical, 6)
                .accessibilityElement(children: .contain)
                .tvFocusableRow()
                #if os(tvOS)
                LabeledContent(L10n.t("about_website")) { Text(verbatim: Self.website).foregroundStyle(Self.hasiBlue) }
                    .focusable()
                LabeledContent(L10n.t("about_email")) { Text(verbatim: Self.email).foregroundStyle(Self.hasiBlue) }
                    .focusable()
                #else
                if let url = URL(string: "https://\(Self.website)") {
                    Link(destination: url) {
                        LabeledContent(L10n.t("about_website")) { Text(verbatim: Self.website).foregroundStyle(Self.hasiBlue) }
                    }
                    .accessibilityIdentifier("about_website")
                }
                if let url = URL(string: "mailto:\(Self.email)") {
                    Link(destination: url) {
                        LabeledContent(L10n.t("about_email")) { Text(verbatim: Self.email).foregroundStyle(Self.hasiBlue) }
                    }
                    .accessibilityIdentifier("about_email")
                }
                #endif
            }

            Section {
                LegalLinksRows()
            } footer: {
                Text(L10n.t("about_privacy_icloud"))   // Build 17: where synced data lives
                    .accessibilityIdentifier("about_privacy_icloud")
            }

            Section {
                NavigationLink(value: SettingsRoute.licenses) {
                    VStack(alignment: .leading, spacing: 4) {
                        LText("about_licenses")
                        Text(verbatim: "VLCKit / libVLC – LGPL-2.1").font(Theme.caption).foregroundStyle(Theme.textSecondary)
                    }
                }
                .accessibilityIdentifier("about_licenses")
            } footer: {
                Text(verbatim: "© 2026 Hasi Elektronic")
            }
        }
        .hiddenListBackground()
        .screenBackground()
        .navigationTitle(L10n.t("about_title"))
    }
}

/// The app's own icon from the bundle (iOS: `CFBundleIcons`; tvOS layered icons are not loadable as an image →
/// the app mark).
private struct AppIconImage: View {
    var body: some View {
        #if canImport(UIKit)
        if let image = Self.icon {
            Image(uiImage: image).resizable().scaledToFit()
                .clipShape(RoundedRectangle(cornerRadius: Theme.isTV ? 24 : 14, style: .continuous))
                .accessibilityHidden(true)
        } else {
            mark
        }
        #else
        mark
        #endif
    }

    private var mark: some View {
        RoundedRectangle(cornerRadius: Theme.isTV ? 24 : 14, style: .continuous)
            .fill(Theme.surfaceElevated)
            .overlay(Image(systemName: "play.tv.fill").font(.system(size: Theme.isTV ? 56 : 30, weight: .bold))
                .foregroundStyle(Theme.premiumGradient))
            .accessibilityHidden(true)
    }

    #if canImport(UIKit)
    private static let icon: UIImage? = {
        guard let icons = Bundle.main.object(forInfoDictionaryKey: "CFBundleIcons") as? [String: Any],
              let primary = icons["CFBundlePrimaryIcon"] as? [String: Any] else { return nil }
        if let files = primary["CFBundleIconFiles"] as? [String], let name = files.last, let image = UIImage(named: name) { return image }
        if let name = primary["CFBundleIconName"] as? String { return UIImage(named: name) }
        return nil
    }()
    #endif
}
