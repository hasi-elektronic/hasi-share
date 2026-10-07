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
    /// Region codes that, as a group prefix, are tags, not countries ("TV | …", "HD | …"): no flag, raw code.
    static let tagCodes: Set<String> = ["TV", "FM", "AM", "SD", "HD", "VO"]
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

    /// Leading "XX<sep>" / "XXX<sep>" (separator •, |, :, -, ]) or "[XX]" / "[XXX]": the code, aliases applied.
    static func prefixCode(_ title: String) -> String? {
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        let token: String
        if trimmed.hasPrefix("[") {
            guard let close = trimmed.firstIndex(of: "]") else { return nil }
            token = String(trimmed[trimmed.index(after: trimmed.startIndex)..<close]).trimmingCharacters(in: .whitespaces)
        } else {
            let end = trimmed.firstIndex(where: { !$0.isLetter }) ?? trimmed.endIndex
            token = String(trimmed[..<end])
            let rest = trimmed[end...].drop(while: { $0 == " " })
            guard let sep = rest.first, "•|:-]".contains(sep) else { return nil }
        }
        guard (2...3).contains(token.count), token.allSatisfy({ $0.isLetter && $0.isUppercase }) else { return nil }
        if let alias = aliases[token] { return alias.isEmpty ? nil : alias }
        return token
    }

    static func detect(_ title: String) -> String? {
        let upperTokens = title.split(whereSeparator: { " |:-_[]()/,.".contains($0) }).map(String.init)
        // Bracketed or trailing upper-case code ("Sport (UK)", "Haber TR").
        for token in upperTokens.prefix(3) {
            if let alias = aliases[token.uppercased()] { return alias.isEmpty ? nil : alias }
            if token.count == 2, token == token.uppercased(), token.allSatisfy(\.isLetter), !ignoredCodes.contains(token),
               regionCodes.contains(token) {
                return token
            }
        }
        let lower = title.lowercased()
        let words = lower.split(whereSeparator: { !$0.isLetter && $0 != " " }).map { $0.trimmingCharacters(in: .whitespaces) }
        for word in words where !word.isEmpty {
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
            let lower = code.lowercased()
            if let name = locale.localizedString(forLanguageCode: lower), name.lowercased() != lower {
                return name.prefix(1).uppercased() + name.dropFirst()
            }
            return code
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
    /// "NETFLIX DIZILER". Without a flag ("EN | Drama", "AR | …", "[EN] Drama") the name stays as written.
    public static func strippedTitle(_ title: String) -> String {
        guard emoji(for: title) != nil else { return title }
        return withoutPrefix(title) ?? title
    }

    /// The name without its leading code prefix, whatever the code ("EN | Drama" → "Drama").
    public static func nameWithoutPrefix(_ title: String) -> String {
        withoutPrefix(title) ?? title
    }

    /// "XX | rest" / "XX • rest" / "XX: rest" / "[XX] rest" → "rest" when the prefix is a short code (≤ 3 letters).
    static func withoutPrefix(_ title: String) -> String? {
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("["), let close = trimmed.firstIndex(of: "]") {
            let inner = trimmed[trimmed.index(after: trimmed.startIndex)..<close]
            let rest = trimmed[trimmed.index(after: close)...].trimmingCharacters(in: CharacterSet(charactersIn: " |:•-"))
            if inner.count <= 3, !rest.isEmpty { return rest }
        }
        let parts = trimmed.split(maxSplits: 1, whereSeparator: { "|:•".contains($0) })
        if parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces).count <= 3 {
            let rest = parts[1].trimmingCharacters(in: .whitespaces)
            return rest.isEmpty ? nil : rest
        }
        return nil
    }

    /// Search key of a category name: country prefix removed, case and diacritics folded
    /// ("TR | DİZİLER" → "diziler"), so a query does not match every category of a country by its prefix.
    public static func searchKey(_ title: String) -> String {
        fold(withoutPrefix(title) ?? title)
    }

    /// Case- and diacritics-insensitive form ("Türk Dİzİlerİ" → "turk dizileri").
    public static func fold(_ text: String) -> String {
        // Turkish dotted/dotless i fold to "i" before the generic folding (İ → i̇ would keep a combining dot).
        let mapped = text.replacingOccurrences(of: "İ", with: "I").replacingOccurrences(of: "ı", with: "i")
        return mapped.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
    }

    /// True when `title` matches the (already folded or raw) query.
    public static func matches(_ title: String, query: String) -> Bool {
        let q = fold(query.trimmingCharacters(in: .whitespacesAndNewlines))
        return q.isEmpty || searchKey(title).contains(q)
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
