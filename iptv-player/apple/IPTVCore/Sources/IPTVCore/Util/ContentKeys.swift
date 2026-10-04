import Foundation

/// Source fingerprints, item ids and content keys (CONTRACT §1.1). Content keys identify
/// favorites and progress across devices, so they must be identical on every platform.
public enum SourceFingerprint {
    /// `hex(sha256("xtream|" + lowercase(host) + "|" + username))[0..16]`.
    public static func xtream(host: String, username: String) -> String {
        String(Hashing.sha256Hex("xtream|\(host.lowercased())|\(username)").prefix(16))
    }

    /// Fingerprint from a raw (user-entered) server URL; nil if it cannot be normalized.
    public static func xtream(serverUrl: String, username: String) -> String? {
        guard let base = URLNormalizer.xtreamBase(serverUrl), let host = URLNormalizer.host(of: base) else { return nil }
        return xtream(host: host, username: username)
    }

    /// `hex(sha256("m3u|" + normalizeUrl(url)))[0..16]`.
    public static func m3u(url: String) -> String {
        String(Hashing.sha256Hex("m3u|\(URLNormalizer.normalize(url))").prefix(16))
    }

    /// Fingerprint of a source from its secrets.
    public static func of(_ secrets: SourceSecrets) -> String? {
        switch secrets {
        case .m3u(let m3u): return m3u(url: m3u.url)
        case .xtream(let x): return xtream(serverUrl: x.serverUrl, username: x.username)
        }
    }
}

/// Cross-device content keys: `fingerprint + ":" + kind + ":" + itemId`.
public enum ContentKey {
    /// Item id of an M3U entry: `"u" + hex(sha256(entry.url))[0..16]`.
    public static func m3uItemId(entryUrl: String) -> String {
        "u" + Hashing.sha256Hex(entryUrl).prefix(16)
    }

    /// Builds a content key.
    public static func make(fingerprint: String, kind: ContentKind, itemId: String) -> String {
        "\(fingerprint):\(kind.rawValue):\(itemId)"
    }

    /// Splits a content key into its parts, or nil when malformed.
    public static func parse(_ key: String) -> (fingerprint: String, kind: ContentKind, itemId: String)? {
        let parts = key.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3, let kind = ContentKind(rawValue: String(parts[1])) else { return nil }
        return (String(parts[0]), kind, String(parts[2]))
    }
}

/// Device key of CONTRACT §7.1. Raw device identifiers never leave the device.
public enum DeviceKey {
    /// `hex(sha256(DEVICE_KEY_PREFIX + "|" + appId + "|" + rawDeviceId))`.
    /// Apple: `appId` = bundle id, `rawDeviceId` = `identifierForVendor.uuidString`.
    public static func make(appId: String, rawDeviceId: String) -> String {
        Hashing.sha256Hex("\(ProtocolConstants.deviceKeyPrefix)|\(appId)|\(rawDeviceId)")
    }
}
