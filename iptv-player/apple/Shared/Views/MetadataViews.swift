import IPTVCore
import IPTVKit
import SwiftUI

// TMDB metadata UI (CONTRACT §11): landscape backdrops, the cast row and the TMDB attribution. Everything here is
// optional decoration – without metadata the detail pages keep the provider's poster and fields.

extension MetadataLanguage {
    /// The metadata language of the current UI language (Settings → App language).
    static var ui: MetadataLanguage { MetadataLanguage(code: L10n.languageCode) }
}

/// Full-bleed 16:9 TMDB backdrop for the detail hero. Apple TV loads it at screen resolution (1920 px) and fades
/// it into the background on the left and bottom, where title, meta and the action row sit.
struct BackdropHero: View {
    let url: String
    let height: CGFloat

    var body: some View {
        ZStack {
            RemoteImage(url: url, maxPixel: Theme.isTV ? 1920 : 1280, placeholder: nil, background: Theme.surface)
                .frame(height: height)
                .frame(maxWidth: .infinity)
                .clipped()
            LinearGradient(stops: [.init(color: .black.opacity(0.35), location: 0), .init(color: .clear, location: 0.25),
                                   .init(color: Theme.bg.opacity(0.7), location: 0.72), .init(color: Theme.bg, location: 1)],
                           startPoint: .top, endPoint: .bottom)
            if Theme.isTV {
                LinearGradient(colors: [Theme.bg.opacity(0.9), Theme.bg.opacity(0.35), .clear], startPoint: .leading, endPoint: .center)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: height)
        .clipped()
        .accessibilityHidden(true)
    }
}

/// Horizontal cast row (billing order, round TMDB profile photos). Apple TV: every card is focusable so the row
/// scrolls with the remote; it is its own focus section, so ▲▼ leave it straight to the neighbouring row.
struct CastRow: View {
    let cast: [MetadataCastMember]

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.isTV ? 18 : 10) {
            Text(L10n.t("detail_cast_title"))
                .font(Theme.isTV ? Theme.body.weight(.bold) : .headline)
                .foregroundStyle(Theme.textPrimary)
                .accessibilityAddTraits(.isHeader)
                .padding(.horizontal, Theme.isTV ? Theme.safeH : 0)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: Theme.isTV ? 40 : 14) {
                    ForEach(Array(cast.enumerated()), id: \.offset) { _, member in
                        CastCard(member: member)
                    }
                }
                .padding(.horizontal, Theme.isTV ? Theme.safeH : 0)
                .padding(.vertical, Theme.isTV ? 24 : 2)
            }
            #if os(tvOS)
            .scrollClipDisabled()
            .focusSection()
            #endif
        }
        .accessibilityIdentifier("detail_cast_row")
    }
}

private struct CastCard: View {
    let member: MetadataCastMember
    #if os(tvOS)
    @FocusState private var focused: Bool
    #endif

    private var size: CGFloat { Theme.isTV ? 150 : 76 }

    var body: some View {
        VStack(spacing: Theme.isTV ? 12 : 6) {
            RemoteImage(url: member.profileUrl, maxPixel: Theme.isTV ? 300 : 200, placeholder: "person.fill")
                .frame(width: size, height: size)
                .clipShape(Circle())
                #if os(tvOS)
                .overlay(Circle().stroke(Color.white, lineWidth: focused ? 5 : 0))
                .scaleEffect(focused ? 1.12 : 1)
                .shadow(color: .black.opacity(focused ? 0.5 : 0), radius: 18, y: 10)
                .animation(.easeOut(duration: 0.15), value: focused)
                #endif
            VStack(spacing: 2) {
                Text(member.name)
                    .font(Theme.isTV ? Theme.caption.weight(.semibold) : .caption.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                if let character = member.character, !character.isEmpty {
                    Text(character)
                        .font(Theme.isTV ? .system(size: 20) : .caption2)
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            .lineLimit(2)
            .multilineTextAlignment(.center)
            .frame(width: size + (Theme.isTV ? 40 : 14))
        }
        #if os(tvOS)
        .focusable()
        .focused($focused)
        #endif
        .accessibilityElement(children: .combine)
    }
}

/// TMDB wordmark in TMDB's brand gradient – shown less prominently than the app's own branding (TMDB terms).
struct TMDBMark: View {
    var height: CGFloat = Theme.isTV ? 36 : 18

    var body: some View {
        Text(verbatim: "TMDB")
            .font(.system(size: height * 0.72, weight: .heavy, design: .rounded))
            .foregroundStyle(Color(red: 0x0D / 255, green: 0x25 / 255, blue: 0x3F / 255))
            .padding(.horizontal, height * 0.45)
            .frame(height: height)
            .background(Capsule().fill(LinearGradient(colors: [Color(red: 0x90 / 255, green: 0xCE / 255, blue: 0xA1 / 255),
                                                               Color(red: 0x01 / 255, green: 0xB4 / 255, blue: 0xE4 / 255)],
                                                      startPoint: .leading, endPoint: .trailing)))
            .accessibilityLabel(Text(verbatim: "The Movie Database"))
    }
}

/// Small "Info and images: TMDB" line under a detail page that shows TMDB data.
struct MetadataSourceLine: View {
    var body: some View {
        HStack(spacing: Theme.isTV ? 14 : 8) {
            Text(L10n.t("detail_metadata_source"))
                .font(Theme.isTV ? Theme.caption : .caption2)
                .foregroundStyle(Theme.textSecondary)
            TMDBMark(height: Theme.isTV ? 28 : 14)
                .accessibilityHidden(true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("detail_metadata_source")
    }
}

/// The page fields with TMDB first and the provider's values as fallback (CONTRACT §11).
struct DetailFields {
    var imageURL: String?
    var backdropURL: String?
    var rating: Double?
    var year: Int?
    var durationSec: Int?
    var genres: String?
    var plot: String?
    var trailerURL: URL?
    var cast: [MetadataCastMember]
    var usesMetadata: Bool

    init(metadata: MediaMetadata?, posterURL: String?, providerBackdrop: String? = nil, rating: Double?, year: Int?,
         durationSec: Int?, genres: String?, plot: String?, trailerURL: URL?) {
        let m = metadata
        imageURL = posterURL.flatMap { $0.isEmpty ? nil : $0 } ?? m?.posterUrl
        backdropURL = m?.backdropUrl ?? providerBackdrop.flatMap { $0.isEmpty ? nil : $0 }
        self.rating = m?.rating ?? rating
        self.year = year ?? m?.year
        self.durationSec = durationSec ?? m?.runtimeMinutes.map { $0 * 60 }
        self.genres = m.flatMap { $0.genres.isEmpty ? nil : $0.genres.joined(separator: ", ") } ?? genres
        self.plot = m?.overview.flatMap { $0.isEmpty ? nil : $0 } ?? plot
        self.trailerURL = trailerURL ?? m?.trailerURL
        cast = m?.cast ?? []
        usesMetadata = m != nil
    }
}
