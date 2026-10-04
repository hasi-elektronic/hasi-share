import Foundation
import IPTVCore
import SwiftUI

/// Localized strings from `Localizable.xcstrings` (generated from spec/strings.json).
/// `{0}`, `{1}` in the spec become `%1$@`, `%2$@` (string arguments).
enum L10n {
    static func t(_ key: String, _ args: String...) -> String {
        let format = Bundle.main.localizedString(forKey: key, value: nil, table: nil)
        guard !args.isEmpty else { return format }
        return String(format: format, locale: Locale.current, arguments: args.map { $0 as CVarArg })
    }

    /// Plural entry: `{0}` is the integer count, further args are strings.
    static func plural(_ key: String, _ count: Int, _ args: String...) -> String {
        let format = Bundle.main.localizedString(forKey: key, value: nil, table: nil)
        return String(format: format, locale: Locale.current, arguments: [count as CVarArg] + args.map { $0 as CVarArg })
    }

    static func error(_ p: ErrorPresentation) -> (title: String, body: String, hint: String?) {
        (title: t(p.titleKey, p.titleArgs), body: t(p.bodyKey, p.bodyArgs), hint: p.hintKey.map { t($0) })
    }

    private static func t(_ key: String, _ args: [String]) -> String {
        let format = Bundle.main.localizedString(forKey: key, value: nil, table: nil)
        guard !args.isEmpty else { return format }
        return String(format: format, locale: Locale.current, arguments: args.map { $0 as CVarArg })
    }

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
    Text(verbatim: args.isEmpty ? L10n.t(key) : String(format: Bundle.main.localizedString(forKey: key, value: nil, table: nil),
                                                         locale: Locale.current, arguments: args.map { $0 as CVarArg }))
}
