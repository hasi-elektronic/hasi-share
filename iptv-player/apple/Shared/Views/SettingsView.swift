import IPTVCore
import IPTVKit
import SwiftUI

enum SettingsRoute: Hashable {
    case sources
    case advanced
    case source(String)
    case edit(String)
    case add(AddSourceRoute)
    case account
    case formatTest
    case paywall
    case licenses
    case about
    /// Build 16: "Calibrate audio sync" (VLC calibration test clip).
    case avSyncCalibration
}

/// Settings (SCREENS §3.9) – always reachable, also when locked. Top level: only what users change
/// (sources, languages, quick start, TV/soundbar audio delay); everything else under "Advanced".
struct SettingsView: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        @Bindable var settings = env.settings
        Form {
            Section {
                NavigationLink(value: SettingsRoute.sources) {
                    HStack {
                        Label(L10n.t("settings_sources"), systemImage: "antenna.radiowaves.left.and.right")
                        Spacer()
                        Text(verbatim: String(env.sources.count)).foregroundStyle(Theme.textSecondary)
                    }
                }
                .accessibilityIdentifier("settings_sources")
                // Switching re-renders the whole app in the new language (root views are keyed by it).
                Picker(L10n.t("pref_app_language"), selection: Binding(get: { settings.appLanguage }, set: { code in
                    L10n.setLanguage(code)
                    settings.appLanguage = code
                    env.applyLanguagePreferences()
                })) {
                    Text(L10n.t("system_default")).tag("")
                    ForEach(AppSettings.supportedLanguages, id: \.self) { Text(verbatim: Self.languageNames[$0] ?? $0).tag($0) }
                }
                .accessibilityIdentifier("settings_app_language")
                Picker(L10n.t("pref_audio_lang"), selection: $settings.audioLanguage) {
                    Text(L10n.t("automatic")).tag("")
                    ForEach(Self.languages, id: \.self) { Text(L10n.locale.localizedString(forLanguageCode: $0) ?? $0).tag($0) }
                }
                .accessibilityIdentifier("settings_audio_language")
                Picker(L10n.t("pref_subtitle_lang"), selection: $settings.subtitleLanguage) {
                    Text(L10n.t("automatic")).tag("")
                    Text(L10n.t("off")).tag("off")
                    ForEach(Self.languages, id: \.self) { Text(L10n.locale.localizedString(forLanguageCode: $0) ?? $0).tag($0) }
                }
                .accessibilityIdentifier("settings_subtitle_language")
                .onChange(of: settings.audioLanguage) { env.applyLanguagePreferences() }
                .onChange(of: settings.subtitleLanguage) { env.applyLanguagePreferences() }
                Toggle(L10n.t("settings_quick_start"), isOn: $settings.quickStart)
                    .accessibilityIdentifier("settings_quick_start")
                AutoplayNextEpisodeToggle()   // Build 16 (PlayerExtrasViews.swift)
                #if os(iOS)
                BackgroundPlaybackSettings()   // Build 17 (PlaybackSystemControls.swift)
                #endif
                // Build 16: the device's lip-sync fix is the VLC calibration (test clip; never changes the engine).
                AVSyncCalibrationRow()
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L10n.t("settings_quick_start_hint"))
                    #if os(iOS)
                    Text(L10n.t("settings_background_hint"))
                    #endif
                }
            }
            Section {
                NavigationLink(value: SettingsRoute.advanced) {
                    Label(L10n.t("settings_advanced"), systemImage: "slider.horizontal.3")
                }
                .accessibilityIdentifier("settings_advanced")
                NavigationLink(value: SettingsRoute.about) {
                    Label(L10n.t("about_title"), systemImage: "info.circle")
                }
                .accessibilityIdentifier("settings_about")
            }
        }
        .hiddenListBackground()
        .screenBackground()
        .navigationTitle(L10n.t("nav_settings"))
        .navigationDestination(for: SettingsRoute.self) { route in
            switch route {
            case .sources: SourcesView()
            case .advanced: AdvancedSettingsView()
            case .source(let id): SourceDetailView(sourceId: id)
            case .edit(let id): EditSourceView(sourceId: id)
            case .add(.m3u): AddSourceView(kind: .m3u)
            case .add(.xtream): AddSourceView(kind: .xtream)
            case .add(.pairing): PairingView()
            case .account: AccountView()
            case .formatTest: FormatTestView()
            case .paywall: PaywallView()
            case .licenses: LicensesView()
            case .about: AboutView()
            case .avSyncCalibration: AVSyncCalibrationView()
            }
        }
    }

    /// Audio / subtitle preference (L5): every ISO 639-1 language, the common IPTV ones first, then by name in the UI
    /// language (cached per UI language).
    static var languages: [String] { LanguageList.codes(for: L10n.languageCode) }
    /// Endonyms for the app-language picker (always in their own language).
    static let languageNames = ["de": "Deutsch", "tr": "Türkçe", "en": "English"]
}

