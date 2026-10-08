import CoreImage.CIFilterBuiltins
import IPTVCore
import IPTVKit
import SwiftUI

/// Remote image through `ImageLoader` (URLCache 200 MB + NSCache, downsampled).
struct RemoteImage: View {
    let url: String?
    var maxPixel: Int = 400
    var contentMode: ContentMode = .fill
    var placeholder: String? = "photo"
    var background: Color = Theme.surface
    @State private var image: CGImage?

    var body: some View {
        ZStack {
            background
            if let image {
                Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: contentMode)
            } else if let placeholder {
                Image(systemName: placeholder).font(Theme.isTV ? .largeTitle : .title2).foregroundStyle(Theme.textSecondary.opacity(0.5))
                    .accessibilityHidden(true)   // IOS-18: no "Fernseher" / "Film" for a missing logo
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

/// Colored channel tile with the logo large and centered (color derived from the channel name).
/// Without a logo the channel name is drawn in bold white.
struct ChannelTile: View {
    let channel: Channel
    var width: CGFloat
    var height: CGFloat
    var radius: CGFloat = Theme.cardRadius

    var body: some View {
        let color = Theme.channelColor(channel.name)
        ZStack {
            LinearGradient(colors: [color, color.opacity(0.72)], startPoint: .topLeading, endPoint: .bottomTrailing)
            if channel.logoUrl != nil {
                RemoteImage(url: channel.logoUrl, maxPixel: 300, contentMode: .fit, placeholder: nil, background: .clear)
                    .padding(.horizontal, width * 0.16)
                    .padding(.vertical, height * 0.16)
            } else {
                Text(Self.initials(channel.name))
                    .font(.system(size: min(height * 0.36, width * 0.22), weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .padding(.horizontal, 8)
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .accessibilityHidden(true)
    }

    /// "Apple BipBop 4x3" → "ABB", "ZDF" → "ZDF".
    static func initials(_ name: String) -> String {
        let words = name.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).filter { !$0.isEmpty }
        if words.count == 1 { return String(words[0].prefix(4)).uppercased() }
        return String(words.prefix(3).compactMap(\.first)).uppercased()
    }
}

/// Small rounded label used on artwork corners ("HD", "4K", catch-up…).
struct CornerBadge: View {
    var text: String?
    var icon: String?
    var color: Color = .black.opacity(0.55)

    var body: some View {
        Group {
            if let icon {
                Image(systemName: icon).font(.system(size: Theme.isTV ? 20 : 10, weight: .bold))
            } else if let text {
                Text(text).font(.system(size: Theme.isTV ? 18 : 10, weight: .heavy))
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, Theme.isTV ? 9 : 5)
        .frame(minWidth: Theme.isTV ? 36 : 20, minHeight: Theme.isTV ? 32 : 18)
        .background(RoundedRectangle(cornerRadius: Theme.isTV ? 8 : 5, style: .continuous).fill(color))
    }
}

/// Quality / format tags derived from names and container extensions.
enum MediaTags {
    /// "4K", "UHD", "FHD", "HD" or "SD" when the name says so.
    static func quality(in name: String) -> String? {
        let tokens = Set(name.uppercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
        for tag in ["4K", "UHD", "FHD", "HD", "SD"] where tokens.contains(tag) { return tag }
        if tokens.contains("2160P") { return "4K" }
        if tokens.contains("1080P") { return "FHD" }
        if tokens.contains("720P") { return "HD" }
        return nil
    }

    /// Display title without year / quality decorations: "Night Shift (2024) HD" → ("Night Shift", 2024).
    static func clean(_ name: String) -> (title: String, year: Int?) {
        var title = name
        var year: Int?
        if let r = title.range(of: #"[\(\[]((19|20)\d{2})[\)\]]"#, options: .regularExpression) {
            year = Int(title[r].filter(\.isNumber))
            title.removeSubrange(r)
        }
        let tags: Set<String> = ["HD", "FHD", "UHD", "4K", "SD", "HEVC", "H265", "H264", "1080P", "720P", "2160P"]
        var words = title.split(separator: " ").map(String.init)
        while let last = words.last, tags.contains(last.uppercased()) || last == "-" || last == "|" { words.removeLast() }
        title = words.joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return (title.isEmpty ? name : title, year)
    }

    /// "Mountain Patrol S01E01 First Snow" → "First Snow" (M3U episode titles repeat series + code).
    static func episodeTitle(_ title: String, seriesName: String) -> String {
        var t = title
        if !seriesName.isEmpty, t.lowercased().hasPrefix(seriesName.lowercased()) { t = String(t.dropFirst(seriesName.count)) }
        if let r = t.range(of: #"^\s*[-–:]?\s*S\d{1,3}\s*E\d{1,4}\s*[-–:]?\s*"#, options: [.regularExpression, .caseInsensitive]) {
            t.removeSubrange(r)
        }
        t = t.trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? title : t
    }

    /// "MKV · HD" format pill text.
    static func format(container: String?, name: String) -> String? {
        let parts = [container?.uppercased(), quality(in: name)].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// Channel card for home rows: colored tile, badges, programme progress, programme + channel name.
struct ChannelCard: View {
    let row: ChannelRow
    var width: CGFloat = Theme.isTV ? 330 : 168
    var isFavorite = false

    var body: some View {
        let height = width * 0.6
        VStack(alignment: .leading, spacing: Theme.isTV ? 12 : 6) {
            ChannelTile(channel: row.channel, width: width, height: height)
                .overlay(alignment: .topTrailing) {
                    VStack(spacing: 4) {
                        if let q = MediaTags.quality(in: row.channel.name) { CornerBadge(text: q) }
                        if row.channel.catchup.isAvailable {
                            CornerBadge(icon: "clock.arrow.circlepath").accessibilityLabel(L10n.t("epg_catchup_available"))
                        }
                        if isFavorite { CornerBadge(icon: "star.fill", color: Theme.warning.opacity(0.9)) }
                    }
                    .padding(Theme.isTV ? 10 : 6)
                }
                .overlay(alignment: .bottom) {
                    if let now = row.nowNext?.now {
                        ProgressBar(value: EpgSchedule.progress(of: now, at: Date()), color: .white)
                            .frame(height: Theme.isTV ? 5 : 3)
                            .padding(.horizontal, Theme.isTV ? 14 : 8)
                            .padding(.bottom, Theme.isTV ? 10 : 6)
                    }
                }
                .modifier(TVFocusCard())
            VStack(alignment: .leading, spacing: 2) {
                Text(row.nowNext?.now?.title ?? row.channel.name)
                    .font(Theme.isTV ? Theme.caption.weight(.semibold) : .subheadline.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary).lineLimit(1)
                Text(row.nowNext?.now == nil ? L10n.t("epg_no_info") : row.channel.name)
                    .font(Theme.isTV ? .system(size: 21) : .caption)
                    .foregroundStyle(Theme.textSecondary).lineLimit(1)
            }
            .frame(width: width, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel([row.channel.name, row.nowNext?.now?.title].compactMap { $0 }.joined(separator: ", "))
    }
}

/// Wide 16:9 artwork card (continue watching): cropped poster, progress at the bottom, corner badge.
struct WideArtworkCard: View {
    let title: String
    var subtitle: String?
    let imageURL: String?
    var progress: Double?
    var badgeIcon: String?
    var width: CGFloat = Theme.isTV ? 520 : 260

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.isTV ? 12 : 6) {
            ZStack(alignment: .bottom) {
                RemoteImage(url: imageURL, maxPixel: 700, placeholder: "film")
                    .frame(width: width, height: width * 9 / 16, alignment: .top)
                    .clipped()
                LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .center, endPoint: .bottom)
                if let progress, progress > 0 {
                    ProgressBar(value: progress).frame(height: Theme.isTV ? 6 : 4)
                        .padding(.horizontal, Theme.isTV ? 16 : 10).padding(.bottom, Theme.isTV ? 14 : 9)
                }
            }
            .frame(width: width, height: width * 9 / 16)
            .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
            .overlay(alignment: .topTrailing) {
                if let badgeIcon { CornerBadge(icon: badgeIcon, color: Theme.primary.opacity(0.9)).padding(Theme.isTV ? 12 : 8) }
            }
            .modifier(TVFocusCard())
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Theme.isTV ? Theme.caption.weight(.semibold) : .subheadline.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary).lineLimit(1)
                if let subtitle {
                    Text(subtitle).font(Theme.isTV ? .system(size: 21) : .caption).foregroundStyle(Theme.textSecondary).lineLimit(1)
                }
            }
            .frame(width: width, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }
}

/// 2:3 poster card.
struct PosterCard: View {
    let title: String
    let url: String?
    var progress: Double?
    var subtitle: String?
    /// Fixed width, or `nil` to fill the grid cell (2:3).
    var width: CGFloat? = Theme.posterWidth
    var isNew = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.isTV ? 12 : 6) {
            Color.clear
                .frame(width: width, height: width.map { $0 * 1.5 })
                .aspectRatio(2 / 3, contentMode: .fit)
                .overlay(RemoteImage(url: url, maxPixel: 500, placeholder: "film"))
                .clipShape(RoundedRectangle(cornerRadius: Theme.posterRadius, style: .continuous))
                .overlay(alignment: .bottom) {
                    if let progress, progress > 0 {
                        ProgressBar(value: progress).frame(height: 4).padding(8)
                    } else if isNew {
                        NewBadge().padding(.bottom, Theme.isTV ? 12 : 7)
                    }
                }
                .overlay(alignment: .top) {
                    if url == nil {
                        Text(title).font(Theme.isTV ? Theme.caption.weight(.bold) : .caption.weight(.bold))
                            .foregroundStyle(Theme.textPrimary.opacity(0.8)).multilineTextAlignment(.center)
                            .lineLimit(3).padding(10).padding(.bottom, 8)
                    }
                }
                .modifier(TVFocusCard(radius: Theme.posterRadius))
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(Theme.isTV ? Theme.caption : .caption.weight(.medium)).foregroundStyle(Theme.textPrimary).lineLimit(1)
                if let subtitle {
                    Text(subtitle).font(Theme.isTV ? .system(size: 20) : .caption2).foregroundStyle(Theme.textSecondary).lineLimit(1)
                }
            }
            .frame(width: width, alignment: .leading)
            .frame(maxWidth: width == nil ? .infinity : nil, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }
}

struct ProgressBar: View {
    let value: Double
    var color: Color = Theme.primary

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.25))
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
                    .accessibilityIdentifier("error_hint")
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

/// Horizontal filter chips (categories with country flags, seasons, favorites…).
struct ChipBar<ID: Hashable>: View {
    let items: [(id: ID, title: String)]
    @Binding var selection: ID
    var showFlags = false
    var leadingIcon: ((ID) -> String?)? = nil
    var identifierPrefix = "chip"
    /// Accessibility id per item (default: `<identifierPrefix>_<index>`).
    var identifier: ((ID) -> String)? = nil

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Theme.isTV ? 16 : 8) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    let selected = selection == item.id
                    Button { selection = item.id } label: {
                        HStack(spacing: Theme.isTV ? 10 : 6) {
                            if let icon = leadingIcon?(item.id) {
                                Image(systemName: icon).font(Theme.isTV ? .system(size: 22, weight: .semibold) : .caption.weight(.semibold))
                            } else if showFlags, let flag = CountryFlag.emoji(for: item.title) {
                                Text(flag)
                            }
                            Text(showFlags ? CountryFlag.strippedTitle(item.title) : item.title)
                                .lineLimit(1)
                        }
                        .font(Theme.isTV ? Theme.caption.weight(.medium) : .subheadline.weight(.medium))
                        .foregroundStyle(selected ? Color.black : Theme.textPrimary)
                        .padding(.horizontal, Theme.isTV ? 26 : 14).padding(.vertical, Theme.isTV ? 12 : 8)
                        .background(Capsule().fill(selected ? Color.white : Theme.surface))
                        .overlay(Capsule().stroke(selected ? Color.clear : Theme.stroke, lineWidth: 1))
                    }
                    .buttonStyle(CardButtonStyle(radius: 40, scale: 1.1))
                    .accessibilityIdentifier(identifier?(item.id) ?? "\(identifierPrefix)_\(index)")
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
            .padding(.horizontal, Theme.safeH)
            .padding(.vertical, Theme.isTV ? 18 : 4)
        }
        #if os(tvOS)
        .focusSection()
        #endif
    }
}

/// Flag emoji for category names that contain a country name or code ("DE | Sport", "Germany", "TÜRKİYE").
/// The detection lives in IPTVKit (`CategoryCountry`, unit-tested); this is the view-side shorthand.
enum CountryFlag {
    static func code(for title: String) -> String? { CategoryCountry.code(for: title) }

    static func emoji(for title: String) -> String? { CategoryCountry.emoji(for: title) }

    /// Removes a leading code prefix ("DE | Sport" → "Sport") so the flag is not repeated.
    static func strippedTitle(_ title: String) -> String { CategoryCountry.strippedTitle(title) }

    /// "🇹🇷 DİZİLER" – flag (when a country is detected) + name without its code prefix.
    static func displayTitle(_ title: String) -> String {
        [emoji(for: title), strippedTitle(title)].compactMap { $0 }.joined(separator: " ")
    }

    /// Name of a group code in the UI language: regions "TR" → "Türkiye" / "Türkei", language groups
    /// "EN" → "English" / "İngilizce", "AR" → "Arabisch" (CategoryCountry.displayName).
    static func countryName(_ code: String) -> String {
        CategoryCountry.displayName(of: code, locale: L10n.locale)
    }

    /// Category as a genre (hero / detail line): the name without its group prefix ("EN | Amazon Prime" →
    /// "Amazon Prime", "TR | DİZİLER" → "DİZİLER").
    static func genreName(_ title: String) -> String {
        code(for: title) == nil ? title : CategoryCountry.nameWithoutPrefix(title)
    }

    /// "🇹🇷 " for real regions, "" for language groups / tags (no 🇦🇷 for "AR").
    static func flagPrefix(_ code: String) -> String {
        CategoryCountry.flagEmoji(forCode: code).map { "\($0) " } ?? ""
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
        // Never truncated (German "Testphase: noch 4 Tage" is long); neighbours wrap instead.
        Text(text).font(Theme.caption.weight(.semibold)).foregroundStyle(.white).lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(Capsule().fill(color.opacity(0.85)))
    }
}

/// Row title used above shelves.
struct RowTitle: View {
    let title: String

    var body: some View {
        Text(title).font(Theme.rowTitle).foregroundStyle(Theme.textPrimary).lineLimit(1)
            .accessibilityAddTraits(.isHeader)
    }
}

/// Section header + horizontal shelf; optional "See all" (header link on iPhone/iPad, trailing card on TV).
struct Shelf<Content: View>: View {
    let title: String
    var spacing: CGFloat = Theme.shelfSpacing
    var seeAll: BrowseRoute? = nil
    /// Label of the "See all" link (search sections: "Show all").
    var seeAllTitleKey = "action_see_all"
    var identifier: String? = nil
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.isTV ? 4 : 10) {
            HStack(alignment: .firstTextBaseline) {
                RowTitle(title: title)
                Spacer(minLength: 12)
                #if !os(tvOS)
                if let seeAll {
                    NavigationLink(value: seeAll) {
                        LText(seeAllTitleKey).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.primary)
                    }
                    .accessibilityIdentifier("see_all_\(identifier ?? title)")
                }
                #endif
            }
            .padding(.horizontal, Theme.safeH)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: spacing) {
                    content()
                    #if os(tvOS)
                    if let seeAll {
                        NavigationLink(value: seeAll) {
                            VStack(spacing: 12) {
                                Image(systemName: "square.grid.2x2").font(.system(size: 44, weight: .semibold))
                                LText(seeAllTitleKey).font(Theme.caption.weight(.semibold))
                            }
                            .foregroundStyle(Theme.textPrimary)
                            .frame(width: 220, height: 220)
                            .background(RoundedRectangle(cornerRadius: Theme.cardRadius).fill(Theme.surface))
                            .modifier(TVFocusCard())
                        }
                        .buttonStyle(ArtworkButtonStyle())
                        .accessibilityIdentifier("see_all_\(identifier ?? title)")
                    }
                    #endif
                }
                .padding(.horizontal, Theme.safeH)
                .padding(.vertical, Theme.isTV ? 30 : 0)
            }
            #if os(tvOS)
            .scrollClipDisabled()
            .focusSection()
            #endif
        }
    }
}

