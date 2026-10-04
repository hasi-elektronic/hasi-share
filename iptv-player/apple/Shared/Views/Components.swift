import CoreImage.CIFilterBuiltins
import IPTVCore
import IPTVKit
import SwiftUI

/// Remote image through `ImageLoader` (URLCache 200 MB + NSCache, downsampled).
struct RemoteImage: View {
    let url: String?
    var maxPixel: Int = 400
    var contentMode: ContentMode = .fill
    var placeholder: String = "photo"
    @State private var image: CGImage?

    var body: some View {
        ZStack {
            Theme.surface
            if let image {
                Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: contentMode)
            } else {
                Image(systemName: placeholder).font(Theme.isTV ? .largeTitle : .title2).foregroundStyle(Theme.textSecondary.opacity(0.5))
            }
        }
        .task(id: url) {
            guard let url, let u = URL(string: url) else { image = nil; return }
            if let hit = ImageLoader.shared.cached(u, maxPixel: maxPixel) { image = hit; return }
            image = await ImageLoader.shared.image(for: u, maxPixel: maxPixel)
        }
    }
}

/// 16:9 channel logo box (logo `fit`, surface background).
struct ChannelLogo: View {
    let url: String?
    var width: CGFloat = Theme.isTV ? 120 : 64

    var body: some View {
        RemoteImage(url: url, maxPixel: 256, contentMode: .fit, placeholder: "tv")
            .frame(width: width, height: width * 9 / 16)
            .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

/// 2:3 poster card.
struct PosterCard: View {
    let title: String
    let url: String?
    var progress: Double?
    var width: CGFloat = Theme.posterWidth

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            RemoteImage(url: url, maxPixel: 500, placeholder: "film")
                .frame(width: width, height: width * 1.5)
                .clipShape(RoundedRectangle(cornerRadius: Theme.posterRadius))
                .overlay(alignment: .bottom) {
                    if let progress, progress > 0 {
                        ProgressBar(value: progress).frame(height: 4).padding(6)
                    }
                }
            Text(title).font(Theme.caption).foregroundStyle(Theme.textPrimary).lineLimit(2)
                .frame(width: width, alignment: .leading)
        }
    }
}

struct ProgressBar: View {
    let value: Double
    var color: Color = Theme.primary

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.2))
                Capsule().fill(color).frame(width: g.size.width * min(1, max(0, value)))
            }
        }
    }
}

struct LiveBadge: View {
    var body: some View {
        LText("live_badge").font(.caption.bold()).foregroundStyle(.white)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 4).fill(Theme.live))
    }
}

/// Channel list row: number, logo, name, now programme + progress, next time.
struct ChannelRowView: View {
    let row: ChannelRow
    var isFavorite = false
    var timeFormatter: EpgTimeFormatter

    var body: some View {
        HStack(spacing: Theme.isTV ? 20 : 12) {
            Text(row.channel.number.map(String.init) ?? "")
                .font(Theme.caption.monospacedDigit()).foregroundStyle(Theme.textSecondary)
                .frame(width: Theme.isTV ? 60 : 34, alignment: .trailing)
            ChannelLogo(url: row.channel.logoUrl)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(row.channel.name).font(Theme.body.weight(.semibold)).foregroundStyle(Theme.textPrimary).lineLimit(1)
                    if isFavorite { Image(systemName: "star.fill").font(.caption).foregroundStyle(Theme.warning) }
                }
                if let now = row.nowNext?.now {
                    Text(now.title).font(Theme.caption).foregroundStyle(Theme.textSecondary).lineLimit(1)
                    ProgressBar(value: EpgSchedule.progress(of: now, at: Date())).frame(height: 3)
                } else {
                    LText("epg_no_info").font(Theme.caption).foregroundStyle(Theme.textSecondary.opacity(0.7))
                }
            }
            Spacer(minLength: 8)
            if let next = row.nowNext?.next {
                VStack(alignment: .trailing, spacing: 2) {
                    LText("epg_next").font(.caption2).foregroundStyle(Theme.textSecondary)
                    Text(timeFormatter.time(next.start)).font(Theme.caption.monospacedDigit()).foregroundStyle(Theme.textSecondary)
                }
            }
        }
        .padding(.vertical, Theme.isTV ? 10 : 6)
        .padding(.horizontal, Theme.isTV ? 16 : 0)
        .contentShape(Rectangle())
    }
}

/// Error card with the localized title/body/hint and actions (docs/SCREENS.md §4).
struct ErrorCardView: View {
    let presentation: ErrorPresentation
    var onAction: (ErrorAction) -> Void