/// Settings → Sources: list (→ detail) and "+ add" rows (M3U, Xtream, tvOS: phone/QR).
struct SourcesView: View {
    @Environment(AppEnvironment.self) private var env
    #if os(iOS)
    @State private var reordering = false
    #endif

    var body: some View {
        Form {
            Section {
                ForEach(env.sources) { source in
                    NavigationLink(value: SettingsRoute.source(source.id)) {
                        SourceSummaryRow(source: source, isActive: env.sources.count > 1 && source.id == env.currentSource?.id)
                    }
                    .accessibilityIdentifier("settings_source_\(source.name)")
                }
                // IOS-23: drag to reorder (tvOS: Move up / Move down in the source detail).
                .onMove { env.moveSources(from: $0, to: $1) }
            }
            Section(L10n.t("add_source")) {
                NavigationLink(value: SettingsRoute.add(.m3u)) { Label(L10n.t("add_source_m3u"), systemImage: "plus") }
                    .accessibilityIdentifier("settings_add_m3u")
                NavigationLink(value: SettingsRoute.add(.xtream)) { Label(L10n.t("add_source_xtream"), systemImage: "plus") }
                    .accessibilityIdentifier("settings_add_xtream")
                #if os(tvOS)
                if env.accountsEnabled {
                    NavigationLink(value: SettingsRoute.add(.pairing)) { Label(L10n.t("add_source_qr"), systemImage: "qrcode") }
                }
                #endif
            }
        }
        .hiddenListBackground()
        .screenBackground()
        .navigationTitle(L10n.t("settings_sources"))
        #if os(iOS)
        .environment(\.editMode, .constant(reordering ? .active : .inactive))
        .toolbar {
            if env.sources.count > 1 {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(L10n.t(reordering ? "fav_move_done" : "fav_move")) { reordering.toggle() }
                        .accessibilityIdentifier(reordering ? "sources_move_done" : "sources_move")
                }
            }
        }
        #endif
    }
}

