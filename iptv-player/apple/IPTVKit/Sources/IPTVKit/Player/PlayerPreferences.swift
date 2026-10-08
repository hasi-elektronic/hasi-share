import Foundation
import Observation

/// Device-local player preferences of the Build 16 "watching pack" (docs/SCREENS.md §3.5/§3.7): next-episode
/// autoplay and the subtitle style. Kept in their own keys (not `AppSettings`) – `KeyValueStore`, like the
/// audio delays.
@MainActor
@Observable
public final class PlayerPreferences {
    @ObservationIgnored private let kv: any KeyValueStore

    /// "Play next episode automatically" (default on): the next-episode card counts down 10 s and plays.
    public var autoplayNextEpisode: Bool { didSet { kv.setValue(autoplayNextEpisode, forKey: Self.autoplayKey) } }
    /// Subtitle look for both engines (`SubtitleStyle`).
    public var subtitleStyle: SubtitleStyle { didSet { kv.setValue(subtitleStyle, forKey: Self.styleKey) } }

    static let autoplayKey = "player.autoplayNext"
    static let styleKey = "player.subtitleStyle"

    public init(kv: any KeyValueStore) {
        self.kv = kv
        autoplayNextEpisode = kv.value(Bool.self, forKey: Self.autoplayKey) ?? true
        subtitleStyle = kv.value(SubtitleStyle.self, forKey: Self.styleKey) ?? SubtitleStyle()
    }
}

/// Subtitle style (Player → Subtitles → Style, docs/SCREENS.md §3.7). Mapped to `AVTextStyleRule` attributes
/// for AVPlayer and to libVLC freetype options for VLCKit (`SubtitleStyleMapping`).
public struct SubtitleStyle: Codable, Sendable, Hashable {
    public enum Size: String, Codable, Sendable, CaseIterable { case small, medium, large, extraLarge }
    public enum Color: String, Codable, Sendable, CaseIterable { case white, yellow }
    public enum Background: String, Codable, Sendable, CaseIterable { case none, semi, solid }

    public var size: Size
    public var color: Color
    public var background: Background

    public init(size: Size = .medium, color: Color = .white, background: Background = .none) {
        self.size = size
        self.color = color
        self.background = background
    }

    public var isDefault: Bool { self == SubtitleStyle() }
}

/// Engine mapping of `SubtitleStyle` (pure, unit-tested).
public enum SubtitleStyleMapping {
    /// AVPlayer (`AVPlayerEngine`: `AVTextStyleRule` with `kCMTextMarkupAttribute_RelativeFontSize`,
    /// `…_ForegroundColorARGB`, `…_CharacterBackgroundColorARGB`): percent of the default size (100).
    public static func relativeFontSizePercent(_ size: SubtitleStyle.Size) -> Double {
        switch size {
        case .small: return 75
        case .medium: return 100
        case .large: return 130
        case .extraLarge: return 165
        }
    }

    public static func foregroundARGB(_ color: SubtitleStyle.Color) -> [Double] {
        switch color {
        case .white: return [1, 1, 1, 1]
        case .yellow: return [1, 1, 0.92, 0.23]
        }
    }

    /// nil = no background box.
    public static func backgroundARGB(_ background: SubtitleStyle.Background) -> [Double]? {
        switch background {
        case .none: return nil
        case .semi: return [0.55, 0, 0, 0]
        case .solid: return [1, 0, 0, 0]
        }
    }

    /// libVLC 3 media options (freetype text renderer). `freetype-rel-fontsize` is a divisor of the video height
    /// (smaller = bigger text, libVLC's own presets: 20 smaller · 18 small · 16 normal · 12 large · 6 larger);
    /// colour is decimal 0xRRGGBB; background opacity 0…255 (black box). Limits: libVLC reads them when the text
    /// renderer starts, so a change applies by reopening the item (the controller reloads in place); bold /
    /// outline stay libVLC's defaults.
    public static func vlcOptions(_ style: SubtitleStyle) -> [String] {
        let rel: Int
        switch style.size {
        case .small: rel = 20
        case .medium: rel = 16
        case .large: rel = 12
        case .extraLarge: rel = 9
        }
        let color = style.color == .white ? 0xFFFFFF : 0xFFEB3B
        let opacity: Int
        switch style.background {
        case .none: opacity = 0
        case .semi: opacity = 140
        case .solid: opacity = 255
        }
        return [":freetype-rel-fontsize=\(rel)", ":freetype-color=\(color)",
                ":freetype-background-opacity=\(opacity)", ":freetype-background-color=0"]
    }
}
