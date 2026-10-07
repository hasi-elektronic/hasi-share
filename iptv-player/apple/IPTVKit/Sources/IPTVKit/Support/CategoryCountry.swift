import Foundation

/// Group (country or language) of a provider category name – the Movies/Series country filter and the flag
/// next to category names (docs/SCREENS.md §3.2). Pure and thread-safe; results are cached per name.
///
/// * A leading 2–3 letter upper-case code followed by a separator ("TR • NETFLIX DIZILER", "DE | Serien",
///   "EN: Drama", "IT - Serie", "[AR] مسلسلات") is the group, whether it is an ISO region or a language code
///   – providers group by language too (EN, AR). Aliases still apply (UK → GB, USA → US). A digit breaks it
///   ("4K | Movies" → no group).
/// * Otherwise the name is searched for a country (bracketed/trailing code "Sport (UK)", country names in
///   English/Turkish/German, aliases such as TÜRKİYE).
public enum CategoryCountry {
    /// Two-letter tokens that are words/tags far more often than country codes inside a name ("TV", "HD"…).
    /// Not used for a leading code with a separator (there the separator makes "IT | Serie" Italian).
    static let ignoredCodes: Set<String> = ["TV", "FM", "AM", "SD", "HD", "VO", "IN", "IT", "TO", "NO", "BE", "ME", "IS", "AS", "AT", "BY", "MY", "AN"]
    /// Region codes that, as a group prefix, almost always mean a language: no flag, language name.
    static let languageFirstCodes: Set<String> = ["EN", "AR"]
    /// Prefixes that are tags, channels or packages – never a country/language group ("FHD | …", "VIP | …",
    /// "UFC | …", "BBC | …"). The single list for both the group detection and the display.
    static let tagCodes: Set<String> = [
        // Quality / format
        "SD", "HD", "FHD", "UHD", "HDR", "VO", "VOD", "SUB", "DUB",
        // Radio / TV
        "TV", "FM", "AM",
        // Packages and labels
        "VIP", "PPV", "NEW", "TOP", "HOT", "ALL", "KID", "MIX", "XXX",
        // Sports leagues / promotions
        "UFC", "WWE", "NBA", "NFL", "NHL", "MLB",
        // Broadcasters / networks often used as a group prefix
        "BBC", "ITV", "CNN", "SKY", "FOX", "HBO", "AMC", "ABC", "CBS", "NBC", "MTV", "TRT",
    ]
    /// 3-letter language codes providers use (ISO 639-2/B and /T spellings of the languages the apps' users
    /// actually see) → ISO 639-1 for the language name. Other 3-letter codes stay a group but show the raw
    /// code: the full ISO 639 list would turn tags into obscure languages ("NEW" → Newari, "BBC" → Batak Toba).
    static let threeLetterLanguages: [String: String] = [
        "ENG": "en", "GER": "de", "DEU": "de", "FRA": "fr", "FRE": "fr", "TUR": "tr", "ARA": "ar", "SPA": "es",
        "ESP": "es", "ITA": "it", "POR": "pt", "RUS": "ru", "POL": "pl", "NLD": "nl", "DUT": "nl", "KUR": "ku",
        "PER": "fa", "FAS": "fa", "HIN": "hi", "ALB": "sq", "SQI": "sq", "BOS": "bs", "HRV": "hr", "SRP": "sr",
    ]
    /// Separators after a leading code ("TR • …", "DE | …", "EN: …", "NL - …", "ES] …"). "-" only with a
    /// space after it, so words such as "Sci-Fi" or "X-Men" are not split.
    static let prefixSeparators: Set<Character> = ["•", "|", ":", "-", "]"]
    /// Provider spellings → ISO region code ("" = known group without a single country).
    static let aliases: [String: String] = [
        "UK": "GB", "USA": "US", "U.S.": "US", "UAE": "AE", "KSA": "SA", "EX-YU": "RS", "EXYU": "RS", "LATAM": "",
        "TURKIYE": "TR", "TÜRKİYE": "TR", "TURKEY": "TR", "DEUTSCHLAND": "DE", "ALMANYA": "DE", "ENGLAND": "GB",
    ]

    static let regionCodes: Set<String> = Set(Locale.Region.isoRegions.map(\.identifier)
        .filter { $0.count == 2 && $0.allSatisfy(\.isLetter) })

    /// Lowercased country names (English, Turkish, German) → ISO region code.
    static let names: [String: String] = {
        var map: [String: String] = [:]
        let locales = ["en", "tr", "de"].map(Locale.init(identifier:))
        for code in regionCodes {
            for locale in locales {
                if let name = locale.localizedString(forRegionCode: code) { map[name.lowercased()] = code }
            }
        }
        return map
    }()