/// Settings → Advanced: playback details, appearance, account, purchase, diagnostics and about.
struct AdvancedSettingsView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var syncResetDone = false
    @State private var syncResetTask: Task<Void, Never>?

    var body: some View {
        @Bindable var settings = env.settings
        Form {
            Section(L10n.t("settings_playback")) {
                Picker(L10n.t("pref_default_aspect"), selection: $settings.aspect) {
                    ForEach(AspectMode.allCases, id: \.self) { Text(L10n.t($0.titleKey)).tag($0) }
                }
                .onChange(of: settings.aspect) { env.player.aspect = settings.aspect }
                Picker(L10n.t("pref_buffer"), selection: $settings.largeBuffer) {
                    Text(L10n.t("buffer_normal")).tag(false)
                    Text(L10n.t("buffer_large")).tag(true)
                }
                .onChange(of: settings.largeBuffer) { env.player.largeBuffer = settings.largeBuffer }
            }
            Section(L10n.t("settings_appearance")) {
                // U4: device zone or any IANA zone (searchable list).
                NavigationLink {
                    TimeZonePickerView(selection: $settings.epgTimeZone)
                } label: {
                    LabeledContent(L10n.t("pref_epg_timezone"), value: TimeZonePickerView.title(settings.epgTimeZone))
                }
                .accessibilityIdentifier("settings_epg_timezone")
                // L4: without a choice the clock follows the UI language's locale (de/tr 24 h, en_US 12 h).
                Toggle(L10n.t("pref_24h"), isOn: Binding(get: { settings.use24Hour ?? Self.localeUses24Hour },
                                                         set: { settings.use24Hour = $0 }))
                    .accessibilityIdentifier("settings_24h")
            }
            if env.accountsEnabled {
                Section(L10n.t("settings_account")) {
                    NavigationLink(value: SettingsRoute.account) {
                        if let account = env.account.account {
                            LText("account_signed_in_as", account.email)
                        } else {
                            LText(Theme.isTV ? "account_sign_in_tv" : "account_sign_in")
                        }
                    }
                }
            }
            Section(L10n.t("settings_purchase")) {
                NavigationLink(value: SettingsRoute.paywall) { PurchaseStatusRow() }
                    .accessibilityIdentifier("settings_purchase")
            }
            Section {
                // A/V sync A/B tests (CONTRACT §6.1 rule −1): device-local, applies at the next open.
                Picker(L10n.t("settings_player_engine"), selection: $settings.playerEngine) {
                    Text(L10n.t("automatic")).tag(PlayerEngineOverride.automatic)
                    Text(L10n.t("player_engine_apple")).tag(PlayerEngineOverride.avPlayer)
                    Text(L10n.t("player_engine_vlc")).tag(PlayerEngineOverride.vlcKit)
                    if env.player.remuxAvailable {
                        Text(L10n.t("player_engine_remux")).tag(PlayerEngineOverride.remux)
                    }
                }
                .accessibilityIdentifier("settings_player_engine")
                .onChange(of: settings.playerEngine) { env.player.setEngineOverride(settings.playerEngine) }
                // The confirmation is a second line of the same row (one focusable on tvOS; never truncated, IOS-17).
                Button { resetSync() } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L10n.t("audio_sync_reset"))
                        if syncResetDone {
                            Text(L10n.t("audio_sync_reset_done")).font(Theme.caption).foregroundStyle(Theme.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .accessibilityIdentifier("settings_reset_sync_done")
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .accessibilityIdentifier("settings_reset_sync")
                AVSyncCalibrationRow()
                NavigationLink(value: SettingsRoute.formatTest) { LText("diagnostics_format_test") }
                Toggle(L10n.t("perf_overlay"), isOn: $settings.showPerfOverlay)
                    .accessibilityIdentifier("settings_perf_overlay")
                Button(L10n.t("diagnostics_clear_images")) { ImageLoader.shared.clear() }
                Button(L10n.t("diagnostics_clear_epg")) { env.clearEpgCache() }
                LText("about_version", env.config.appVersion).foregroundStyle(Theme.textSecondary)
                NavigationLink(value: SettingsRoute.licenses) { LText("about_licenses") }
                    .accessibilityIdentifier("settings_licenses")
                LegalLinksRows()
            } header: {
                Text(L10n.t("settings_advanced"))
            } footer: {
                Text(L10n.t("settings_player_engine_hint"))
            }
        }
        .hiddenListBackground()
        .screenBackground()
        .navigationTitle(L10n.t("settings_advanced"))
        .onDisappear { syncResetTask?.cancel() }
    }

    /// 24 h clock of the UI language's locale (the toggle's state while the user has not chosen).
    static var localeUses24Hour: Bool {
        !(DateFormatter.dateFormat(fromTemplate: "j", options: 0, locale: L10n.locale) ?? "H").contains("a")
    }

    /// "Reset sync": every audio delay (device + all channels/titles) back to 0, confirmed for 2.5 s.
    private func resetSync() {
        env.player.resetAudioDelays()
        AccessibilityNotification.Announcement(L10n.t("audio_sync_reset_done")).post()
        syncResetDone = true
        syncResetTask?.cancel()
        syncResetTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled else { return }
            syncResetDone = false
        }
    }
}

private struct PurchaseStatusRow: View {
    @Environment(AppEnvironment.self) private var env
    var body: some View {
        switch env.license.decision.state {
        case .purchased: LText("purchase_owned")
        case .trialActive: TrialChip()
        case .trialExpired: LText("trial_expired")
        case .trialNotStarted: LText("trial_not_started")
        }
    }
}

struct SourceSummaryRow: View {
    @Environment(AppEnvironment.self) private var env
    let source: Source
    /// IOS-08: the source in use (shown only when there are several).
    var isActive = false

