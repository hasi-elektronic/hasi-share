import IPTVKit
import SwiftUI

#if canImport(CNovaRemux)
/// Text subtitles of the "Apple + Remux" engine (Build 21): the local HLS carries none, so the cues the remuxer
/// read are drawn here, polled 10× a second against the player time, in the user's subtitle style
/// (size / colour / background, SCREENS §3.7). Other engines draw their own subtitles – this view is empty then.
struct RemuxSubtitleOverlay: View {
    let player: PlayerController

    #if os(tvOS)
    private static let baseSize: CGFloat = 46
    private static let bottomPadding: CGFloat = 70
    #else
    private static let baseSize: CGFloat = 20
    private static let bottomPadding: CGFloat = 28
    #endif

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.1)) { _ in
            let texts = (player.engine as? RemuxPlaybackEngine)?.subtitleTexts() ?? []
            VStack(spacing: 0) {
                Spacer()
                // Always in the tree (no `if`): an inserted view would fade in with the player's running animations
                // and never become visible at 10 updates/s. Empty → hidden.
                Self.styled(texts.joined(separator: "\n"), style: player.subtitleStyle)
                    .opacity(texts.isEmpty ? 0 : 1)
            }
            .transaction { $0.animation = nil }
            .padding(.horizontal, 40)
            .padding(.bottom, Self.bottomPadding)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    static func styled(_ text: String, style: SubtitleStyle) -> some View {
        let size = baseSize * SubtitleStyleMapping.relativeFontSizePercent(style.size) / 100
        let fg = SubtitleStyleMapping.foregroundARGB(style.color)
        let bg = SubtitleStyleMapping.backgroundARGB(style.background)
        return Text(attributed(text))
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(Color(red: fg[1], green: fg[2], blue: fg[3], opacity: fg[0]))
            .multilineTextAlignment(.center)
            .shadow(color: .black.opacity(bg == nil ? 0.9 : 0), radius: 2, x: 0, y: 1)
            .padding(.horizontal, bg == nil ? 0 : 10)
            .padding(.vertical, bg == nil ? 0 : 4)
            .background(bg.map { Color(red: $0[1], green: $0[2], blue: $0[3], opacity: $0[0]) } ?? .clear,
                        in: RoundedRectangle(cornerRadius: 4))
    }

    /// `<i>…</i>` spans → italic; everything else plain.
    static func attributed(_ text: String) -> AttributedString {
        var out = AttributedString()
        var italic = false
        var rest = Substring(text)
        while !rest.isEmpty {
            let tag = italic ? "</i>" : "<i>"
            let range = rest.range(of: tag)
            var piece = AttributedString(String(rest[..<(range?.lowerBound ?? rest.endIndex)]))
            if italic { piece.inlinePresentationIntent = .emphasized }
            out += piece
            guard let range else { break }
            italic.toggle()
            rest = rest[range.upperBound...]
        }
        return out
    }
}
#else
struct RemuxSubtitleOverlay: View {
    let player: PlayerController
    var body: some View { EmptyView() }
}
#endif
