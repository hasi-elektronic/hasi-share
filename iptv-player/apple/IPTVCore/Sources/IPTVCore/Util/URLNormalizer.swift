import Foundation

/// Components of an absolute URL split the same (string-based) way on every platform.
struct URLParts: Sendable, Hashable {
    var scheme: String
    var userInfo: String?   // without the trailing "@"
    var host: String
    var port: String?
    /// Everything after the authority: path, query and fragment, byte-exact.
    var rest: String

    /// Splits `scheme://authority rest`. Returns nil when the string has no `scheme://`.
    static func parse(_ string: String) -> URLParts? {
        guard let schemeEnd = string.range(of: "://") else { return nil }
        let scheme = String(string[string.startIndex..<schemeEnd.lowerBound])
        guard isValidScheme(scheme) else { return nil }
        let afterScheme = string[schemeEnd.upperBound...]
        let authorityEnd = afterScheme.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }) ?? afterScheme.endIndex
        var authority = String(afterScheme[afterScheme.startIndex..<authorityEnd])
        let rest = String(afterScheme[authorityEnd...])
        var userInfo: String?
        if let at = authority.lastIndex(of: "@") {
            userInfo = String(authority[authority.startIndex..<at])
            authority = String(authority[authority.index(after: at)...])
        }
        var host = authority
        var port: String?
        if let colon = authority.lastIndex(of: ":") {
            let candidate = authority[authority.index(after: colon)...]
            if !candidate.isEmpty, candidate.allSatisfy({ $0.isASCII && $0.isNumber }) {
                host = String(authority[authority.startIndex..<colon])
                port = String(candidate)
            }
        }
        return URLParts(scheme: scheme, userInfo: userInfo, host: host, port: port, rest: rest)
    }

    static func isValidScheme(_ scheme: String) -> Bool {
        guard let first = scheme.unicodeScalars.first, first.isASCIILetter else { return false }
        return scheme.unicodeScalars.allSatisfy { $0.isASCIILetter || ("0"..."9").contains($0) || $0 == "+" || $0 == "." || $0 == "-" }
    }

    /// The URL path (without query and fragment).
    var path: String {
        let end = rest.firstIndex(where: { $0 == "?" || $0 == "#" }) ?? rest.endIndex
        return String(rest[rest.startIndex..<end])
    }
}

extension Unicode.Scalar {
    var isASCIILetter: Bool { ("a"..."z").contains(self) || ("A"..."Z").contains(self) }
}

/// URL normalization rules of CONTRACT §1.1 (fingerprints) and §4.1 (Xtream server base).
public enum URLNormalizer {
    /// `normalizeUrl` of CONTRACT §1.1: trim; lowercase scheme and host; drop the default
    /// port (:80 for http, :443 for https); keep path, query and fragment byte-exact.
    /// Strings without `scheme://` are returned trimmed.
    public static func normalize(_ url: String) -> String {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var parts = URLParts.parse(trimmed) else { return trimmed }
        parts.scheme = parts.scheme.lowercased()
        parts.host = parts.host.lowercased()
        if isDefaultPort(scheme: parts.scheme, port: parts.port) { parts.port = nil }
        var out = parts.scheme + "://"
        if let userInfo = parts.userInfo { out += userInfo + "@" }
        out += parts.host
        if let port = parts.port { out += ":" + port }
        return out + parts.rest
    }

    /// Lowercased host of an absolute URL string (port and user info excluded), or nil.
    public static func host(of url: String) -> String? {
        guard let parts = URLParts.parse(url.trimmingCharacters(in: .whitespacesAndNewlines)),
              !parts.host.isEmpty else { return nil }
        return parts.host.lowercased()
    }

    /// Xtream server base URL of CONTRACT §4.1: trim; add `http://` if no scheme; lowercase
    /// scheme and host; drop default port; strip a trailing `/`; strip a trailing
    /// `player_api.php`, `get.php` or `xmltv.php` (with any query); keep a non-empty base path.
    ///
    /// Returns `scheme://host[:port][/path]`, or nil when no usable http(s) host remains.
    public static func xtreamBase(_ input: String) -> String? {
        var trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.range(of: "://") == nil { trimmed = "http://" + trimmed }
        guard var parts = URLParts.parse(trimmed) else { return nil }
        parts.scheme = parts.scheme.lowercased()
        guard parts.scheme == "http" || parts.scheme == "https" else { return nil }
        parts.host = parts.host.lowercased()
        guard !parts.host.isEmpty else { return nil }
        if isDefaultPort(scheme: parts.scheme, port: parts.port) { parts.port = nil }
        var path = parts.path
        while path.hasSuffix("/") { path.removeLast() }
        if let slash = path.lastIndex(of: "/") {
            let last = path[path.index(after: slash)...].lowercased()
            if ["player_api.php", "get.php", "xmltv.php"].contains(last) {
                path = String(path[path.startIndex..<slash])
            }
        }
        while path.hasSuffix("/") { path.removeLast() }
        var out = parts.scheme + "://" + parts.host
        if let port = parts.port { out += ":" + port }
        return out + path
    }

    private static func isDefaultPort(scheme: String, port: String?) -> Bool {
        guard let port, let value = Int(port) else { return false }
        return (scheme == "http" && value == 80) || (scheme == "https" && value == 443)
    }
}
