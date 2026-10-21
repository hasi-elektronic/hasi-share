import Foundation

/// Log redaction of CONTRACT §10. Every log line must pass `redact(_:)`.
///
/// Rules, applied in order:
/// 1. registered secret values (length ≥ 3), longest first, literal replace → `***`
/// 2. URL user info `scheme://user:pass@` → `scheme://***@`
/// 3. Xtream stream paths `/(live|movie|series|timeshift)/U/P/` → `/$1/***/***/`
/// 4. sensitive query/assignment values (`password=…`, `token=…`, …) → `key=***`
/// 5. `Bearer <token>` → `Bearer ***`
///
/// Thread-safe; use `Redactor.shared` from the logging layer and register the secrets of
/// every configured source (see `SourceSecrets.redactableValues`).
public final class Redactor: @unchecked Sendable {  // immutable regexes + locked state
    /// Process-wide instance used by the app's logger.
    public static let shared = Redactor()

    private let secrets = LockedState<[String]>([])
    private let rules: [(NSRegularExpression, String)]

    public init() {
        let patterns: [(String, String)] = [
            (#"(?i)\b([a-z][a-z0-9+.-]*://)[^/\s@:]+:[^/\s@]*@"#, "$1***@"),
            (#"(?i)/(live|movie|series|timeshift)/[^/\s?#]+/[^/\s?#]+/"#, "/$1/***/***/"),
            (#"(?i)\b(username|password|pass|pwd|token|auth|key|apikey|api_key|secret|signature|sig|access_token)=([^&\s#"']*)"#, "$1=***"),
            (#"(?i)(Bearer\s+)[A-Za-z0-9._~+/=-]+"#, "$1***"),
        ]
        // The patterns are constants; a failure here is a programming error caught by tests.
        rules = patterns.compactMap { pattern, template in
            (try? NSRegularExpression(pattern: pattern)).map { ($0, template) }
        }
    }

    /// Registers secret values (passwords, usernames, playlist URLs…). Values shorter
    /// than 3 characters are ignored.
    public func register(_ values: [String]) {
        secrets.withLock { list in
            for value in values where value.count >= 3 && !list.contains(value) {
                list.append(value)
            }
            list.sort { $0.count > $1.count }
        }
    }

    /// Removes previously registered values (e.g. when a source is deleted).
    public func unregister(_ values: [String]) {
        secrets.withLock { list in list.removeAll { values.contains($0) } }
    }

    /// Replaces the full set of registered secrets.
    public func setSecrets(_ values: [String]) {
        secrets.withLock { $0 = [] }
        register(values)
    }

    /// Currently registered secret count (for diagnostics/tests).
    public var registeredCount: Int { secrets.withLock { $0.count } }

    /// Returns `input` with all secrets and secret-looking parts replaced by `***`.
    public func redact(_ input: String) -> String {
        var output = input
        let values = secrets.withLock { $0 }
        for value in values where output.contains(value) {
            output = output.replacingOccurrences(of: value, with: "***")
        }
        for (regex, template) in rules {
            let range = NSRange(output.startIndex..<output.endIndex, in: output)
            output = regex.stringByReplacingMatches(in: output, options: [], range: range, withTemplate: template)
        }
        return output
    }

    /// Stateless redaction with an explicit secret list (used by tests and one-off logging).
    public static func redact(_ input: String, secrets: [String]) -> String {
        let redactor = Redactor()
        redactor.register(secrets)
        return redactor.redact(input)
    }
}