    var body: some View {
        HStack(spacing: 12) {
            Circle().fill(color).frame(width: 10, height: 10)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(source.name).font(Theme.body.weight(.semibold))
                    if isActive {
                        Label(L10n.t("source_active"), systemImage: "checkmark.circle.fill")
                            .font(Theme.caption.weight(.semibold)).foregroundStyle(Theme.success)
                            .accessibilityIdentifier("source_active_badge")
                    }
                }
                Text("\(source.type == .xtream ? "Xtream" : "M3U") · \(source.displayHost)").font(Theme.caption).foregroundStyle(Theme.textSecondary)
                if let last = source.lastRefreshAt {
                    LText("source_last_refresh", L10n.date(last, date: .abbreviated, time: .shortened)).font(.caption2).foregroundStyle(Theme.textSecondary)
                } else {
                    LText("source_never_refreshed").font(.caption2).foregroundStyle(Theme.textSecondary)
                }
                if let expires = source.xtreamAccount?.expiresAt {
                    LText("source_expires", L10n.date(expires, date: .abbreviated, time: .omitted)).font(.caption2).foregroundStyle(Theme.textSecondary)
                }
            }
            if env.refreshing.contains(source.id) { Spacer(); ProgressView() }
        }
    }

    private var color: Color {
        guard let result = source.lastRefreshResult else { return Theme.textSecondary }
        return result.isOK ? Theme.success : Theme.error
    }
}

/// Source detail (SCREENS §3.9): status (catalog + EPG), refresh, use, edit, EPG URL, EPG shift, auto refresh,
/// order (tvOS), delete (confirmed).
struct SourceDetailView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    let sourceId: String
    @State private var confirmDelete = false
    @State private var lastError: SourceError?

    var body: some View {
        Form {
            if let source = env.sources.first(where: { $0.id == sourceId }) {
                Section { SourceSummaryRow(source: source, isActive: env.sources.count > 1 && source.id == env.currentSource?.id).tvFocusableRow() }
                if let result = source.lastRefreshResult {
                    Section {
                        if let error = result.error {
                            let text = L10n.error(error.presentation())
                            Text(text.title).foregroundStyle(Theme.error)
                            Text(text.body).font(Theme.caption)
                        } else {
                            LText("source_summary", L10n.number(result.liveCount), L10n.number(result.movieCount), L10n.number(result.seriesCount))
                                .tvFocusableRow()
                        }
                        // B6: the guide's own status – a failed XMLTV is never silent.
                        if let epgError = result.epgError {
                            Label(L10n.t("err_epg_failed", L10n.error(epgError.presentation()).title), systemImage: "exclamationmark.triangle.fill")
                                .font(Theme.caption).foregroundStyle(Theme.warning)
                                .accessibilityIdentifier("source_epg_status")
                                .tvFocusableRow()
                        } else if let count = result.epgProgramCount {
                            Text(epgLoadedText(count: count, at: result.epgLoadedAt))
                                .font(Theme.caption).foregroundStyle(Theme.textSecondary)
                                .accessibilityIdentifier("source_epg_status")
                                .tvFocusableRow()
                        }
                    }
                }
                Section {
                    Button(L10n.t("action_refresh")) {
                        Task { lastError = await env.refreshSource(id: sourceId) }
                    }
                    .disabled(env.refreshing.contains(sourceId))
                    .accessibilityIdentifier("source_refresh")
                    if env.sources.count > 1, env.currentSource?.id != sourceId {
                        Button(L10n.t("source_use")) { env.selectSource(sourceId) }
                            .accessibilityIdentifier("source_use")
                    }
                    NavigationLink(value: SettingsRoute.edit(sourceId)) { LText("action_edit") }
                        .accessibilityIdentifier("source_edit")
                    NavigationLink(value: SettingsRoute.edit(sourceId)) {
                        LabeledContent(L10n.t("source_epg_url"), value: epgURLText(source))
                    }
                    .accessibilityIdentifier("source_epg_url")
                    epgShiftRows(source)
                    Picker(L10n.t("source_auto_refresh"), selection: Binding(get: { source.autoRefreshHours }, set: { v in
                        env.updateSource(id: sourceId) { $0.autoRefreshHours = v }
                    })) {
                        Text(L10n.t("off")).tag(0)
                        ForEach([6, 12, 24], id: \.self) { Text(L10n.t("every_n_hours", String($0))).tag($0) }
                    }
                }
                #if os(tvOS)
                if env.sources.count > 1, let index = env.sources.firstIndex(where: { $0.id == sourceId }) {
                    // IOS-23 on tvOS: one focusable row per direction.
                    Section {
                        if index > 0 {
                            Button(L10n.t("source_move_up")) { env.moveSources(from: IndexSet(integer: index), to: index - 1) }
                                .accessibilityIdentifier("source_move_up")
                        }
                        if index < env.sources.count - 1 {
                            Button(L10n.t("source_move_down")) { env.moveSources(from: IndexSet(integer: index), to: index + 2) }
                                .accessibilityIdentifier("source_move_down")
                        }
                    }
                }
                #endif
                Section {
                    Button(L10n.t("action_delete"), role: .destructive) { confirmDelete = true }
                        .accessibilityIdentifier("source_delete")
                }
                .confirmationDialog(L10n.t("source_delete_confirm", source.name), isPresented: $confirmDelete, titleVisibility: .visible) {
                    Button(L10n.t("action_delete"), role: .destructive) {
                        env.deleteSource(id: sourceId)
                        dismiss()
                    }
                    .accessibilityIdentifier("source_delete_confirm")
                    Button(L10n.t("action_cancel"), role: .cancel) {}
                }
            }
        }
        .hiddenListBackground()
        .screenBackground()
        .navigationTitle(env.sources.first(where: { $0.id == sourceId })?.name ?? "")
    }

    private func epgLoadedText(count: Int, at date: Date?) -> String {
        L10n.t("epg_status_loaded", L10n.number(count), date.map { L10n.date($0, date: .abbreviated, time: .shortened) } ?? "–")
    }

    /// Override (host + path only, never credentials) or the default with "Default:".
    private func epgURLText(_ source: Source) -> String {
        let display = env.refresher.epgURL(sourceId: source.id).flatMap(AddSourceViewModel.displayURL)
        guard let display else { return L10n.t("source_epg_none") }
        return source.epgUrlOverride ? display : L10n.t("source_epg_default", display)
    }

    /// IOS-24: presets −12…+12 h in 30-min steps (+ the current value when the fine buttons left the grid);
    /// iOS keeps the ±15 min buttons (L3: with VoiceOver labels).
    @ViewBuilder
    private func epgShiftRows(_ source: Source) -> some View {
        let values = Array(Set(Self.shiftPresets + [source.epgShiftMinutes])).sorted()
        Picker(L10n.t("source_epg_shift"), selection: Binding(get: { source.epgShiftMinutes }, set: { v in
            shift(source, by: v - source.epgShiftMinutes)
        })) {
            ForEach(values, id: \.self) { Text(Self.shiftText($0)).tag($0) }
        }
        .accessibilityIdentifier("source_epg_shift")
        #if !os(tvOS)
        HStack {
            Spacer()
            Button { shift(source, by: -15) } label: { Image(systemName: "minus.circle") }
                .disabled(source.epgShiftMinutes <= -720)
                .accessibilityLabel(L10n.t("epg_shift_earlier"))
                .accessibilityIdentifier("source_epg_shift_minus")
            Button { shift(source, by: 15) } label: { Image(systemName: "plus.circle") }
                .disabled(source.epgShiftMinutes >= 720)
                .accessibilityLabel(L10n.t("epg_shift_later"))
                .accessibilityIdentifier("source_epg_shift_plus")
        }
        .buttonStyle(.borderless)
        #endif
    }

    static let shiftPresets = Array(stride(from: -720, through: 720, by: 30))

    private func shift(_ source: Source, by delta: Int) {
        env.updateSource(id: source.id) { $0.epgShiftMinutes = min(720, max(-720, $0.epgShiftMinutes + delta)) }
    }

    static func shiftText(_ minutes: Int) -> String {
        let sign = minutes < 0 ? "−" : "+"
        let m = abs(minutes)
        return String(format: "%@%d:%02d", sign, m / 60, m % 60)
    }
}

