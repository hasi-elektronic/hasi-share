import Foundation

/// A short excerpt of a description around the matched words (plot hits, SCREENS §3.6).
public struct SearchSnippet: Sendable, Hashable {
    public struct Part: Sendable, Hashable {
        public var text: String
        public var isMatch: Bool
        public init(text: String, isMatch: Bool) {
            self.text = text
            self.isMatch = isMatch
        }
    }

    public var parts: [Part]
    public init(parts: [Part]) { self.parts = parts }
    public var text: String { parts.map(\.text).joined() }
    public var matchedWords: [String] { parts.filter(\.isMatch).map(\.text) }
}

/// Text helpers of the search: query tokens, folded words, snippets, the term dictionary and edit distance.
/// Folding = `CategoryCountry.fold` (case, diacritics, Turkish ı/İ → i) – the same equivalence the FTS index
/// gets from `unicode61 remove_diacritics 2` plus the dotless-i variant (`CatalogPeople.indexed`).
public enum SearchText {
    /// Query tokens as given to FTS (lowercased, split at everything that is not a letter or digit). Turkish
    /// "ı"/"İ" become "i": every indexed text with those letters also carries its "i" variant
    /// (`CatalogPeople.indexed`), so "haberlerı" finds "Haberleri" and "yılmaz" still finds "Yılmaz".
    public static func tokens(_ text: String) -> [String] {
        text.replacingOccurrences(of: "İ", with: "I").replacingOccurrences(of: "ı", with: "i").lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
    }

    /// Folded query tokens (snippet highlighting, dictionary lookups).
    public static func foldedTokens(_ text: String) -> [String] {
        tokens(text).map(CategoryCountry.fold).filter { !$0.isEmpty }
    }

    /// Words of `text` with their ranges, folded.
    static func words(_ text: String) -> [(range: Range<String.Index>, folded: String)] {
        var out: [(Range<String.Index>, String)] = []
        var start: String.Index?
        var i = text.startIndex
        while i < text.endIndex {
            let isWord = text[i].unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) }
            if isWord {
                if start == nil { start = i }
            } else if let s = start {
                out.append((s..<i, CategoryCountry.fold(String(text[s..<i]))))
                start = nil
            }
            i = text.index(after: i)
        }
        if let s = start { out.append((s..<text.endIndex, CategoryCountry.fold(String(text[s..<text.endIndex])))) }
        return out
    }

    /// True when every folded token is the start of some word of `text` (FTS prefix semantics).
    public static func matchesAll(_ text: String, folded tokens: [String]) -> Bool {
        guard !tokens.isEmpty else { return false }
        let w = words(text).map(\.folded)
        return tokens.allSatisfy { t in w.contains { $0.hasPrefix(t) } }
    }

    /// Excerpt of `text` (≤ `maxLength` characters, cut at word boundaries, "…" where cut) around the first
    /// place where the tokens occur in order (the phrase), else the first matched word. Words starting with a
    /// token are marked. Folding-aware: "kizilcik" marks "Kızılcık", "serbeti" marks "Şerbeti".
    public static func snippet(_ text: String, tokens: [String], maxLength: Int = 120) -> SearchSnippet {
        let folded = tokens.map(CategoryCountry.fold).filter { !$0.isEmpty }
        let clean = text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        let words = words(clean)
        let isMatch = words.map { w in folded.contains { w.folded.hasPrefix($0) } }
        // Anchor: the start of the phrase (consecutive words matching consecutive tokens), else first match.
        var anchor: Int? = nil
        if folded.count > 1 {
            for i in words.indices where i + folded.count <= words.count {
                if (0..<folded.count).allSatisfy({ words[i + $0].folded.hasPrefix(folded[$0]) }) { anchor = i; break }
            }
        }
        if anchor == nil { anchor = isMatch.firstIndex(of: true) }
        var lower = clean.startIndex
        if let a = anchor {
            // About a third of the window before the match, starting at a word.
            let lead = maxLength / 3
            var j = a
            while j > 0, clean.distance(from: words[j - 1].range.lowerBound, to: words[a].range.lowerBound) <= lead { j -= 1 }
            lower = words[j].range.lowerBound
        }
        var upper = clean.endIndex
        if clean.distance(from: lower, to: clean.endIndex) > maxLength {
            let limit = clean.index(lower, offsetBy: maxLength)
            upper = words.last(where: { $0.range.upperBound <= limit && $0.range.lowerBound >= lower })?.range.upperBound ?? limit
        }
        var parts: [SearchSnippet.Part] = []
        if lower > clean.startIndex { parts.append(.init(text: "…", isMatch: false)) }
        var cursor = lower
        for (index, w) in words.enumerated() where w.range.lowerBound >= lower && w.range.upperBound <= upper && isMatch[index] {
            if cursor < w.range.lowerBound { parts.append(.init(text: String(clean[cursor..<w.range.lowerBound]), isMatch: false)) }
            parts.append(.init(text: String(clean[w.range]), isMatch: true))
            cursor = w.range.upperBound
        }
        if cursor < upper { parts.append(.init(text: String(clean[cursor..<upper]), isMatch: false)) }
        if upper < clean.endIndex { parts.append(.init(text: "…", isMatch: false)) }
        return SearchSnippet(parts: parts)
    }

    // MARK: Term dictionary (did-you-mean)

    /// Dictionary terms of a title / people text: folded words of ≥ 3 characters that are not numbers,
    /// with a display form (lowercased original: "konuşanlar"). The dotless-i variant is not a term.
    public static func terms(_ text: String) -> [(term: String, display: String)] {
        let display = CatalogPeople.display(text)
        var out: [(String, String)] = []
        for w in words(display) {
            let term = w.folded
            guard term.count >= 3, term.count <= 32, !term.allSatisfy(\.isNumber) else { continue }
            out.append((term, String(display[w.range]).lowercased()))
        }
        return out
    }

    /// Indexed form of a term in the trigram table: padded with spaces so short words share their edge
    /// trigrams (" ky" / "ya " for "kya" → "kaya").
    static func gram(_ term: String) -> String { " \(term) " }

    /// FTS5 trigram OR-query for a folded token.
    static func trigramQuery(_ token: String) -> String? {
        let chars = Array(gram(token))
        guard chars.count >= 3 else { return nil }
        var seen = Set<String>()
        var grams: [String] = []
        for i in 0...(chars.count - 3) {
            let g = String(chars[i..<(i + 3)])
            if !g.contains("\""), seen.insert(g).inserted { grams.append("\"\(g)\"") }
        }
        return grams.isEmpty ? nil : grams.joined(separator: " OR ")
    }

    /// Optimal string alignment distance (Levenshtein + adjacent transposition), early exit above `limit`.
    public static func distance(_ a: String, _ b: String, limit: Int = .max) -> Int {
        let a = Array(a), b = Array(b)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        if abs(a.count - b.count) > limit { return limit + 1 }
        var prev2 = [Int](repeating: 0, count: b.count + 1)
        var prev = Array(0...b.count)
        var cur = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            cur[0] = i
            var rowMin = cur[0]
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                var v = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost)
                if i > 1, j > 1, a[i - 1] == b[j - 2], a[i - 2] == b[j - 1] { v = min(v, prev2[j - 2] + 1) }
                cur[j] = v
                rowMin = min(rowMin, v)
            }
            if rowMin > limit { return limit + 1 }
            (prev2, prev, cur) = (prev, cur, prev2)
        }
        return prev[b.count]
    }

    /// Allowed typos for a token of this length.
    static func maxTypos(_ length: Int) -> Int { length <= 4 ? 1 : 2 }
}
