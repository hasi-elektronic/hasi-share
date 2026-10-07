import Foundation

/// Country of a provider category name ("TR • NETFLIX DIZILER" → TR, "DE | Serien" → DE, "Germany" → DE).
/// Drives the flag emoji next to category names and the country filter of Movies/Series
/// (docs/SCREENS.md §3.2). Pure and thread-safe; results are cached per name.
public enum CategoryCountry {
    /// Two-letter tokens that are words/tags far more often than country prefixes ("TV", "HD", "IT"…).
    static let ignoredCodes: Set<String> = ["TV", "FM", "AM", "SD", "HD", "VO", "IN", "IT", "TO", "NO", "BE", "ME", "IS", "AS", "AT", "BY", "MY", "AN"]
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

    /// ISO region code of a category name, nil when it names no (single) country.
    public static func code(for title: String) -> String? {
        if let hit = cache.get(title) { return hit.code }
        let code = detect(title)
        cache.set(title, code)
        return code
    }

    static func detect(_ title: String) -> String? {
        let upperTokens = title.split(whereSeparator: { " |:-_[]()/,.".contains($0) }).map(String.init)
        // Leading or bracketed upper-case code ("DE | Sport", "[TR] Ulusal", "Sport (UK)").
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

    /// Flag emoji of a region code ("TR" → 🇹🇷).
    public static func flag(_ code: String) -> String {
        let base: UInt32 = 0x1F1E6 - 65
        return String(String.UnicodeScalarView(code.uppercased().unicodeScalars.compactMap { UnicodeScalar(base + $0.value) }))
    }

    /// Flag emoji for a category name, nil without a country.
    public static func emoji(for title: String) -> String? { code(for: title).map(flag) }

    /// Removes a leading code prefix so the flag is not repeated: "DE | Sport" → "Sport",
    /// "TR • NETFLIX DIZILER" → "NETFLIX DIZILER", "[EN] Drama" stays (no country).
    public static func strippedTitle(_ title: String) -> String {
        guard code(for: title) != nil else { return title }
        return withoutPrefix(title) ?? title
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