/// Settings → source → Edit (IOS-03/U2): the add form prefilled from the source; saving re-validates and reloads.
struct EditSourceView: View {
    @Environment(AppEnvironment.self) private var env
    let sourceId: String

    var body: some View {
        if let source = env.sources.first(where: { $0.id == sourceId }) {
            AddSourceView(kind: source.type == .xtream ? .xtream : .m3u, editing: source)
        }
    }
}

/// U4: EPG time zone – "Device" or any IANA zone, searchable.
struct TimeZonePickerView: View {
    @Binding var selection: String
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    static func title(_ id: String) -> String {
        guard !id.isEmpty, let zone = TimeZone(identifier: id) else { return L10n.t("timezone_device") }
        return "\(id.replacingOccurrences(of: "_", with: " ")) (\(offset(zone)))"
    }

    static func offset(_ zone: TimeZone, at date: Date = Date()) -> String {
        let seconds = zone.secondsFromGMT(for: date)
        let sign = seconds < 0 ? "−" : "+"
        let m = abs(seconds) / 60
        return String(format: "UTC%@%d:%02d", sign, m / 60, m % 60)
    }

    private var zones: [String] {
        let all = TimeZone.knownTimeZoneIdentifiers
        let q = query.trimmingCharacters(in: .whitespaces).lowercased().replacingOccurrences(of: " ", with: "_")
        guard !q.isEmpty else { return all }
        return all.filter { $0.lowercased().contains(q) || Self.offset(TimeZone(identifier: $0) ?? .gmt).lowercased().contains(q) }
    }