    var body: some View {
        let text = L10n.error(presentation)
        VStack(spacing: Theme.isTV ? 20 : 12) {
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: Theme.isTV ? 56 : 36)).foregroundStyle(Theme.warning)
            Text(text.title).font(Theme.headline).foregroundStyle(Theme.textPrimary).multilineTextAlignment(.center)
            Text(text.body).font(Theme.body).foregroundStyle(Theme.textSecondary).multilineTextAlignment(.center)
            if let hint = text.hint {
                Text(hint).font(Theme.body.weight(.semibold)).foregroundStyle(Theme.primary).multilineTextAlignment(.center)
            }
            HStack(spacing: 16) {
                ForEach(Array(presentation.actions.enumerated()), id: \.offset) { index, action in
                    if index == 0 {
                        Button(L10n.actionTitle(action)) { onAction(action) }.buttonStyle(PrimaryButtonStyle())
                    } else {
                        Button(L10n.actionTitle(action)) { onAction(action) }.buttonStyle(SecondaryButtonStyle())
                    }
                }
            }
            .padding(.top, 8)
        }
        .padding(Theme.isTV ? 48 : 24)
        .frame(maxWidth: Theme.isTV ? 1000 : 520)
        .background(RoundedRectangle(cornerRadius: Theme.cardRadius).fill(Theme.surfaceElevated))
    }
}

/// QR code via CoreImage `CIQRCodeGenerator`.
struct QRCodeView: View {
    let text: String

    var body: some View {
        if let image = Self.make(text) {
            Image(decorative: image, scale: 1).interpolation(.none).resizable().scaledToFit()
                .padding(16).background(Color.white).clipShape(RoundedRectangle(cornerRadius: 12))
        } else {
            Color.white
        }
    }

    static func make(_ text: String) -> CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 12, y: 12)) else { return nil }
        return CIContext().createCGImage(output, from: output.extent)
    }
}

/// Horizontal chips (categories, seasons, sort).
struct ChipBar<ID: Hashable>: View {
    let items: [(id: ID, title: String)]
    @Binding var selection: ID

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Theme.isTV ? 16 : 8) {
                ForEach(items, id: \.id) { item in
                    Button { selection = item.id } label: {
                        Text(item.title).font(Theme.caption.weight(.medium)).lineLimit(1)
                            .foregroundStyle(selection == item.id ? .white : Theme.textPrimary)
                            .padding(.horizontal, Theme.isTV ? 24 : 14).padding(.vertical, Theme.isTV ? 12 : 7)
                            .background(Capsule().fill(selection == item.id ? Theme.primary : Theme.surface))
                    }
                    .buttonStyle(CardButtonStyle())
                }
            }
            .padding(.horizontal, Theme.safeH)
            .padding(.vertical, Theme.isTV ? 16 : 4)
        }
    }
}

/// Trial status chip ("Trial: 5 days left").
struct TrialChip: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        let decision = env.license.decision
        Group {
            switch decision.state {
            case .trialActive:
                let remaining = decision.remainingTrialMs(nowMs: env.license.nowMs()) ?? 0
                let days = Int(remaining / 86_400_000)
                chip(days >= 1 ? L10n.plural("trial_chip_days", days) : L10n.t("trial_chip_hours", String(max(1, remaining / 3_600_000))), Theme.primary)
            case .trialExpired:
                chip(L10n.t("trial_chip_expired"), Theme.live)
            case .purchased, .trialNotStarted:
                EmptyView()
            }
        }
    }

    private func chip(_ text: String, _ color: Color) -> some View {
        Text(text).font(Theme.caption.weight(.semibold)).foregroundStyle(.white)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(Capsule().fill(color.opacity(0.85)))
    }
}

/// Section header + horizontal shelf.
struct Shelf<Content: View>: View {
    let title: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.isTV ? 16 : 8) {
            Text(title).font(Theme.headline).foregroundStyle(Theme.textPrimary).padding(.horizontal, Theme.safeH)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: Theme.isTV ? 40 : 12) { content() }
                    .padding(.horizontal, Theme.safeH)
                    .padding(.vertical, Theme.isTV ? 24 : 0)
            }
            #if os(tvOS)
            .focusSection()
            #endif
        }
    }
}

/// Empty state.
struct EmptyStateView: View {
    let icon: String
    let text: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: Theme.isTV ? 64 : 40)).foregroundStyle(Theme.textSecondary.opacity(0.6))
            Text(text).font(Theme.body).foregroundStyle(Theme.textSecondary).multilineTextAlignment(.center)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension AppEnvironment {
    /// EPG time formatter honouring the settings (time zone, 24 h).
    var timeFormatter: EpgTimeFormatter {
        EpgTimeFormatter(timeZone: settings.timeZone, locale: .current, use24Hour: settings.use24Hour)
    }
}