/// Small accent badge on posters ("NEW").
struct NewBadge: View {
    var body: some View {
        LText("badge_new").font(.system(size: Theme.isTV ? 17 : 9, weight: .heavy)).foregroundStyle(.white)
            .padding(.horizontal, Theme.isTV ? 10 : 6).padding(.vertical, Theme.isTV ? 4 : 3)
            .background(RoundedRectangle(cornerRadius: Theme.isTV ? 6 : 4, style: .continuous).fill(Theme.primary))
    }
}

/// Round play symbol (continue cards, detail hero, episode thumbnails).
struct PlayCircle: View {
    var size: CGFloat = Theme.isTV ? 72 : 40

    var body: some View {
        Image(systemName: "play.fill")
            .font(.system(size: size * 0.38, weight: .bold))
            .foregroundStyle(.white)
            .offset(x: size * 0.04)
            .frame(width: size, height: size)
            .background(Circle().fill(.black.opacity(0.35)))
            .overlay(Circle().stroke(.white, lineWidth: max(2, size * 0.06)))
            .accessibilityHidden(true)
    }
}

/// "Continue watching" card: 16:9 artwork, centered play icon, title on the image bottom,
/// accent progress bar under the card (SCREENS §3.2; hidden while the duration is unknown).
struct ContinueCard: View {
    let title: String
    var subtitle: String?
    let imageURL: String?
    var progress: Double?
    /// false while the duration is unknown (the bar would be meaningless).
    var showsProgress = true
    var width: CGFloat = Theme.isTV ? 480 : 250

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.isTV ? 8 : 5) {
            ZStack(alignment: .bottomLeading) {
                RemoteImage(url: imageURL, maxPixel: 700, placeholder: "film")
                    .frame(width: width, height: width * 9 / 16, alignment: .top)
                    .clipped()
                LinearGradient(colors: [.clear, .black.opacity(0.75)], startPoint: .center, endPoint: .bottom)
                PlayCircle().frame(maxWidth: .infinity, maxHeight: .infinity)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(Theme.isTV ? Theme.caption.weight(.bold) : .subheadline.weight(.bold)).lineLimit(1)
                    if let subtitle {
                        Text(subtitle).font(Theme.isTV ? .system(size: 20) : .caption2).foregroundStyle(.white.opacity(0.75)).lineLimit(1)
                    }
                }
                .foregroundStyle(.white)
                .padding(.horizontal, Theme.isTV ? 16 : 10).padding(.bottom, Theme.isTV ? 12 : 8)
            }
            .frame(width: width, height: width * 9 / 16)
            .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
            .modifier(TVFocusCard())
            // Unknown duration: no bar, same height (CONTRACT §8).
            ProgressBar(value: progress ?? 0).frame(width: width, height: Theme.isTV ? 5 : 3).opacity(showsProgress ? 1 : 0)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Top-10 poster: large outlined rank number behind the poster.
