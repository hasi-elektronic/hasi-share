package io.iptvplayer.core.util

import java.util.Locale

/**
 * A URL split into its parts **without** any re-encoding (java.net.URI would re-encode and
 * break the "byte-exact path/query" rule of CONTRACT §1.1).
 *
 * @property scheme lower-case scheme (e.g. `http`).
 * @property userInfo raw `user:pass` part or null.
 * @property host lower-case host; IPv6 literals keep their brackets.
 * @property port explicit port string or null (default ports are dropped by [UrlNormalizer]).
 * @property rest path + query + fragment, byte-exact (may be empty).
 */
public data class UrlParts(
    val scheme: String,
    val userInfo: String?,
    val host: String,
    val port: String?,
    val rest: String,
) {
    /** Path only (no query/fragment), possibly empty. */
    val path: String
        get() {
            val end = rest.indexOfFirst { it == '?' || it == '#' }
            return if (end < 0) rest else rest.substring(0, end)
        }

    /** `scheme://[userinfo@]host[:port]` */
    val origin: String
        get() = buildString {
            append(scheme).append("://")
            if (userInfo != null) append(userInfo).append('@')
            append(host)
            if (port != null) append(':').append(port)
        }

    override fun toString(): String = origin + rest

    public companion object {
        /**
         * Splits [url] (already trimmed). Returns null when there is no `scheme://`.
         * Scheme and host are lower-cased (ROOT locale); everything else is untouched.
         */
        public fun parse(url: String): UrlParts? {
            val sep = url.indexOf("://")
            if (sep <= 0) return null
            val scheme = url.substring(0, sep)
            if (!scheme.first().isLetter() || scheme.any { !(it.isLetterOrDigit() || it == '+' || it == '-' || it == '.') }) {
                return null
            }
            val afterScheme = url.substring(sep + 3)
            var authEnd = afterScheme.indexOfFirst { it == '/' || it == '?' || it == '#' }
            if (authEnd < 0) authEnd = afterScheme.length
            val authority = afterScheme.substring(0, authEnd)
            val rest = afterScheme.substring(authEnd)
            val at = authority.lastIndexOf('@')
            val userInfo = if (at >= 0) authority.substring(0, at) else null
            val hostPort = if (at >= 0) authority.substring(at + 1) else authority
            val host: String
            var port: String? = null
            if (hostPort.startsWith("[")) {
                val close = hostPort.indexOf(']')
                if (close < 0) {
                    host = hostPort
                } else {
                    host = hostPort.substring(0, close + 1)
                    val after = hostPort.substring(close + 1)
                    if (after.startsWith(":")) port = after.substring(1)
                }
            } else {
                val colon = hostPort.lastIndexOf(':')
                if (colon >= 0) {
                    host = hostPort.substring(0, colon)
                    port = hostPort.substring(colon + 1)
                } else {
                    host = hostPort
                }
            }
            if (port != null && port.isEmpty()) port = null
            return UrlParts(
                scheme = scheme.lowercase(Locale.ROOT),
                userInfo = userInfo,
                host = host.lowercase(Locale.ROOT),
                port = port,
                rest = rest,
            )
        }
    }
}

/**
 * URL normalization rules of CONTRACT §1.1 (`normalizeUrl`) and §4.1 (Xtream base URL).
 */
public object UrlNormalizer {
    private val XTREAM_SCRIPTS = setOf("player_api.php", "get.php", "xmltv.php")

    private fun defaultPort(scheme: String): String? = when (scheme) {
        "http" -> "80"
        "https" -> "443"
        else -> null
    }

    /**
     * CONTRACT §1.1 `normalizeUrl`: trim; lowercase scheme and host; drop the default port
     * (`:80` for http, `:443` for https); keep path, query and fragment byte-exact.
     * Input without `scheme://` is only trimmed.
     */
    public fun normalizeUrl(url: String): String {
        val trimmed = url.trim()
        val parts = UrlParts.parse(trimmed) ?: return trimmed
        return dropDefaultPort(parts).toString()
    }

    private fun dropDefaultPort(parts: UrlParts): UrlParts =
        if (parts.port != null && parts.port == defaultPort(parts.scheme)) parts.copy(port = null) else parts

    /**
     * CONTRACT §4.1 Xtream base: trim; add `http://` when no scheme; lowercase scheme+host;
     * drop default port; strip trailing `/`; strip a trailing `player_api.php`, `get.php` or
     * `xmltv.php` (with any query); keep a non-empty base path (e.g. `/c`).
     * Result: `scheme://host[:port][/path]`.
     */
    public fun xtreamBase(serverUrl: String): String {
        var s = serverUrl.trim()
        if (!s.contains("://")) s = "http://$s"
        val parts = UrlParts.parse(s)?.let(::dropDefaultPort) ?: return s.trimEnd('/')
        var path = parts.path.trimEnd('/')
        val lastSlash = path.lastIndexOf('/')
        val lastSegment = path.substring(lastSlash + 1)
        if (lastSegment.lowercase(Locale.ROOT) in XTREAM_SCRIPTS) {
            path = path.substring(0, maxOf(lastSlash, 0)).trimEnd('/')
        }
        return parts.copy(rest = path).toString()
    }

    /** Host part (lower-case, no port, no user info) of an absolute URL, or null. */
    public fun host(url: String): String? = UrlParts.parse(url.trim())?.host?.takeIf { it.isNotEmpty() }

    /** Host to show in the UI (`example.com`). Never contains credentials. */
    public fun displayHost(url: String): String =
        host(url) ?: host("http://" + url.trim()) ?: ""

    /** True when [url] is an absolute `http`/`https` URL with a host (form validation). */
    public fun isHttpUrl(url: String): Boolean {
        val p = UrlParts.parse(url.trim()) ?: return false
        return (p.scheme == "http" || p.scheme == "https") && p.host.isNotEmpty() && !p.host.contains(' ')
    }

    /**
     * Last non-empty path segment of [url] (query/fragment ignored), or null.
     * Used as display-name fallback for M3U entries (CONTRACT §3.3).
     */
    public fun lastPathSegment(url: String): String? {
        val parts = UrlParts.parse(url.trim())
        val path = parts?.path ?: url.substringBefore('?').substringBefore('#')
        return path.trimEnd('/').substringAfterLast('/').takeIf { it.isNotEmpty() }
    }

    /** Lower-case extension of the last path segment (`mkv`), or null. */
    public fun pathExtension(url: String): String? {
        val seg = lastPathSegment(url) ?: return null
        val dot = seg.lastIndexOf('.')
        if (dot < 0 || dot == seg.lastIndex) return null
        return seg.substring(dot + 1).lowercase(Locale.ROOT)
    }
}
