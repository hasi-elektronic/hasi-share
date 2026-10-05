import IPTVCore
import IPTVKit
import SwiftUI

/// M3U / Xtream form → stepwise progress → summary or precise error (SCREENS §3.1).
struct AddSourceView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(Router.self) private var router
    @Environment(\.dismiss) private var dismiss
    @State private var model: AddSourceViewModel?
    let kind: AddSourceViewModel.Kind
    var payload: PairPayload?

    var body: some View {
        Group {
            if let model {
                content(model)
            } else {
                ProgressView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .screenBackground()
        .navigationTitle(L10n.t(kind == .m3u ? "add_source_m3u" : "add_source_xtream"))
        .onAppear {
            guard model == nil else { return }
            let m = AddSourceViewModel(env: env, kind: kind)
            if let payload {
                m.apply(payload)
                m.connect()
            }
            model = m
        }
        .onDisappear { router.onboarding = false }
    }

    @ViewBuilder
    private func content(_ model: AddSourceViewModel) -> some View {
        switch model.phase {
        case .editing:
            AddSourceForm(model: model)
        case .connecting(let step):
            VStack(spacing: 24) {
                ProgressView().controlSize(.large)
                Text(text(for: step)).font(Theme.headline).foregroundStyle(Theme.textPrimary)
                Button(L10n.t("action_cancel")) { model.cancel() }.buttonStyle(SecondaryButtonStyle())
            }
            .onAppear { router.onboarding = true }
        case .success(let source):
            successView(source)
        case .failed(let error):
            ErrorCardView(presentation: error.presentation(formatDate: { $0.formatted(date: .long, time: .omitted) })) { action in
                switch action {
                case .retry, .refresh: model.connect()
                default: model.backToForm()
                }
            }
            .padding(Theme.safeH)
        }
    }

    private func successView(_ source: Source) -> some View {
        let status = source.lastRefreshResult ?? SourceStatus()
        return VStack(spacing: Theme.isTV ? 24 : 14) {
            Image(systemName: "checkmark.circle.fill").font(.system(size: Theme.isTV ? 96 : 64)).foregroundStyle(Theme.success)
            LText("source_added_title").font(Theme.title).foregroundStyle(Theme.textPrimary)
            Text(source.name).font(Theme.headline).foregroundStyle(Theme.textSecondary)
            LText("source_summary", "\(status.liveCount)", "\(status.movieCount)", "\(status.seriesCount)")
                .font(Theme.body).foregroundStyle(Theme.textPrimary)
            if let account = source.xtreamAccount {
                if let expires = account.expiresAt {
                    LText("source_expires", expires.formatted(date: .long, time: .omitted)).font(Theme.caption).foregroundStyle(Theme.textSecondary)
                } else {
                    LText("source_unlimited").font(Theme.caption).foregroundStyle(Theme.textSecondary)
                }
            }
            Button(L10n.t("action_continue")) {
                router.onboarding = false
                dismiss()
            }
            .buttonStyle(PrimaryButtonStyle())
            .accessibilityIdentifier("add_source_continue")
        }
        .padding(Theme.safeH)
    }

    private func text(for step: RefreshProgress) -> String {
        switch step {
        case .connecting: return L10n.t("progress_connecting")
        case .authenticating: return L10n.t("progress_auth")
        case .channels(let n): return L10n.t("progress_channels", n.formatted())
        case .movies(let n): return L10n.t("progress_movies", n.formatted())
        case .series(let n): return L10n.t("progress_series", n.formatted())
        case .epg: return L10n.t("progress_epg")
        }
    }
}

private struct AddSourceForm: View {
    @Bindable var model: AddSourceViewModel
    @State private var showAdvanced = false

    var body: some View {
        Form {
            Section {
                TextField(L10n.t("field_name"), text: $model.name)
                    .accessibilityIdentifier("field_name")
                if model.kind == .m3u {
                    TextField(L10n.t("field_m3u_url"), text: $model.m3uURL)
                        .urlField()
                        .accessibilityIdentifier("field_m3u_url")
                    if model.m3uURLError { LText("validation_url").font(.caption).foregroundStyle(Theme.error) }
                } else {
                    TextField(L10n.t("field_server"), text: $model.server)
                        .urlField()
                        .accessibilityIdentifier("field_server")
                    if model.serverError { LText("validation_url").font(.caption).foregroundStyle(Theme.error) }
                    TextField(L10n.t("field_username"), text: $model.username)
                        .plainField()
                        .accessibilityIdentifier("field_username")
                    #if os(tvOS)
                    // tvOS: a Form row focuses only ONE control – an eye button next to the field
                    // would take the focus and the password could never be entered.
                    SecureField(L10n.t("field_password"), text: $model.password)
                        .plainField()
                        .accessibilityIdentifier("field_password")
                    #else
                    HStack {
                        if model.showPassword {
                            TextField(L10n.t("field_password"), text: $model.password).plainField()
                        } else {
                            SecureField(L10n.t("field_password"), text: $model.password).plainField()
                        }
                        Button {
                            model.showPassword.toggle()
                        } label: {
                            Image(systemName: model.showPassword ? "eye.slash" : "eye")
                        }
                        .accessibilityLabel(L10n.t(model.showPassword ? "action_hide_password" : "action_show_password"))
                    }
                    .accessibilityIdentifier("field_password")
                    #endif
                }
            }
            Section {
                Toggle(L10n.t("field_advanced"), isOn: $showAdvanced)
                if showAdvanced {
                    TextField(L10n.t("field_epg_url"), text: $model.epgURL).urlField()
                    if model.epgURLError { LText("validation_url").font(.caption).foregroundStyle(Theme.error) }
                    if model.kind == .m3u {
                        TextField(L10n.t("field_user_agent"), text: $model.userAgent).plainField()
                    }
                }
            }
            Section {
                Button(L10n.t("action_connect")) { model.connect() }
                    .disabled(!model.isValid)
                    .accessibilityIdentifier("action_connect")
            }
            Section {
                LText("legal_no_content").font(.caption).foregroundStyle(Theme.textSecondary)
            }
        }
        .hiddenListBackground()
    }
}

extension View {
    func urlField() -> some View {
        #if os(iOS)
        return self.keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
        #else
        return self.textInputAutocapitalization(.never).autocorrectionDisabled()
        #endif
    }

    func plainField() -> some View {
        textInputAutocapitalization(.never).autocorrectionDisabled()
    }
}
