import IPTVKit
import SwiftUI

/// Settings → "iCloud" (Build 17, SCREENS §3.9): the sync switch and its status. One focusable row on tvOS (the
/// toggle); status and privacy note are the section footer.
struct ICloudSyncSection: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        #if os(tvOS)
        // tvOS lists show no section footers: the status is the switch's second line, the note its own row.
        Section {
            Toggle(isOn: Binding(get: { env.cloud.isEnabled }, set: { env.cloud.setEnabled($0) })) {
                VStack(alignment: .leading, spacing: 4) {
                    Label(L10n.t("icloud_sync_toggle"), systemImage: "icloud")
                    Text(Self.statusText(env.cloud)).font(Theme.caption).foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("settings_icloud_status")
                }
            }
            .accessibilityIdentifier("settings_icloud_sync")
            Text(L10n.t("icloud_hint")).font(Theme.caption).foregroundStyle(Theme.textSecondary).tvFocusableRow()
        } header: {
            Text(L10n.t("icloud_section"))
        }
        #else
        Section {
            Toggle(isOn: Binding(get: { env.cloud.isEnabled }, set: { env.cloud.setEnabled($0) })) {
                Label(L10n.t("icloud_sync_toggle"), systemImage: "icloud")
            }
            .accessibilityIdentifier("settings_icloud_sync")
        } header: {
            Text(L10n.t("icloud_section"))
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                Text(Self.statusText(env.cloud))
                    .accessibilityIdentifier("settings_icloud_status")
                Text(L10n.t("icloud_hint"))
            }
        }
        #endif
    }

    static func statusText(_ cloud: CloudSync) -> String {
        switch cloud.status {
        case .off: return L10n.t("icloud_status_off")
        case .noAccount: return L10n.t("icloud_status_no_account")
        case .syncing: return L10n.t("icloud_status_syncing")
        case .storageFull: return L10n.t("icloud_status_storage_full")
        case .upToDate:
            guard let at = cloud.lastSyncedAt else { return L10n.t("icloud_status_on") }
            return L10n.t("icloud_status_synced", L10n.date(at, date: .omitted, time: .shortened))
        }
    }
}

/// Source row / detail: a source from another device whose login details have not arrived through iCloud Keychain
/// yet – a neutral waiting state, never an error.
struct SourceWaitingForKeychainLabel: View {
    var body: some View {
        Label(L10n.t("source_waiting_keychain"), systemImage: "key.icloud")
            .font(.caption2)
            .foregroundStyle(Theme.textSecondary)
            .accessibilityIdentifier("source_waiting_keychain")
    }
}