    var body: some View {
        List {
            Section {
                row(id: "", title: L10n.t("timezone_device"))
            }
            Section {
                ForEach(zones, id: \.self) { id in row(id: id, title: Self.title(id)) }
            }
        }
        .searchable(text: $query, prompt: L10n.t("timezone_search"))
        .hiddenListBackground()
        .screenBackground()
        .navigationTitle(L10n.t("pref_epg_timezone"))
    }

    private func row(id: String, title: String) -> some View {
        Button {
            selection = id
            dismiss()
        } label: {
            HStack {
                Text(title).foregroundStyle(Theme.textPrimary)
                Spacer()
                if selection == id { Image(systemName: "checkmark").foregroundStyle(Theme.primary) }
            }
        }
        .accessibilityIdentifier(id.isEmpty ? "timezone_device" : "timezone_\(id)")
        .accessibilityAddTraits(selection == id ? .isSelected : [])
    }
}

/// S1 / IOS-19: privacy policy and terms – links on iOS; on tvOS (no browser) one focusable row each that shows
/// a QR code with the URL.
struct LegalLinksRows: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        link("privacy", env.config.privacyURL, id: "legal_privacy")
        link("terms", env.config.termsURL, id: "legal_terms")
    }

    @ViewBuilder
    private func link(_ key: String, _ url: URL, id: String) -> some View {
        #if os(tvOS)
        NavigationLink {
            LegalQRView(titleKey: key, url: url)
        } label: {
            LText(key)
        }
        .accessibilityIdentifier(id)
        #else
        Link(destination: url) {
            Label(L10n.t(key), systemImage: "arrow.up.right.square")
        }
        .accessibilityIdentifier(id)
        #endif
    }
}

/// tvOS: a legal page as QR code + readable URL.
struct LegalQRView: View {
    let titleKey: String
    let url: URL

    var body: some View {
        VStack(spacing: 30) {
            LText(titleKey).font(Theme.title).foregroundStyle(Theme.textPrimary)
            QRCodeView(text: url.absoluteString).frame(width: 360, height: 360)
            LText("legal_open_on_phone", url.absoluteString).font(Theme.body).foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .accessibilityIdentifier("legal_url")
        }
        .padding(Theme.safeH)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .screenBackground()
        .focusable()
    }
}

