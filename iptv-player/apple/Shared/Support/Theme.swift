import SwiftUI

/// Visual tokens of docs/SCREENS.md §1 (dark only, pure black background).
enum Theme {
    static let bg = Color.black
    static let surface = Color(hex: 0x16181D)
    static let surfaceElevated = Color(hex: 0x24272F)
    static let stroke = Color.white.opacity(0.10)
    static let primary = Color(hex: 0x5B8CFF)
    static let primaryVariant = Color(hex: 0x7C5CFF)
    static let textPrimary = Color(hex: 0xF2F4F8)
    static let textSecondary = Color(hex: 0xA3ACBD)
    static let live = Color(hex: 0xFF4D5E)
    static let success = Color(hex: 0x2BD47D)
    static let warning = Color(hex: 0xFFB547)
    static let error = Color(hex: 0xFF5C5C)

    static let premiumGradient = LinearGradient(colors: [primary, primaryVariant], startPoint: .topLeading, endPoint: .bottomTrailing)

    #if os(tvOS)
    static let isTV = true
    /// Overscan-safe margins (48 × 27 dp at 1x → points on tvOS 1920×1080).
    static let safeH: CGFloat = 80
    static let safeV: CGFloat = 45
    static let body: Font = .system(size: 29)
    static let caption: Font = .system(size: 24)
    static let title: Font = .system(size: 48, weight: .bold)
    static let largeTitle: Font = .system(size: 76, weight: .heavy)
    static let headline: Font = .system(size: 34, weight: .semibold)
    static let rowTitle: Font = .system(size: 36, weight: .bold)
    static let posterWidth: CGFloat = 240
    static let cardRadius: CGFloat = 16
    static let posterRadius: CGFloat = 14
    static let rowSpacing: CGFloat = 56
    static let shelfSpacing: CGFloat = 40
    #else
    static let isTV = false
    static let safeH: CGFloat = 16
    static let safeV: CGFloat = 12
    static let body: Font = .body
    static let caption: Font = .footnote
    static let title: Font = .largeTitle.bold()
    static let largeTitle: Font = .system(.largeTitle, design: .default).weight(.heavy)
    static let headline: Font = .headline
    static let rowTitle: Font = .title3.bold()
    static let posterWidth: CGFloat = 116
    static let cardRadius: CGFloat = 12
    static let posterRadius: CGFloat = 10
    static let rowSpacing: CGFloat = 28
    static let shelfSpacing: CGFloat = 12
    #endif

    /// Deterministic tile colors for channels without own artwork color (SCREENS §1).
    static let channelPalette: [UInt32] = [
        0x2F6FED, 0xE0533D, 0x15924A, 0x8B3FD9, 0xD3286F, 0x0A8AA8, 0xC9730A,
        0x4B4FD8, 0x0B7F5E, 0xB3262A, 0x2B8FD6, 0x56616F, 0xA8740B, 0x6D4AC4,
    ]

    /// Stable color for a channel (FNV-1a over the lowercased name – `hashValue` is per-process).
    static func channelColor(_ name: String) -> Color {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in name.lowercased().utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return Color(hex: channelPalette[Int(hash % UInt64(channelPalette.count))])
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255, opacity: 1)
    }
}

/// Pill button in the primary color (star actions).
struct PrimaryButtonStyle: ButtonStyle {
    var fullWidth = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.headline)
            .foregroundStyle(.white)
            .lineLimit(1)
            .padding(.horizontal, Theme.isTV ? 40 : 22)
            .padding(.vertical, Theme.isTV ? 18 : 13)
            .frame(maxWidth: fullWidth ? .infinity : nil)
            .background(Capsule().fill(Theme.premiumGradient))
            .modifier(TVFocusCard(radius: 60, scale: fullWidth ? 1.04 : 1.08))
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}

/// Secondary pill button.
struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.body)
            .foregroundStyle(Theme.textPrimary)
            .padding(.horizontal, Theme.isTV ? 32 : 18)
            .padding(.vertical, Theme.isTV ? 16 : 10)
            .background(Capsule().fill(Theme.surfaceElevated))
            .modifier(TVFocusCard(radius: 60))
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}

/// Round icon button (favorite, restart, more, settings…) – SCREENS §3.4.
struct RoundIconButtonStyle: ButtonStyle {
    var size: CGFloat = Theme.isTV ? 84 : 42

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: size * 0.4, weight: .semibold))
            .foregroundStyle(Theme.textPrimary)
            .frame(width: size, height: size)
            .background(Circle().fill(Theme.surfaceElevated.opacity(0.9)))
            .overlay(Circle().stroke(Theme.stroke, lineWidth: 1))
            .contentShape(Circle())
            .modifier(TVFocusCard(radius: size / 2, scale: 1.12))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

/// TV focus treatment: scale (default 1.08×) + 3 pt primary ring + shadow (SCREENS §1).
struct TVFocusCard: ViewModifier {
    @Environment(\.isFocused) private var isFocused
    var radius: CGFloat = Theme.cardRadius
    var scale: CGFloat = 1.08

    func body(content: Content) -> some View {
        content
            .overlay(RoundedRectangle(cornerRadius: radius).stroke(Theme.primary, lineWidth: isFocused ? 4 : 0))
            .scaleEffect(isFocused ? scale : 1)
            .shadow(color: .black.opacity(isFocused ? 0.6 : 0), radius: 16, y: 8)
            .animation(.easeOut(duration: 0.18), value: isFocused)
    }
}

/// Plain card button style used for focusable cards (no system platter on tvOS).
struct CardButtonStyle: ButtonStyle {
    var radius: CGFloat = Theme.cardRadius
    var scale: CGFloat = 1.08

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .modifier(TVFocusCard(radius: radius, scale: scale))
            .opacity(configuration.isPressed ? 0.85 : 1)
    }
}

/// Card whose artwork carries the focus ring while the caption below stays unscaled.
struct ArtworkButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.85 : 1)
    }
}

extension View {
    /// Applies the screen background and safe margins.
    func screenBackground() -> some View {
        background(Theme.bg.ignoresSafeArea())
    }
}

extension View {
    /// Hides the system list/form background (iOS); tvOS lists have none.
    @ViewBuilder
    func hiddenListBackground() -> some View {
        #if os(tvOS)
        self
        #else
        scrollContentBackground(.hidden)
        #endif
    }
}
