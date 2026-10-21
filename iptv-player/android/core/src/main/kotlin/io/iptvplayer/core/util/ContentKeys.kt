package io.iptvplayer.core.util

import io.iptvplayer.core.CoreConstants
import io.iptvplayer.core.model.ContentKind
import io.iptvplayer.core.model.SourceSecrets
import java.util.Locale

/**
 * Source fingerprints and content keys (CONTRACT §1.1, `test-vectors/content-keys.json`).
 *
 * ```
 * xtreamFingerprint = hex(sha256("xtream|" + lowercase(host) + "|" + username))[0..16]
 * m3uFingerprint    = hex(sha256("m3u|" + normalizeUrl(url)))[0..16]
 * itemId (M3U)      = "u" + hex(sha256(entry.url))[0..16]
 * contentKey        = fingerprint + ":" + kind + ":" + itemId
 * ```
 * Content keys identify favorites/progress across reinstalls and devices (sync, §8).
 */
public object ContentKeys {
    /** Xtream fingerprint from a bare [host] (port excluded) and the case-sensitive [username]. */
    public fun xtreamFingerprint(host: String, username: String): String =
        Sha256.hex("xtream|" + host.lowercase(Locale.ROOT) + "|" + username).substring(0, 16)

    /** Xtream fingerprint from a user-typed server URL (normalized per §4.1, host only). */
    public fun xtreamFingerprintForServer(serverUrl: String, username: String): String =
        xtreamFingerprint(UrlNormalizer.host(UrlNormalizer.xtreamBase(serverUrl)) ?: serverUrl.trim(), username)

    /** M3U fingerprint of a playlist URL (normalized per §1.1). */
    public fun m3uFingerprint(playlistUrl: String): String =
        Sha256.hex("m3u|" + UrlNormalizer.normalizeUrl(playlistUrl)).substring(0, 16)

    /** Fingerprint of a source from its secrets. */
    public fun fingerprint(secrets: SourceSecrets): String = when (secrets) {
        is SourceSecrets.M3u -> m3uFingerprint(secrets.url)
        is SourceSecrets.Xtream -> xtreamFingerprintForServer(secrets.serverUrl, secrets.username)
    }

    /** M3U item id: `"u" + hex(sha256(entryUrl))[0..16]` (URL exactly as in the playlist). */
    public fun m3uItemId(entryUrl: String): String = "u" + Sha256.hex(entryUrl).substring(0, 16)

    /** `fingerprint:kind:itemId`. */
    public fun contentKey(fingerprint: String, kind: ContentKind, itemId: String): String =
        "$fingerprint:${kind.wire}:$itemId"

    /** Parses a content key; null when malformed. */
    public fun parse(contentKey: String): ParsedContentKey? {
        val first = contentKey.indexOf(':')
        if (first <= 0) return null
        val second = contentKey.indexOf(':', first + 1)
        if (second < 0) return null
        val kind = ContentKind.fromWire(contentKey.substring(first + 1, second)) ?: return null
        val itemId = contentKey.substring(second + 1)
        if (itemId.isEmpty()) return null
        return ParsedContentKey(contentKey.substring(0, first), kind, itemId)
    }
}

/** Parts of a content key. */
public data class ParsedContentKey(val fingerprint: String, val kind: ContentKind, val itemId: String)

/**
 * Device key of CONTRACT §7.1:
 * `hex(sha256(DEVICE_KEY_PREFIX + "|" + applicationId + "|" + ANDROID_ID))`.
 * The raw ANDROID_ID never leaves the device.
 */
public object DeviceKey {
    /** Computes the 64-hex-char device key. */
    public fun compute(applicationId: String, rawDeviceId: String): String =
        Sha256.hex(CoreConstants.DEVICE_KEY_PREFIX + "|" + applicationId + "|" + rawDeviceId)
}