/// Optional account: e-mail code (iOS) / device code + QR (tvOS), sign out, delete (SCREENS §3.9).
struct AccountView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var email = ""
    @State private var code = ""
    @State private var confirmDelete = false

    var body: some View {
        let account = env.account
        Form {
            Section { LText("account_why").font(Theme.caption).foregroundStyle(Theme.textSecondary) }
            if let info = account.account {
                Section {
                    LText("account_signed_in_as", info.email)
                    if let synced = env.lastSyncedAt { LText("last_synced", L10n.date(synced, date: .omitted, time: .shortened)) }
                    Button(L10n.t("account_sign_out")) { Task { await account.signOut() } }
                    Button(L10n.t("account_delete"), role: .destructive) { confirmDelete = true }
                }
                .confirmationDialog(L10n.t("account_delete_confirm"), isPresented: $confirmDelete, titleVisibility: .visible) {
                    Button(L10n.t("account_delete"), role: .destructive) { Task { _ = await account.deleteAccount() } }
                    Button(L10n.t("action_cancel"), role: .cancel) {}
                }
            } else {
                #if os(tvOS)
                deviceLogin(account)
                #endif
                Section(L10n.t("account_sign_in")) {
                    if let pending = account.pendingEmail {
                        LText("account_code_sent", pending)
                        TextField(L10n.t("account_enter_code"), text: $code)
                        if let dev = account.devCode { LText("account_dev_code", dev).foregroundStyle(Theme.warning) }
                        Button(L10n.t("account_verify")) { Task { await account.verify(code: code) } }.disabled(code.count < 6)
                        Button(L10n.t("action_cancel")) { account.cancelEmailLogin() }
                    } else {
                        TextField(L10n.t("account_field_email"), text: $email).plainField()
                        #if os(iOS)
                            .keyboardType(.emailAddress)
                        #endif
                        Button(L10n.t("account_send_code")) { Task { await account.startEmailLogin(email: email, locale: L10n.languageCode) } }
                            .disabled(!email.contains("@"))
                    }
                    if account.busy { ProgressView() }
                    if let error = account.errorMessage { Text(error).foregroundStyle(Theme.error) }
                }
            }
        }
        .hiddenListBackground()
        .screenBackground()
        .navigationTitle(L10n.t("settings_account"))
        .onDisappear { account.cancelDeviceLogin() }
    }

    #if os(tvOS)
    @ViewBuilder
    private func deviceLogin(_ account: AccountManager) -> some View {
        Section(L10n.t("account_sign_in_tv")) {
            switch account.deviceLogin {
            case .idle:
                Button(L10n.t("account_sign_in_tv")) { account.startDeviceLogin() }
            case let .waiting(start, expiresAt):
                HStack(spacing: 40) {
                    QRCodeView(text: start.verificationUrlComplete).frame(width: 300, height: 300)
                    VStack(alignment: .leading, spacing: 16) {
                        LText("device_login_title", env.config.backendBaseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
                        LText("device_login_code", start.userCode).font(.system(size: 56, weight: .heavy, design: .monospaced))
                        TimelineView(.periodic(from: .now, by: 1)) { ctx in
                            let left = max(0, Int(expiresAt.timeIntervalSince(ctx.date)))
                            LText("pair_expires_in", String(format: "%d:%02d", left / 60, left % 60))
                        }
                    }
                }
            case .expired:
                LText("pair_expired")
                Button(L10n.t("action_new_code")) { account.startDeviceLogin() }
            case .failed(let message):
                Text(message).foregroundStyle(Theme.error)
                Button(L10n.t("action_retry")) { account.startDeviceLogin() }
            }
        }
    }
    #endif
}

/// Settings → Diagnostics → Format test (stream-samples.json bundled).
struct FormatTestView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var model: FormatTestViewModel?

    var body: some View {
        @Bindable var settings = env.settings
        List {
            Section {
                TextField(L10n.t("format_test_host"), text: $settings.formatTestHost).plainField()
                Button(L10n.t("format_test_run")) {
                    let m = FormatTestViewModel(samplesJSON: Self.samplesJSON, lanHost: settings.formatTestHost, engines: .app)
                    model = m
                    Task { await m.runAll() }
                }
                .disabled(model?.running == true)
                .accessibilityIdentifier("format_test_run")
            }
            if let model {
                ForEach(model.samples) { sample in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(sample.name).font(Theme.body)
                            Text(L10n.t("format_test_expected", model.expected(sample))).font(Theme.caption).foregroundStyle(Theme.textSecondary)
                            if let engine = model.engines[sample.id] {
                                Text(L10n.t("format_test_engine", engine == .vlcKit ? "VLCKit" : "AVPlayer"))
                                    .font(Theme.caption).foregroundStyle(engine == .vlcKit ? Theme.warning : Theme.primary)
                            }
                        }
                        Spacer()
                        result(model.results[sample.id] ?? .pending)
                    }
                }
            }
        }
        .hiddenListBackground()
        .screenBackground()
        .navigationTitle(L10n.t("diagnostics_format_test"))
        .onAppear {
            if model == nil { model = FormatTestViewModel(samplesJSON: Self.samplesJSON, lanHost: env.settings.formatTestHost, engines: .app) }
        }
    }

    static var samplesJSON: Data? {
        Bundle.main.url(forResource: "stream-samples", withExtension: "json").flatMap { try? Data(contentsOf: $0) }
    }

    @ViewBuilder
    private func result(_ outcome: FormatTestViewModel.Outcome) -> some View {
        switch outcome {
        case .pending: Text("–").foregroundStyle(Theme.textSecondary)
        case .running: ProgressView()
        case .ok: LText("format_test_result_ok").foregroundStyle(Theme.success)
        case .expectedError(let name): LText("format_test_result_expected_error", name).foregroundStyle(Theme.success)
        case .unexpected(let name): LText("format_test_result_fail", name).foregroundStyle(Theme.error)
        }
    }
}

