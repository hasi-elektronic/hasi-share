import Foundation

/// Channel-name normalization for EPG fallback matching (CONTRACT §5,
/// `xmltv/name-normalization.json`). Locale-independent: "ISTANBUL" → "istanbul" even on
/// devices set to Turkish.
public enum NameNormalizer {
    static let stopTokens: Set<String> = ["hd", "fhd", "uhd", "4k", "sd", "hevc", "h265", "tr", "de", "en"]

    /// Normalizes a channel name:
    /// 1. lowercase (root locale)
    /// 2. NFD, drop U+0300…U+036F, then map ı→i ß→ss ø→o æ→ae œ→oe ł→l đ→d
    /// 3. remove `[…]` and `(…)` groups
    /// 4. split on `[^a-z0-9]+`, drop empty and stop tokens
    /// 5. join without separator; if empty, fall back to steps 1–3 with `[^a-z0-9]` removed.
    public static func normalize(_ name: String) -> String {
        // Step 1: String.lowercased() uses the Unicode default (root) case mapping.
        let lower = name.lowercased()
        // Step 2.
        var folded = String.UnicodeScalarView()
        for scalar in lower.decomposedStringWithCanonicalMapping.unicodeScalars {
            switch scalar.value {
            case 0x0300...0x036F: continue
            case 0x0131: folded.append("i")             // ı
            case 0x00DF: folded.append(contentsOf: "ss".unicodeScalars) // ß
            case 0x00F8: folded.append("o")             // ø
            case 0x00E6: folded.append(contentsOf: "ae".unicodeScalars) // æ
            case 0x0153: folded.append(contentsOf: "oe".unicodeScalars) // œ
            case 0x0142: folded.append("l")             // ł
            case 0x0111: folded.append("d")             // đ
            default: folded.append(scalar)
            }
        }
        // Step 3.
        let withoutGroups = removeBracketGroups(Array(folded))
        // Step 4/5.
        var tokens: [String] = []
        var current = String.UnicodeScalarView()
        func flush() {
            if !current.isEmpty {
                let token = String(current)
                if !stopTokens.contains(token) { tokens.append(token) }
                current = String.UnicodeScalarView()
            }
        }
        for scalar in withoutGroups {
            if isAlnum(scalar) { current.append(scalar) } else { flush() }
        }
        flush()
        if !tokens.isEmpty { return tokens.joined() }
        var fallback = String.UnicodeScalarView()
        for scalar in withoutGroups where isAlnum(scalar) { fallback.append(scalar) }
        return String(fallback)
    }

    @inline(__always)
    private static func isAlnum(_ s: Unicode.Scalar) -> Bool {
        ("a"..."z").contains(s) || ("0"..."9").contains(s)
    }

    /// Removes non-nested `[...]` and `(...)` groups (an unclosed opener is kept as text).
    private static func removeBracketGroups(_ scalars: [Unicode.Scalar]) -> [Unicode.Scalar] {
        var out: [Unicode.Scalar] = []
        out.reserveCapacity(scalars.count)
        var i = 0
        while i < scalars.count {
            let s = scalars[i]
            let closer: Unicode.Scalar? = s == "[" ? "]" : (s == "(" ? ")" : nil)
            if let closer, let end = scalars[(i + 1)...].firstIndex(of: closer) {
                i = end + 1
                continue
            }
            out.append(s)
            i += 1
        }
        return out
    }
}
