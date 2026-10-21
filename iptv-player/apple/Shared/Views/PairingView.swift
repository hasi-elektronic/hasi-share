import IPTVCore
import IPTVKit
import SwiftUI

/// TV: "Add with phone" – big QR + short code + URL + 10 min countdown (SCREENS §3.1, CONTRACT §9).
struct PairingView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var manager: PairingManager?

    var body: some View {
        Group {
            if let manager {
                switch manager.state {
                case .idle, .creating:
                    ProgressView()
                case let .waiting(code, pairUrl, expiresAt):
                    waiting(code: code, pairUrl: pairUrl, expiresAt: expiresAt)
                case .received(let payload):
                    AddSourceView(kind: payload.secrets.type == .xtream ? .xtream : .m3u, payload: payload)
                case .expired:
                    VStack(spacing: 24) {
                        LText("pair_expired").font(Theme.headline).foregroundStyle(Theme.textPrimary)
                        Button(L10n.t("action_new_code")) { manager.start() }.buttonStyle(PrimaryButtonStyle())
                    }
                case .failed:
                    ErrorCardView(presentation: SourceError.network(.other).presentation()) { _ in manager.start() }
                }
            } else {
                ProgressView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .screenBackground()
        .onAppear {
            if manager == nil {
                let m = PairingManager(backend: env.backend)
                manager = m
                m.start()
            }
        }
        .onDisappear { if case .received? = manager?.state {} else { manager?.cancel() } }
    }

    private func waiting(code: String, pairUrl: String, expiresAt: Date) -> some View {
        let base = env.config.backendBaseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/pair"
        return HStack(spacing: Theme.isTV ? 80 : 24) {
            QRCodeView(text: pairUrl).frame(width: Theme.isTV ? 460 : 220, height: Theme.isTV ? 460 : 220)
                .accessibilityLabel(pairUrl)
            VStack(alignment: .leading, spacing: Theme.isTV ? 28 : 12) {
                LText("pair_title").font(Theme.title).foregroundStyle(Theme.textPrimary)
                LText("pair_step1", base).font(Theme.body).foregroundStyle(Theme.textSecondary)
                LText("pair_step2", PairCode.display(code)).font(Theme.body).foregroundStyle(Theme.textSecondary)
                Text(PairCode.display(code)).font(.system(size: Theme.isTV ? 96 : 44, weight: .heavy, design: .monospaced))
                    .foregroundStyle(Theme.textPrimary)
                    .accessibilityIdentifier("pair_code")
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let left = max(0, Int(expiresAt.timeIntervalSince(context.date)))
                    LText("pair_expires_in", String(format: "%d:%02d", left / 60, left % 60))
                        .font(Theme.body.monospacedDigit()).foregroundStyle(left < 60 ? Theme.warning : Theme.textSecondary)
                }
                Label(L10n.t("pair_e2e"), systemImage: "lock.fill").font(Theme.caption).foregroundStyle(Theme.success)
            }
        }
        .padding(.horizontal, Theme.safeH)
    }
}
