import IPTVCore
import IPTVKit
import SwiftUI

/// Where "add source" leads.
enum AddSourceRoute: Hashable {
    case m3u
    case xtream
    case pairing
}

/// First launch / no source: logo, legal note, trial card, add-source options (SCREENS §3.1).
struct WelcomeView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(Router.self) private var router
    @State private var path: [AddSourceRoute] = []
    #if os(tvOS)
    /// tvOS: focus starts on the first "add source" option (not on the trial card / a hidden QR option).
    @FocusState private var focusedOption: AddSourceRoute?
    #endif

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(spacing: Theme.isTV ? 36 : 22) {
                    header
                    TrialCard()
                    addOptions
                }
                .padding(.horizontal, Theme.safeH)
                .padding(.vertical, Theme.safeV + 12)
                .frame(maxWidth: Theme.isTV ? 1400 : 640)
                .frame(maxWidth: .infinity)
            }
            .screenBackground()
            .navigationDestination(for: AddSourceRoute.self) { route in
                destination(route)
            }
            #if os(tvOS)
            .defaultFocus($focusedOption, env.accountsEnabled ? .pairing : .m3u)
            #endif
        }
        .onAppear(perform: applyDebugScreen)
        .onChange(of: router.debugScreen) { applyDebugScreen() }   // debug hooks may arrive after appear
    }

    private func applyDebugScreen() {
        guard path.isEmpty else { return }
        switch router.debugScreen {
        case "addSource": path = [.m3u]
        case "addXtream": path = [.xtream]
        case "pairing" where env.accountsEnabled: path = [.pairing]
        default: break
        }
    }

    @ViewBuilder
    private func destination(_ route: AddSourceRoute) -> some View {
        switch route {
        case .m3u: AddSourceView(kind: .m3u)
        case .xtream: AddSourceView(kind: .xtream)
        case .pairing: PairingView()
        }
    }

    private var header: some View {
        VStack(spacing: 12) {
            Image(systemName: "play.tv.fill")
                .font(.system(size: Theme.isTV ? 96 : 60))
                .foregroundStyle(Theme.premiumGradient)
            LText("welcome_title", env.config.displayName).font(Theme.title).foregroundStyle(Theme.textPrimary).multilineTextAlignment(.center)
            LText("welcome_subtitle").font(Theme.body).foregroundStyle(Theme.textSecondary).multilineTextAlignment(.center)
            LText("legal_no_content").font(Theme.caption).foregroundStyle(Theme.textSecondary.opacity(0.8))
                .multilineTextAlignment(.center).padding(.top, 4)
        }
    }

    private var addOptions: some View {
        VStack(alignment: .leading, spacing: Theme.isTV ? 20 : 10) {
            LText("add_source").font(Theme.headline).foregroundStyle(Theme.textPrimary)
            #if os(tvOS)
            // QR pairing needs the backend (hidden while ACCOUNTS_ENABLED = NO / placeholder backend).
            if env.accountsEnabled {
                option(.pairing, icon: "qrcode", key: "add_source_qr")
            }
            #endif
            option(.m3u, icon: "list.bullet.rectangle", key: "add_source_m3u")
            option(.xtream, icon: "server.rack", key: "add_source_xtream")
        }
        #if os(tvOS)
        .focusSection()
        #endif
    }

    private func option(_ route: AddSourceRoute, icon: String, key: String) -> some View {
        Button { path.append(route) } label: {
            HStack(spacing: 16) {
                Image(systemName: icon).font(Theme.headline).foregroundStyle(Theme.primary).frame(width: Theme.isTV ? 56 : 32)
                LText(key).font(Theme.body.weight(.semibold)).foregroundStyle(Theme.textPrimary)
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(Theme.textSecondary)
            }
            .padding(Theme.isTV ? 28 : 16)
            .background(RoundedRectangle(cornerRadius: Theme.cardRadius).fill(Theme.surface))
        }
        .buttonStyle(CardButtonStyle())
        #if os(tvOS)
        .focused($focusedOption, equals: route)
        #endif
        .accessibilityIdentifier("add_\(key)")
    }
}

/// Trial information card (duration, what locks, one-time price) – SCREENS §3.1 / CONTRACT §7.5.
struct TrialCard: View {
    @Environment(AppEnvironment.self) private var env
    @State private var model: PaywallViewModel?

    var body: some View {
        let decision = env.license.decision
        VStack(alignment: .leading, spacing: Theme.isTV ? 20 : 12) {
            HStack {
                Image(systemName: "crown.fill").foregroundStyle(Theme.warning)
                LText("paywall_title", env.config.displayName).font(Theme.headline).foregroundStyle(Theme.textPrimary)
                Spacer()
                TrialChip()
            }
            switch decision.state {
            case .purchased:
                LText("purchase_owned").font(Theme.body).foregroundStyle(Theme.success)
            case .trialActive:
                if let end = decision.trialEndMs {
                    LText("trial_active_until", L10n.date(Date(timeIntervalSince1970: Double(end) / 1000), date: .abbreviated, time: .shortened))
                        .font(Theme.body).foregroundStyle(Theme.textSecondary)
                }
            case .trialExpired, .trialNotStarted:
                Text(L10n.plural("trial_info", env.license.trialDays, env.store.lifetimePrice ?? "…"))
                    .font(Theme.body).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) { trialButtons(decision) }
                    VStack(alignment: .leading, spacing: 10) { trialButtons(decision) }
                }
            }
            if decision.pendingPurchase {
                LText("purchase_pending").font(Theme.caption).foregroundStyle(Theme.warning)
            }
            if let message = model?.message {
                Text(message.arg.map { L10n.t(message.key, $0) } ?? L10n.t(message.key))
                    .font(Theme.caption).foregroundStyle(message.isError ? Theme.error : Theme.success)
            }
        }
        .padding(Theme.isTV ? 36 : 18)
        .background(RoundedRectangle(cornerRadius: Theme.cardRadius).fill(Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius).stroke(Theme.premiumGradient, lineWidth: 1))
        #if os(tvOS)
        .focusSection()
        #endif
        .onAppear { if model == nil { model = PaywallViewModel(env: env) } }
    }
}

extension TrialCard {
    @ViewBuilder
    fileprivate func trialButtons(_ decision: AccessDecision) -> some View {
        if decision.state == .trialNotStarted {
            Button(L10n.t("trial_start")) { Task { await model?.startTrial() } }
                .buttonStyle(PrimaryButtonStyle())
                .accessibilityIdentifier("trial_start")
        }
        Button(L10n.t("purchase_buy", env.store.lifetimePrice ?? "…")) { Task { await model?.buy() } }
            .buttonStyle(decision.state == .trialNotStarted ? AnyButtonStyle(SecondaryButtonStyle()) : AnyButtonStyle(PrimaryButtonStyle()))
        Button(L10n.t("purchase_restore")) { Task { await model?.restore() } }
            .buttonStyle(SecondaryButtonStyle())
    }
}

/// Type-erased button style.
struct AnyButtonStyle: ButtonStyle {
    private let make: (Configuration) -> AnyView
    init<S: ButtonStyle>(_ style: S) { make = { AnyView(style.makeBody(configuration: $0)) } }
    func makeBody(configuration: Configuration) -> some View { make(configuration) }
}