    private static let cache = CountryCache()

    /// Group code of a category name (ISO region "TR", or a language/other code "EN", "AR"), nil = no group.
    public static func code(for title: String) -> String? {
        if let hit = cache.get(title) { return hit.code }
        let code = prefixCode(title) ?? detect(title)
        cache.set(title, code)
        return code
    }

    /// Leading code + separator, or the bracket form: ("TR", "NETFLIX DIZILER") for "TR • NETFLIX DIZILER",
    /// ("EN", "Drama") for "[EN] Drama". Shared by the group detection, prefix stripping and search.
    static func leadingPrefix(_ title: String) -> (token: String, rest: String)? {
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        let token: String
        var rest: Substring
        if trimmed.hasPrefix("[") {
            guard let close = trimmed.firstIndex(of: "]") else { return nil }
            token = String(trimmed[trimmed.index(after: trimmed.startIndex)..<close]).trimmingCharacters(in: .whitespaces)
            rest = trimmed[trimmed.index(after: close)...].drop(while: { $0 == " " })
            if let sep = rest.first, prefixSeparators.contains(sep) { rest = rest.dropFirst() }   // "[EN] | Drama"
        } else {
            let end = trimmed.firstIndex(where: { !($0.isLetter || $0.isNumber) }) ?? trimmed.endIndex
            token = String(trimmed[..<end])
            rest = trimmed[end...].drop(while: { $0 == " " })
            guard let sep = rest.first, prefixSeparators.contains(sep) else { return nil }
            rest = rest.dropFirst()
            if sep == "-", !(rest.first?.isWhitespace ?? false) { return nil }
        }
        guard (1...3).contains(token.count) else { return nil }
        return (token, rest.trimmingCharacters(in: .whitespaces))
    }

    /// Group code of a leading prefix: 2–3 upper-case letters, not a tag; aliases applied (UK → GB).
    static func prefixCode(_ title: String) -> String? {
        guard let token = leadingPrefix(title)?.token, (2...3).contains(token.count),
              token.allSatisfy({ $0.isLetter && $0.isUppercase }), !tagCodes.contains(token) else { return nil }
        if let alias = aliases[token] { return alias.isEmpty ? nil : alias }
        return token
    }

    static func detect(_ title: String) -> String? {
        // Words split on spaces and separators, NOT on "-": a hyphenated word is one word ("SCI-FI", "EX-YU").
        let words = title.split(whereSeparator: { " |:_[]()/,.•".contains($0) }).map(String.init)
        // Bracketed or trailing upper-case code ("Sport (UK)", "Haber TR").
        for word in words.prefix(3) {
            // Aliases on the whole word first ("EX-YU" → RS).
            if let alias = aliases[word.uppercased()] { return alias.isEmpty ? nil : alias }
            // Of a hyphenated word only its first part can be a code ("TR-Yerli" → TR); later parts are
            // syllables ("SCI-FI" is not Finland, "X-Men" nothing).
            let token = word.contains("-") ? String(word.split(separator: "-").first ?? "") : word
            if token.count == 2, token == token.uppercased(), token.allSatisfy(\.isLetter), !ignoredCodes.contains(token),
               regionCodes.contains(token) {
                return token
            }
        }
        let lower = title.lowercased()
        let phrases = lower.split(whereSeparator: { !$0.isLetter && $0 != " " }).map { $0.trimmingCharacters(in: .whitespaces) }
        for word in phrases where !word.isEmpty {
            if let code = names[word] { return code }
            for token in word.split(separator: " ") {
                if let code = names[String(token)] { return code }
                if let alias = aliases[String(token).uppercased()], !alias.isEmpty { return alias }
            }
        }
        return nil
    }

    /// How a group code reads: a country (flag + region name), a language (language name, no flag) or a tag.
    public enum Meaning: Equatable, Sendable {
        case region, language, tag
    }

    public static func meaning(of code: String) -> Meaning {
        let upper = code.uppercased()
        if tagCodes.contains(upper) { return .tag }
        if languageFirstCodes.contains(upper) || !regionCodes.contains(upper) { return .language }
        return .region
    }

    /// Flag emoji of a group code – only real regions that are not language-first codes (no 🇦🇷 for "AR").
    public static func flagEmoji(forCode code: String) -> String? {
        meaning(of: code) == .region ? flag(code) : nil
    }

