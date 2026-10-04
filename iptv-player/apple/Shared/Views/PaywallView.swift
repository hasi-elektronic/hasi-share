import IPTVCore
import IPTVKit
import SwiftUI

/// Paywall (SCREENS §3.8): one-time purchase, status card, buy / restore, terms & privacy,
/// optional account hint for cross-platform purchases.
struct PaywallView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @State private var model: PaywallViewModel?

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.isTV ? 32 : 18) {
                Image(systemName: "crown.fill").font(.system(size: Theme.isTV ? 90 : 56)).foregroundStyle(Theme.premiumGradient)
                LText("paywall_title", env.config.displayName).font(Theme.title).foregroundStyle(Theme.textPrimary).multilineTextAlignment(.center)
                LText("paywall_subtitle").font(Theme.body).foregroundStyle(Theme.textSecondary)
                VStack(alignment: .leading, spacing: 10) {
                    benefit("infinity", "paywall_benefit_1")
                    benefit("iphone.and.arrow.forward", "paywall_benefit_2")
                    benefit("checkmark.seal", "paywall_benefit_3")
                }
                .padding(Theme.isTV ? 28 : 16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: Theme.cardRadius).fill(Theme.surface))
                statusCard
                buttons
                if env.license.serverUnreachable {
                    LText("license_server_unreachable").font(Theme.caption).foregroundStyle(Theme.warning)
                }
                if let message = model?.message {
                    Text(message.arg.map { L10n.t(message.key, $0) } ?? L10n.t(message.key))
                        .font(Theme.body).foregroundStyle(message.isError ? Theme.error : Theme.success)
                        .accessibilityIdentifier("paywall_message")
                }
                LText("paywall_other_platform").font(Theme.caption).foregroundStyle(Theme.textSecondary).multilineTextAlignment(.center)
                HStack(spacing: 24) {
                    LText("terms").font(Theme.caption).foregroundStyle(Theme.primary)
                    LText("privacy").font(Theme.caption).foregroundStyle(Theme.primary)
                }
            }
            .padding(.horizontal, Theme.safeH)
            .padding(.vertical, Theme.safeV + 10)
            .frame(maxWidth: Theme.isTV ? 1100 : 560)
            .frame(maxWidth: .infinity)
        }
        .screenBackground()
        .overlay(alignment: .topTrailing) {
            #if os(iOS)
            Button { dismiss() } label: { Image(systemName: "xmark.circle.fill").font(.title) }
                .foregroundStyle(Theme.textSecondary).padding()
                .accessibilityLabel(L10n.t("action_close"))
                .accessibilityIdentifier("paywall_close")
            #endif
        }
        .onAppear { if model == nil { model = PaywallViewModel(env: env) } }
        #if os(tvOS)
        .onExitCommand { dismiss() }
        #endif
    }

    private func benefit(_ icon: String, _ key: String) -> some View {
        Label { LText(key).font(Theme.body).foregroundStyle(Theme.textPrimary) } icon: { Image(systemName: icon).foregroundStyle(Theme.primary) }
    }

    private var statusCard: some View {
        let d = env.license.decision
        let (text, color): (String, Color) = {
            if d.pendingPurchase, d.state != .purchased { return (L10n.t("purchase_pending"), Theme.warning) }
            switch d.state {
            case .purchased: return (L10n.t("purchase_owned"), Theme.success)
            case .trialActive:
                return (L10n.t("trial_remaining", L10n.duration(ms: d.remainingTrialMs(nowMs: env.license.nowMs()) ?? 0)), Theme.primary)
            case .trialExpired: return (L10n.t("trial_expired"), Theme.live)
            case .trialNotStarted: return (L10n.t("trial_not_started"), Theme.textSecondary)
            }
        }()
        return Text(text).font(Theme.headline).foregroundStyle(color)
            .padding(Theme.isTV ? 24 : 14).frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: Theme.cardRadius).stroke(color.opacity(0.6), lineWidth: 1.5))
            .accessibilityIdentifier("paywall_status")
    }

    @ViewBuilder
    private var buttons: some View {
        let d = env.license.decision
        VStack(spacing: 12) {
            if d.state != .purchased {
                Button(L10n.t("purchase_buy", env.store.lifetimePrice ?? "…")) { Task { await model?.buy() } }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(model?.busy == true)
                    .accessibilityIdentifier("purchase_buy")
                if d.state == .trialNotStarted {
                    Button(L10n.t("trial_start")) { Task { await model?.startTrial() } }
                        .buttonStyle(SecondaryButtonStyle())
                        .accessibilityIdentifier("trial_start")
                }
            }
            Button(L10n.t("purchase_restore")) { Task { await model?.restore() } }
                .buttonStyle(SecondaryButtonStyle())
                .accessibilityIdentifier("purchase_restore")
            if model?.busy == true { ProgressView() }
        }
    }
}
