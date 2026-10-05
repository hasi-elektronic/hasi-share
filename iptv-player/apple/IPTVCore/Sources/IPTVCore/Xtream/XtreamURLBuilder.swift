import Foundation

/// Platform whose player decides the live stream extension (CONTRACT §4.5).
public enum StreamPlatform: String, Sendable, Hashable, Codable {
    case android
    case apple
}

/// Builds every Xtream URL (CONTRACT §4.2, §4.5). Credentials are percent-encoded with the
/// unreserved-only rule. Stream URLs contain credentials: build them at play time, never
/// persist or log them unredacted.
public struct XtreamURLBuilder: Sendable, Hashable {
    /// Normalized base (`scheme://host[:port][/path]`).
    public let base: String
    public let username: String
    public let password: String

    /// Returns nil when `serverUrl` cannot be normalized to an http(s) base.
    public init?(serverUrl: String, username: String, password: String) {
        guard let base = URLNormalizer.xtreamBase(serverUrl), URL(string: base) != nil else { return nil }
        self.base = base
        self.username = username
        self.password = password
    }

    public init?(secrets: XtreamSecrets) {
        self.init(serverUrl: secrets.serverUrl, username: secrets.username, password: secrets.password)
    }

    /// Lowercased host of the base (used for the source fingerprint).
    public var host: String { URLNormalizer.host(of: base) ?? "" }

    private var u: String { PercentEncoding.encode(username) }
    private var p: String { PercentEncoding.encode(password) }

    private func url(_ string: String) -> URL {
        // All variable parts are percent-encoded and the base was validated in init.
        URL(string: string) ?? URL(string: base)!
    }

    /// `{base}/player_api.php?username=U&password=P[&action=…][&extra…]`.
    public func apiURL(action: String? = nil, parameters: [(String, String)] = []) -> URL {
        var items: [(String, String)] = [("username", username), ("password", password)]
        if let action { items.append(("action", action)) }
        items.append(contentsOf: parameters)
        return url("\(base)/player_api.php?\(PercentEncoding.query(items))")
    }

    /// `{base}/xmltv.php?username=U&password=P`.
    public func xmltvURL() -> URL {
        url("\(base)/xmltv.php?\(PercentEncoding.query([("username", username), ("password", password)]))")
    }

    /// `{base}/live/U/P/{streamId}.{ext}`.
    public func liveURL(streamId: String, ext: String) -> URL {
        url("\(base)/live/\(u)/\(p)/\(PercentEncoding.encode(streamId)).\(PercentEncoding.encode(ext))")
    }

    /// `{base}/movie/U/P/{streamId}.{containerExt}`.
    public func movieURL(streamId: String, containerExt: String) -> URL {
        url("\(base)/movie/\(u)/\(p)/\(PercentEncoding.encode(streamId)).\(PercentEncoding.encode(containerExt))")
    }

    /// `{base}/series/U/P/{episodeId}.{containerExt}`.
    public func episodeURL(episodeId: String, containerExt: String) -> URL {
        url("\(base)/series/\(u)/\(p)/\(PercentEncoding.encode(episodeId)).\(PercentEncoding.encode(containerExt))")
    }

    /// `{base}/timeshift/U/P/{durationMinutes}/{start}/{streamId}.{ext}` where `start` is the
    /// programme start formatted `yyyy-MM-dd:HH-mm` in the SERVER time zone (fallback UTC)
    /// and `durationMinutes = ceil((end − start) / 60 s)`.
    public func timeshiftURL(streamId: String, start: Date, end: Date, serverTimezone: String?, ext: String) -> URL {
        let minutes = max(1, Int((end.timeIntervalSince(start) / 60).rounded(.up)))
        let startText = Self.timeshiftStart(start, serverTimezone: serverTimezone)
        return url("\(base)/timeshift/\(u)/\(p)/\(minutes)/\(startText)/\(PercentEncoding.encode(streamId)).\(PercentEncoding.encode(ext))")
    }

    /// `yyyy-MM-dd:HH-mm` in the given IANA zone (unknown/nil → UTC).
    public static func timeshiftStart(_ date: Date, serverTimezone: String?) -> String {
        let zone = serverTimezone.flatMap { TimeZone(identifier: $0) } ?? TimeZone(identifier: "UTC")!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        func pad(_ v: Int?, _ width: Int = 2) -> String {
            let s = String(v ?? 0)
            return String(repeating: "0", count: max(0, width - s.count)) + s
        }
        return "\(pad(c.year, 4))-\(pad(c.month))-\(pad(c.day)):\(pad(c.hour))-\(pad(c.minute))"
    }

    /// Live stream extension for a platform (CONTRACT §4.5). `allowedOutputFormats`
    /// missing/empty ⇒ both allowed.
    /// - Android: `ts` if allowed, else `m3u8`.
    /// - Apple: `m3u8`; throws `PlaybackError.unsupportedFormat("mpegts")` when the account
    ///   allows TS but not HLS (AVPlayer cannot play progressive MPEG-TS).
    ///
    /// - Parameter vlcAvailable: Apple apps with the VLCKit engine (CONTRACT §4.5): `m3u8`
    ///   stays preferred (AVPlayer), but `ts`-only accounts get `ts` (played by VLCKit)
    ///   instead of an error. Ignored on Android.
    public static func liveExtension(platform: StreamPlatform, allowedOutputFormats: [String], vlcAvailable: Bool = false) throws -> String {
        let allowed = Set(allowedOutputFormats.map { $0.lowercased() })
        let tsAllowed = allowed.isEmpty || allowed.contains("ts")
        let hlsAllowed = allowed.isEmpty || allowed.contains("m3u8") || allowed.contains("hls")
        switch platform {
        case .android:
            return tsAllowed ? "ts" : "m3u8"
        case .apple:
            if !hlsAllowed && tsAllowed {
                if vlcAvailable { return "ts" }
                throw PlaybackError.unsupportedFormat(container: StreamContainer.mpegts.rawValue)
            }
            return "m3u8"
        }
    }
}