struct RankedPosterCard: View {
    let rank: Int
    let title: String
    let url: String?
    var width: CGFloat = Theme.isTV ? 220 : 112

    var body: some View {
        let numberSize = width * 1.25
        HStack(alignment: .bottom, spacing: -width * 0.22) {
            OutlinedText(text: "\(rank)", size: numberSize)
                .frame(width: rank >= 10 ? width * 1.25 : width * 0.72, alignment: .trailing)
                .offset(y: numberSize * 0.12)
            PosterCard(title: title, url: url, width: width)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(rank). \(title)")
    }
}

/// Text drawn as outline only (rank numbers).
struct OutlinedText: View {
    let text: String
    let size: CGFloat

    var body: some View {
        let font = Font.system(size: size, weight: .heavy, design: .rounded)
        let w = max(1.5, size * 0.018)
        ZStack {
            ForEach(0..<8, id: \.self) { i in
                let a = Double(i) * .pi / 4
                Text(text).font(font).foregroundStyle(Theme.textSecondary.opacity(0.85))
                    .offset(x: cos(a) * w, y: sin(a) * w)
            }
            Text(text).font(font).foregroundStyle(Theme.bg)
        }
        .fixedSize()
        .accessibilityHidden(true)
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
    /// EPG time formatter honouring the settings (time zone, 24 h) – one cached instance (P1: no two
    /// `DateFormatter`s per row / EPG block), rebuilt when the zone, language or clock setting changes.
    var timeFormatter: EpgTimeFormatter {
        EpgTimeFormatter.cached(timeZone: settings.timeZone, locale: L10n.locale, use24Hour: settings.use24Hour)
    }

    /// Category name for a catalog item (shown as genre line).
    func categoryName(sourceId: String, kind: CategoryKind, id: String?) -> String? {
        guard let id else { return nil }
        return (try? catalog.categories(sourceId: sourceId, kind: kind))?.first(where: { $0.id == id })?.name
    }
}
