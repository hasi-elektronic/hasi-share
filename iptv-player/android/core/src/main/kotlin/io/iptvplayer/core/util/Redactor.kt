package io.iptvplayer.core.util

/**
 * Log redaction of CONTRACT §10 (`test-vectors/redaction.json`).
 *
 * Rules, applied **in this order**:
 * 1. every registered secret value (length ≥ 3), longest first, literal replace → `***`
 * 2. user info in URLs (`scheme://user:pass@`) → masked
 * 3. credentials in `/live|movie|series|timeshift/U/P/` paths → masked
 * 4. `username=…`, `password=…`, `token=…` … → `key=***`
 * 5. `Bearer xyz` → `Bearer ***`
 *
 * An instance is a thread-safe registry of secret values (current source usernames, passwords,
 * playlist URLs, session tokens). Use [Redactor.default] as the process-wide registry; every log
 * line of the app must pass [redact] (see [io.iptvplayer.core.util.RedactingLogger]).
 */
public class Redactor {
    private val lock = Any()
    private val refCounts = HashMap<String, Int>()

    @Volatile
    private var snapshot: List<String> = emptyList()

    /**
     * Registers secret values (null/short values are ignored). The percent-encoded form is
     * registered as well, because credentials appear encoded in URLs (CONTRACT §4.5).
     * Registration is reference-counted: each [register] needs a matching [unregister].
     */
    public fun register(vararg values: String?) {
        synchronized(lock) {
            for (v in values.expand()) refCounts[v] = (refCounts[v] ?: 0) + 1
            rebuild()
        }
    }

    /** Reverses one [register] call for each value. */
    public fun unregister(vararg values: String?) {
        synchronized(lock) {
            for (v in values.expand()) {
                val c = (refCounts[v] ?: 0) - 1
                if (c <= 0) refCounts.remove(v) else refCounts[v] = c
            }
            rebuild()
        }
    }

    /** Removes every registered secret. */
    public fun clear() {
        synchronized(lock) {
            refCounts.clear()
            rebuild()
        }
    }

    /** Currently registered secrets, longest first. */
    public fun secrets(): List<String> = snapshot

    /** Redacts [text] with the registered secrets and the generic rules. */
    public fun redact(text: String): String = redact(text, snapshot)

    private fun Array<out String?>.expand(): List<String> = flatMap { v ->
        if (v == null || v.length < MIN_SECRET_LENGTH) {
            emptyList()
        } else {
            val enc = PercentEncoding.encode(v)
            if (enc != v) listOf(v, enc) else listOf(v)
        }
    }

    private fun rebuild() {
        snapshot = refCounts.keys.sortedWith(compareByDescending<String> { it.length }.thenBy { it })
    }

    public companion object {
        /** Secrets shorter than this are never replaced literally (CONTRACT §10 rule 1). */
        public const val MIN_SECRET_LENGTH: Int = 3

        /** Process-wide registry. */
        public val default: Redactor = Redactor()

        private const val MASK = "***"
        private val USERINFO = Regex("""\b([a-z][a-z0-9+.-]*://)[^/\s@:]+:[^/\s@]*@""", RegexOption.IGNORE_CASE)
        private val PATH_CREDS = Regex("""/(live|movie|series|timeshift)/[^/\s?#]+/[^/\s?#]+/""", RegexOption.IGNORE_CASE)
        private val QUERY_SECRETS = Regex(
            """\b(username|password|pass|pwd|token|auth|key|apikey|api_key|secret|signature|sig|access_token)=([^&\s#"']*)""",
            RegexOption.IGNORE_CASE,
        )
        private val BEARER = Regex("""(Bearer\s+)[A-Za-z0-9._~+/=-]+""", RegexOption.IGNORE_CASE)

        /**
         * Pure redaction with an explicit secret list (vector-testable).
         * Secrets shorter than [MIN_SECRET_LENGTH] are ignored; longer ones are replaced first.
         */
        public fun redact(text: String, secrets: Collection<String>): String {
            var s = text
            secrets.asSequence()
                .filter { it.length >= MIN_SECRET_LENGTH }
                .distinct()
                .sortedByDescending { it.length }
                .forEach { secret -> if (s.contains(secret)) s = s.replace(secret, MASK) }
            s = USERINFO.replace(s, "$1***@")
            s = PATH_CREDS.replace(s, "/$1/***/***/")
            s = QUERY_SECRETS.replace(s, "$1=***")
            s = BEARER.replace(s, "$1***")
            return s
        }
    }
}