extension View {
    /// tvOS: makes a read-only list row focusable (otherwise the remote cannot scroll to it).
    @ViewBuilder
    func tvFocusableRow() -> some View {
        #if os(tvOS)
        focusable()
        #else
        self
        #endif
    }
}

/// Settings → Open-source licenses (LGPL-2.1 notice for VLCKit, docs/SECURITY.md §7).
struct LicensesView: View {
    private struct Component: Identifiable {
        let name: String
        let license: String
        let noticeKey: String
        let source: String
        var id: String { name }
    }

    private let components = [
        Component(name: "VLCKit / libVLC (MobileVLCKit, TVVLCKit)", license: "LGPL-2.1-or-later", noticeKey: "licenses_vlckit_notice",
                  source: "https://code.videolan.org/videolan/VLCKit"),
        Component(name: "FFmpeg (libavformat, libavcodec, libavutil, libswresample)", license: "LGPL-2.1-or-later",
                  noticeKey: "licenses_ffmpeg_notice", source: "https://ffmpeg.org/releases/"),
        Component(name: "swift-crypto (Apple)", license: "Apache-2.0", noticeKey: "licenses_apache_notice",
                  source: "https://github.com/apple/swift-crypto"),
        Component(name: "swift-asn1 (Apple)", license: "Apache-2.0", noticeKey: "licenses_apache_notice",
                  source: "https://github.com/apple/swift-asn1"),
    ]
    @State private var showFullText = false

    /// LGPL-2.1 text bundled from Vendor/VLCKit/COPYING.txt (copied by scripts/fetch-vlckit.sh).
    private static let lgplText: String? = Bundle.main.url(forResource: "COPYING", withExtension: "txt")
        .flatMap { try? String(contentsOf: $0, encoding: .utf8) }

    var body: some View {
        List {
            ForEach(components) { c in
                Section(c.name) {
                    Text(c.license).font(Theme.body.weight(.semibold)).tvFocusableRow()
                    LText(c.noticeKey).font(Theme.caption).foregroundStyle(Theme.textSecondary).tvFocusableRow()
                    if c.noticeKey == "licenses_vlckit_notice" {
                        LText("licenses_vlckit_linking").font(Theme.caption).foregroundStyle(Theme.textSecondary)
                    }
                    #if os(tvOS)
                    Text("\(L10n.t("licenses_source_code")): \(c.source)").font(Theme.caption)
                    #else
                    if let url = URL(string: c.source) {
                        Link(destination: url) { Label(L10n.t("licenses_source_code"), systemImage: "arrow.up.right.square") }
                    }
                    #endif
                }
            }
            if let text = Self.lgplText {
                Section {
                    Button(L10n.t("licenses_full_text")) { showFullText.toggle() }
                        .accessibilityIdentifier("licenses_full_text")
                    if showFullText {
                        // Paragraph rows: on tvOS each row is focusable so the remote can scroll the text.
                        ForEach(Array(text.components(separatedBy: "\n\n").enumerated()), id: \.offset) { _, paragraph in
                            Text(paragraph).font(.system(size: Theme.isTV ? 20 : 11, design: .monospaced)).foregroundStyle(Theme.textSecondary)
                                .tvFocusableRow()
                        }
                    }
                } header: {
                    Text("GNU LGPL 2.1")
                }
            }
        }
        .hiddenListBackground()
        .screenBackground()
        .navigationTitle(L10n.t("about_licenses"))
    }
}

/// ISO 639-1 languages for the audio / subtitle preferences (L5).
enum LanguageList {
    /// Shown first: the languages of the owner's panels.
    static let common = ["tr", "de", "en", "ar", "ku", "fr", "es", "it", "ru", "pl", "nl"]
    @MainActor private static var cache: (lang: String, codes: [String])?

    @MainActor
    static func codes(for uiLanguage: String) -> [String] {
        if let cache, cache.lang == uiLanguage { return cache.codes }
        let locale = L10n.locale
        let all = Set(Locale.LanguageCode.isoLanguageCodes.map(\.identifier).filter { $0.count == 2 })
        let rest = all.subtracting(common).filter { locale.localizedString(forLanguageCode: $0) != nil }
            .sorted { (locale.localizedString(forLanguageCode: $0) ?? $0).localizedCompare(locale.localizedString(forLanguageCode: $1) ?? $1) == .orderedAscending }
        let codes = common.filter(all.contains) + rest
        cache = (uiLanguage, codes)
        return codes
    }
}
