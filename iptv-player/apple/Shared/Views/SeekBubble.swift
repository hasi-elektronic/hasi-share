import CoreGraphics
import IPTVKit
import SwiftUI

/// Seek target above the timeline (docs/SCREENS.md §3.7): optional preview thumbnail, target time and
/// the jump ("1:23:40 · +2:30"). tvOS while ◀▶ / a swipe moves the target, iOS while the scrubber is dragged.
struct SeekBubble: View {
    let target: Double
    let delta: Double
    var thumbnail: CGImage?

    #if os(tvOS)
    private static let thumbWidth: CGFloat = 320
    private static let font = Font.system(size: 34, weight: .bold).monospacedDigit()
    #else
    private static let thumbWidth: CGFloat = 160
    private static let font = Font.subheadline.monospacedDigit().weight(.semibold)
    #endif

    private var time: String { L10n.clock(target) }
    private var jump: String { SeekPreview.deltaText(delta) }

    var body: some View {
        VStack(spacing: Theme.isTV ? 10 : 6) {
            if let thumbnail {
                Image(decorative: thumbnail, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: Self.thumbWidth)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.isTV ? 10 : 6, style: .continuous))
            }
            Text(verbatim: "\(time) · \(jump)")
                .font(Self.font)
                .foregroundStyle(.white)
                .lineLimit(1)
                .fixedSize()
        }
        .padding(.horizontal, Theme.isTV ? 18 : 10)
        .padding(.vertical, Theme.isTV ? 12 : 6)
        .background(RoundedRectangle(cornerRadius: Theme.isTV ? 16 : 10, style: .continuous).fill(.black.opacity(0.8)))
        .overlay(RoundedRectangle(cornerRadius: Theme.isTV ? 16 : 10, style: .continuous).stroke(.white.opacity(0.25), lineWidth: 1))
        .fixedSize()
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.t("player_seek_target", time, jump))
        .accessibilityValue(thumbnail != nil ? L10n.t("player_seek_preview_image") : "")
        .accessibilityIdentifier("player_seek_bubble")
    }
}

/// Inside `.overlay(alignment: .bottomLeading)`: lifts `content` by `lift` and centres it on the x position
/// `fraction` of `width`, kept inside it.
struct BubblePlacement: ViewModifier {
    let fraction: Double
    let width: CGFloat
    let lift: CGFloat
    @State private var size: CGSize = .zero

    func body(content: Content) -> some View {
        let x = width * min(1, max(0, fraction))
        let left = min(max(0, x - size.width / 2), max(0, width - size.width))
        content
            .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
            .offset(x: left, y: -lift)
    }
}
