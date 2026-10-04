import SwiftUI

/// Visual tokens of docs/SCREENS.md §1 (dark only).
enum Theme {
    static let bg = Color(hex: 0x0B0D12)
    static let surface = Color(hex: 0x151922)
    static let surfaceElevated = Color(hex: 0x1E2430)
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
    static let headline: Font = .system(size: 34, weight: .semibold)
    static let posterWidth: CGFloat = 220
    static let cardRadius: CGFloat = 16
    #else
    static let isTV = false
    static let safeH: CGFloat = 16
    static let safeV: CGFloat = 12
    static let body: Font = .body
    static let caption: Font = .footnote
    static let title: Font = .largeTitle.bold()
    static let headline: Font = .headline
    static let posterWidth: CGFloat = 120
    static let cardRadius: CGFloat = 12
    #endif
    static let posterRadius: CGFloat = 10
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255, opacity: 1)
    }
}

/// Pill button in the primary color (star actions).
struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.headline)
            .foregroundStyle(.white)
            .padding(.horizontal, Theme.isTV ? 40 : 22)
            .padding(.vertical, Theme.isTV ? 18 : 12)
            .background(Capsule().fill(Theme.premiumGradient))
            .modifier(TVFocusCard(radius: 60))
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

/// TV focus treatment: 1.08× scale + 3 pt primary ring + shadow (SCREENS §1).
struct TVFocusCard: ViewModifier {
    @Environment(\.isFocused) private var isFocused
    var radius: CGFloat = Theme.cardRadius

    func body(content: Content) -> some View {
        content
            .overlay(RoundedRectangle(cornerRadius: radius).stroke(Theme.primary, lineWidth: isFocused ? 4 : 0))
            .scaleEffect(isFocused ? 1.08 : 1)
            .shadow(color: .black.opacity(isFocused ? 0.6 : 0), radius: 16, y: 8)
            .animation(.easeOut(duration: 0.18), value: isFocused)
    }
}

/// Plain card button style used for focusable cards (no system platter on tvOS).
struct CardButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .modifier(TVFocusCard())
            .opacity(configuration.isPressed ? 0.85 : 1)
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
