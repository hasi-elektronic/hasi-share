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
        let h = defaults.object(forKey: "pref.24h") as? Int ?? -1
        use24Hour = h < 0 ? nil : h == 1
        currentSourceId = defaults.string(forKey: "pref.currentSource")
        formatTestHost = defaults.string(forKey: "pref.formatTestHost") ?? "localhost"
    }

    public var timeZone: TimeZone { TimeZone(identifier: epgTimeZone) ?? .current }
}
