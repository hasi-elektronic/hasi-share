import Foundation
import IPTVCore
import IPTVKit
import SwiftUI

/// Localized strings from `Localizable.xcstrings` (generated from spec/strings.json).
/// `{0}`, `{1}` in the spec become `%1$@`, `%2$@` (string arguments).
///
/// The UI language follows Settings → "App language" (System / Deutsch / Türkçe / English) at once:
/// strings come from that `.lproj` bundle and dates/numbers use [locale]. The root views are keyed by
/// the language (`.id`) so everything re-renders after a switch.
enum L10n {
    private struct State: @unchecked Sendable {
        let code: String
        let bundle: Bundle
        let locale: Locale
    }

    nonisolated(unsafe) private static var state = resolve("")

    /// Effective UI language ("de" / "tr" / "en").
    static var languageCode: String { state.code }
    /// Locale for dates, times and numbers matching the UI language (24 h clock for de/tr).
    static var locale: Locale { state.locale }
    static var bundle: Bundle { state.bundle }

    /// `code`: one of `AppSettings.supportedLanguages` or "" (system).
    static func setLanguage(_ code: String) { state = resolve(code) }

    private static func resolve(_ code: String) -> State {
        let available = Bundle.main.localizations.filter { $0 != "Base" }
        let lang: String
        if !code.isEmpty, available.contains(code) {
            lang = code
        } else {
            let prefs = UserDefaults.standard.stringArray(forKey: "AppleLanguages") ?? Locale.preferredLanguages
            lang = Bundle.preferredLocalizations(from: available, forPreferences: prefs).first ?? "en"
        }
        let bundle = Bundle.main.path(forResource: lang, ofType: "lproj").flatMap(Bundle.init(path:)) ?? .main
        return State(code: lang, bundle: bundle, locale: code.isEmpty ? .current : locale(for: lang))
    }

    /// Keeps the device region when it fits the language (de_AT, en_GB…), else the main region.
    private static func locale(for lang: String) -> Locale {
        let current = Locale.current
        if current.language.languageCode?.identifier == lang { return current }
        let region = current.region?.identifier ?? ""
        let regions: [String: [String]] = ["de": ["DE", "AT", "CH", "LI", "LU", "BE"], "tr": ["TR", "CY"]]
        if let fitting = regions[lang] { return Locale(identifier: "\(lang)_\(fitting.contains(region) ? region : fitting[0])") }
        return Locale(identifier: region.isEmpty ? lang : "\(lang)_\(region)")
    }

    static func t(_ key: String, _ args: String...) -> String {
        t(key, args)
    }

    /// Plural entry: `{0}` is the integer count, further args are strings.
    static func plural(_ key: String, _ count: Int, _ args: String...) -> String {
        let format = bundle.localizedString(forKey: key, value: nil, table: nil)
        return String(format: format, locale: locale, arguments: [count as CVarArg] + args.map { $0 as CVarArg })
    }

    static func error(_ p: ErrorPresentation) -> (title: String, body: String, hint: String?) {
        (title: t(p.titleKey, p.titleArgs), body: t(p.bodyKey, p.bodyArgs), hint: p.hintKey.map { t($0) })
    }

    static func t(_ key: String, _ args: [String]) -> String {
        let format = bundle.localizedString(forKey: key, value: nil, table: nil)
        guard !args.isEmpty else { return format }
        return String(format: format, locale: locale, arguments: args.map { $0 as CVarArg })
    }

    /// Date/time in the UI language (`Date.formatted(date:time:)` would use the launch locale).
    static func date(_ date: Date, date dateStyle: Date.FormatStyle.DateStyle, time timeStyle: Date.FormatStyle.TimeStyle) -> String {
        date.formatted(Date.FormatStyle(date: dateStyle, time: timeStyle).locale(locale))
    }

    static func number(_ n: Int) -> String { n.formatted(.number.locale(locale)) }

    static func actionTitle(_ action: ErrorAction) -> String {
        switch action {
        case .retry: return t("action_retry")
        case .edit: return t("action_edit")
        case .deleteSource: return t("action_delete")
        case .refresh: return t("action_refresh")
        case .channelList: return t("action_channel_list")
        case .back: return t("action_back")
        }
    }

    /// "1 Std 20 Min" style duration.
    static func duration(ms: Int64) -> String {
        let f = DateComponentsFormatter()
        f.allowedUnits = ms >= 86_400_000 ? [.day, .hour] : [.hour, .minute]
        f.unitsStyle = .short
        f.maximumUnitCount = 2
        var calendar = Calendar.current
        calendar.locale = locale
        f.calendar = calendar
        return f.string(from: TimeInterval(ms / 1000)) ?? ""
    }

    static func clock(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "--:--" }
        let s = Int(seconds)
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60) : String(format: "%02d:%02d", s / 60, s % 60)
    }
}

/// Localized `Text` from a key.
func LText(_ key: String, _ args: String...) -> Text {
    Text(verbatim: L10n.t(key, args))
}
