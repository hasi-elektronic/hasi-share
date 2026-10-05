import Foundation
import Observation

/// User preferences (UserDefaults) – Settings → Playback / Appearance (docs/SCREENS.md §3.9).
@MainActor
@Observable
public final class AppSettings {
    @ObservationIgnored private let defaults: UserDefaults

    public var aspect: AspectMode { didSet { defaults.set(aspect.rawValue, forKey: "pref.aspect") } }
    /// ISO language code or "" (automatic).
    public var audioLanguage: String { didSet { defaults.set(audioLanguage, forKey: "pref.audioLang") } }
    /// ISO language code, "" (automatic) or "off".
    public var subtitleLanguage: String { didSet { defaults.set(subtitleLanguage, forKey: "pref.subLang") } }
    public var largeBuffer: Bool { didSet { defaults.set(largeBuffer, forKey: "pref.largeBuffer") } }
    public var tvPreview: Bool { didSet { defaults.set(tvPreview, forKey: "pref.tvPreview") } }
    /// IANA id or "" (device).
    public var epgTimeZone: String { didSet { defaults.set(epgTimeZone, forKey: "pref.epgTz") } }
    /// nil → system/locale default.
    public var use24Hour: Bool? { didSet { defaults.set(use24Hour.map { $0 ? 1 : 0 } ?? -1, forKey: "pref.24h") } }
    /// In-app UI language: one of [supportedLanguages] or "" (system). Also written to `AppleLanguages`
    /// so system UI and `Locale.current` follow from the next launch on (the app's L10n switches at once).
    public var appLanguage: String {
        didSet {
            defaults.set(appLanguage, forKey: Self.appLanguageKey)
            if appLanguage.isEmpty { defaults.removeObject(forKey: "AppleLanguages") } else { defaults.set([appLanguage], forKey: "AppleLanguages") }
        }
    }
    public var currentSourceId: String? { didSet { defaults.set(currentSourceId, forKey: "pref.currentSource") } }
    /// Host used for `<LAN-IP>` in the format test (simulator: localhost).
    public var formatTestHost: String { didSet { defaults.set(formatTestHost, forKey: "pref.formatTestHost") } }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        aspect = AspectMode(rawValue: defaults.string(forKey: "pref.aspect") ?? "") ?? .fit
        audioLanguage = defaults.string(forKey: "pref.audioLang") ?? ""
        subtitleLanguage = defaults.string(forKey: "pref.subLang") ?? ""
        largeBuffer = defaults.bool(forKey: "pref.largeBuffer")
        tvPreview = defaults.object(forKey: "pref.tvPreview") as? Bool ?? false
        epgTimeZone = defaults.string(forKey: "pref.epgTz") ?? ""
        let lang = defaults.string(forKey: Self.appLanguageKey) ?? ""
        appLanguage = Self.supportedLanguages.contains(lang) ? lang : ""
        let h = defaults.object(forKey: "pref.24h") as? Int ?? -1
        use24Hour = h < 0 ? nil : h == 1
        currentSourceId = defaults.string(forKey: "pref.currentSource")
        formatTestHost = defaults.string(forKey: "pref.formatTestHost") ?? "localhost"
    }

    public var timeZone: TimeZone { TimeZone(identifier: epgTimeZone) ?? .current }

    /// UI languages shipped in Localizable.xcstrings (Settings order: Deutsch · Türkçe · English).
    public nonisolated static let supportedLanguages = ["de", "tr", "en"]
    public nonisolated static let appLanguageKey = "pref.appLang"

    /// Effective UI language code: the in-app choice, else the localization iOS picked for the app.
    public nonisolated static func uiLanguageCode(defaults: UserDefaults = .standard) -> String {
        let chosen = defaults.string(forKey: appLanguageKey) ?? ""
        if supportedLanguages.contains(chosen) { return chosen }
        let system = Bundle.main.preferredLocalizations.first ?? "en"
        return supportedLanguages.contains(system) ? system : "en"
    }
}
