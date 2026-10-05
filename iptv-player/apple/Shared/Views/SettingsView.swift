import IPTVCore
import IPTVKit
import SwiftUI

enum SettingsRoute: Hashable {
    case source(String)
    case add(AddSourceRoute)
    case account
    case formatTest
    case paywall
    case licenses
}

/// Settings and source management (SCREENS §3.9) – always reachable, also when locked.
struct SettingsView: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        @Bindable var settings = env.settings
        Form {
            Section(L10n.t("settings_sources")) {
                ForEach(env.sources) { source in
                    NavigationLink(value: SettingsRoute.source(source.id)) { SourceSummaryRow(source: source) }
                }
                NavigationLink(value: SettingsRoute.add(.m3u)) { Label(L10n.t("add_source_m3u"), systemImage: "plus") }
                NavigationLink(value: SettingsRoute.add(.xtream)) { Label(L10n.t("add_source_xtream"), systemImage: "plus") }
                #if os(tvOS)
                NavigationLink(value: SettingsRoute.add(.pairing)) { Label(L10n.t("add_source_qr"), systemImage: "qrcode") }
                #endif
            }
            Section(L10n.t("settings_playback")) {
                Picker(L10n.t("pref_default_aspect"), selection: $settings.aspect) {
                    ForEach(AspectMode.allCases, id: \.self) { Text(L10n.t($0.titleKey)).tag($0) }
                }
                .onChange(of: settings.aspect) { env.player.aspect = settings.aspect }
                Picker(L10n.t("pref_audio_lang"), selection: $settings.audioLanguage) {
                    Text(L10n.t("automatic")).tag("")
                    ForEach(Self.languages, id: \.self) { Text(L10n.locale.localizedString(forLanguageCode: $0) ?? $0).tag($0) }
                }
                Picker(L10n.t("pref_subtitle_lang"), selection: $settings.subtitleLanguage) {
                    Text(L10n.t("automatic")).tag("")
                    Text(L10n.t("off")).tag("off")
                    ForEach(Self.languages, id: \.self) { Text(L10n.locale.localizedString(forLanguageCode: $0) ?? $0).tag($0) }
                }
                .onChange(of: settings.audioLanguage) { env.applyLanguagePreferences() }
                .onChange(of: settings.subtitleLanguage) { env.applyLanguagePreferences() }
                Picker(L10n.t("pref_buffer"), selection: $settings.largeBuffer) {
                    Text(L10n.t("buffer_normal")).tag(false)
                    Text(L10n.t("buffer_large")).tag(true)
                }
                #if os(tvOS)
                Toggle(L10n.t("pref_tv_preview"), isOn: $settings.tvPreview)
                #endif
            }
            Section(L10n.t("settings_appearance")) {
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
                Picker(L10n.t("pref_epg_timezone"), selection: $settings.epgTimeZone) {
                    Text(L10n.t("timezone_device")).tag("")
                    ForEach(["UTC", "Europe/Istanbul", "Europe/Berlin", "Europe/London"], id: \.self) { Text($0).tag($0) }
                }
                Toggle(L10n.t("pref_24h"), isOn: Binding(get: { settings.use24Hour ?? true }, set: { settings.use24Hour = $0 }))
            }
            Section(L10n.t("settings_account")) {
                NavigationLink(value: SettingsRoute.account) {
                    if let account = env.account.account {
                        LText("account_signed_in_as", account.email)
                    } else {
                        LText(Theme.isTV ? "account_sign_in_tv" : "account_sign_in")
                    }
                }
            }
            Section(L10n.t("settings_purchase")) {
                NavigationLink(value: SettingsRoute.paywall) { PurchaseStatusRow() }
            }
            Section(L10n.t("settings_advanced")) {
                NavigationLink(value: SettingsRoute.formatTest) { LText("diagnostics_format_test") }
                Button(L10n.t("diagnostics_clear_images")) { ImageLoader.shared.clear() }
                Button(L10n.t("diagnostics_clear_epg")) { env.clearEpgCache() }
                LText("about_version", env.config.appVersion).foregroundStyle(Theme.textSecondary)
                NavigationLink(value: SettingsRoute.licenses) { LText("about_licenses") }
                    .accessibilityIdentifier("settings_licenses")
                LText("privacy").foregroundStyle(Theme.textSecondary)
            }
        }
        .hiddenListBackground()
        .screenBackground()
        .navigationTitle(L10n.t("nav_settings"))
        .navigationDestination(for: SettingsRoute.self) { route in
            switch route {
            case .source(let id): SourceDetailView(sourceId: id)
            case .add(.m3u): AddSourceView(kind: .m3u)
            case .add(.xtream): AddSourceView(kind: .xtream)
            case .add(.pairing): PairingView()
            case .account: AccountView()
            case .formatTest: FormatTestView()
            case .paywall: PaywallView()
            case .licenses: LicensesView()
            }
        }
    }

    static let languages = ["tr", "en", "de", "fr", "es", "ar", "ru"]
    /// Endonyms for the app-language picker (always in their own language).
    static let languageNames = ["de": "Deutsch", "tr": "Türkçe", "en": "English"]
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

    var body: some View {
        HStack(spacing: 12) {
            Circle().fill(color).frame(width: 10, height: 10)
            VStack(alignment: .leading, spacing: 2) {
                Text(source.name).font(Theme.body.weight(.semibold))
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

/// Source detail: refresh, EPG shift, auto refresh, delete (confirmed).
struct SourceDetailView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    let sourceId: String
    @State private var confirmDelete = false
    @State private var lastError: SourceError?

    var body: some View {
        Form {
            if let source = env.sources.first(where: { $0.id == sourceId }) {
                Section { SourceSummaryRow(source: source) }
                if let result = source.lastRefreshResult {
                    Section {
                        if let error = result.error {
                            let text = L10n.error(error.presentation())
                            Text(text.title).foregroundStyle(Theme.error)
                            Text(text.body).font(Theme.caption)
                        } else {
                            LText("source_summary", "\(result.liveCount)", "\(result.movieCount)", "\(result.seriesCount)")
                        }
                    }
                }
                Section {
                    Button(L10n.t("action_refresh")) {
                        Task { lastError = await env.refreshSource(id: sourceId) }
                    }
                    .disabled(env.refreshing.contains(sourceId))
                    #if os(tvOS)
                    // tvOS rows focus a single control → one picker instead of −/+ buttons.
                    Picker(L10n.t("source_epg_shift"), selection: Binding(get: { source.epgShiftMinutes }, set: { v in
                        shift(source, by: v - source.epgShiftMinutes)
                    })) {
                        ForEach(Array(stride(from: -720, through: 720, by: 15)), id: \.self) { Text(Self.shiftText($0)).tag($0) }
                    }
                    #else
                    HStack {
                        Text("\(L10n.t("source_epg_shift")): \(Self.shiftText(source.epgShiftMinutes))")
                        Spacer()
                        Button { shift(source, by: -15) } label: { Image(systemName: "minus.circle") }
                            .disabled(source.epgShiftMinutes <= -720)
                        Button { shift(source, by: 15) } label: { Image(systemName: "plus.circle") }
                            .disabled(source.epgShiftMinutes >= 720)
                    }
                    .buttonStyle(.borderless)
                    #endif
                    Picker(L10n.t("source_auto_refresh"), selection: Binding(get: { source.autoRefreshHours }, set: { v in
                        var s = source; s.autoRefreshHours = v; env.updateSource(s)
                    })) {
                        Text(L10n.t("off")).tag(0)
                        ForEach([6, 12, 24], id: \.self) { Text(L10n.t("every_n_hours", String($0))).tag($0) }
                    }
                }
                Section {
                    Button(L10n.t("action_delete"), role: .destructive) { confirmDelete = true }
                }
                .confirmationDialog(L10n.t("source_delete_confirm", source.name), isPresented: $confirmDelete, titleVisibility: .visible) {
                    Button(L10n.t("action_delete"), role: .destructive) {
                        env.deleteSource(id: sourceId)
                        dismiss()
                    }
                    Button(L10n.t("action_cancel"), role: .cancel) {}
                }
            }
        }
        .hiddenListBackground()
        .screenBackground()
        .navigationTitle(env.sources.first(where: { $0.id == sourceId })?.name ?? "")
    }

    private func shift(_ source: Source, by delta: Int) {
        var s = source
        s.epgShiftMinutes = min(720, max(-720, s.epgShiftMinutes + delta))
        env.updateSource(s)
    }

    static func shiftText(_ minutes: Int) -> String {
        let sign = minutes < 0 ? "−" : "+"
        let m = abs(minutes)
        return String(format: "%@%d:%02d", sign, m / 60, m % 60)
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