    /// Display name of a group code in `locale`: "Türkiye" / "Deutschland" (regions), "English" / "Arapça"
    /// (language-first and non-region codes with a known language name), else the code itself.
    public static func displayName(of code: String, locale: Locale) -> String {
        switch meaning(of: code) {
        case .region:
            return locale.localizedString(forRegionCode: code.uppercased()) ?? code
        case .language:
            // 2-letter codes (ISO 639-1) and a short list of 3-letter ones; anything else stays raw.
            let upper = code.uppercased()
            guard let language = upper.count == 2 ? upper.lowercased() : threeLetterLanguages[upper],
                  let name = locale.localizedString(forLanguageCode: language), name.lowercased() != language else { return code }
            return name.prefix(1).uppercased() + name.dropFirst()
        case .tag:
            return code
        }
    }

    /// Flag emoji of a region code ("TR" → 🇹🇷), unconditionally.
    public static func flag(_ code: String) -> String {
        let base: UInt32 = 0x1F1E6 - 65
        return String(String.UnicodeScalarView(code.uppercased().unicodeScalars.compactMap { UnicodeScalar(base + $0.value) }))
    }

    /// Flag emoji for a category name, nil without a country (language groups such as "EN | …" have none).
    public static func emoji(for title: String) -> String? { code(for: title).flatMap(flagEmoji(forCode:)) }

    /// Removes a leading code prefix when a flag replaces it: "DE | Sport" → "Sport", "TR • NETFLIX DIZILER" →
    /// "NETFLIX DIZILER". Without a flag ("EN | Drama", "AR | …", "[EN] Drama") the name stays as written;
    /// a tag prefix stays too ("4K | Germany" keeps "4K |", the flag comes from "Germany").
    public static func strippedTitle(_ title: String) -> String {
        guard emoji(for: title) != nil else { return title }
        return ownPrefixRemoved(title) ?? title
    }

    /// The name without its leading group code ("EN | Drama" → "Drama"); other prefixes (tags, "4K", "007")
    /// stay.
    public static func nameWithoutPrefix(_ title: String) -> String {
        ownPrefixRemoved(title) ?? title
    }

    /// The rest after the leading prefix – only when that prefix is the name's own group code.
    static func ownPrefixRemoved(_ title: String) -> String? {
        guard let code = prefixCode(title), code == self.code(for: title) else { return nil }
        return withoutPrefix(title)
    }

    /// "XX | rest" / "XX • rest" / "XX: rest" / "XX - rest" / "[XX] rest" → "rest" (prefix ≤ 3 characters,
    /// same separators as the group detection).
    static func withoutPrefix(_ title: String) -> String? {
        guard let prefix = leadingPrefix(title), !prefix.rest.isEmpty else { return nil }
        return prefix.rest
    }

    /// Search key of a category name without its group code ("TR | DİZİLER" → "diziler"); tags and other
    /// prefixes are kept ("HBO | Series" → "hbo | series").
    public static func searchKey(_ title: String) -> String {
        fold(nameWithoutPrefix(title))
    }

    /// Case- and diacritics-insensitive form ("Türk Dİzİlerİ" → "turk dizileri").
    public static func fold(_ text: String) -> String {
        // Turkish dotted/dotless i fold to "i" before the generic folding (İ → i̇ would keep a combining dot).
        let mapped = text.replacingOccurrences(of: "İ", with: "I").replacingOccurrences(of: "ı", with: "i")
        return mapped.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
    }

    /// True when the query (case/diacritics folded) is part of the full name or of the name without its group
    /// code: networks and tags ("hbo", "trt", "4k", "007") and group codes ("tr") are searchable, and a query
    /// that skips the separator ("netflix diz") still matches.
    public static func matches(_ title: String, query: String) -> Bool {
        let q = fold(query.trimmingCharacters(in: .whitespacesAndNewlines))
        return q.isEmpty || fold(title).contains(q) || searchKey(title).contains(q)
    }
}

/// Name → detected code (`nil` results cached too). Category names repeat on every reload.
private final class CountryCache: @unchecked Sendable {
    struct Hit { let code: String? }
    private let lock = NSLock()
    private var values: [String: Hit] = [:]

    func get(_ key: String) -> Hit? {
        lock.lock(); defer { lock.unlock() }
        return values[key]
    }

    func set(_ key: String, _ code: String?) {
        lock.lock(); defer { lock.unlock() }
        if values.count > 20_000 { values.removeAll(keepingCapacity: true) }
        values[key] = Hit(code: code)
    }
}
