import Foundation

/// Source type (CONTRACT §1).
public enum SourceType: String, Codable, Sendable, Hashable, CaseIterable {
    case m3u
    case xtream
}

/// Xtream account details shown in source management (CONTRACT §1, §4.4).
public struct XtreamAccountInfo: Codable, Sendable, Hashable {
    /// Raw `user_info.status` (e.g. "Active").
    public var status: String
    public var expiresAt: Date?
    public var maxConnections: Int?
    public var activeConnections: Int?
    /// Lowercased `allowed_output_formats`; empty means "all allowed".
    public var allowedOutputFormats: [String]
    /// IANA zone of the panel (`server_info.timezone`, default "UTC"); used only for catch-up URLs.
    public var serverTimezone: String

    public init(status: String, expiresAt: Date?, maxConnections: Int?, activeConnections: Int?,
                allowedOutputFormats: [String], serverTimezone: String) {
        self.status = status
        self.expiresAt = expiresAt
        self.maxConnections = maxConnections
        self.activeConnections = activeConnections
        self.allowedOutputFormats = allowedOutputFormats
        self.serverTimezone = serverTimezone
    }
}

/// Result of the last refresh of a source (status badge + summary in source management).
public struct SourceStatus: Codable, Sendable, Hashable {
    /// nil on success.
    public var error: SourceError?
    public var liveCount: Int
    public var movieCount: Int
    public var seriesCount: Int
    public var epgProgramCount: Int?

    public init(error: SourceError? = nil, liveCount: Int = 0, movieCount: Int = 0,
                seriesCount: Int = 0, epgProgramCount: Int? = nil) {
        self.error = error
        self.liveCount = liveCount
        self.movieCount = movieCount
        self.seriesCount = seriesCount
        self.epgProgramCount = epgProgramCount
    }

    public var isOK: Bool { error == nil }
}

/// A configured source (CONTRACT §1). Contains no secrets – those live in `SourceSecrets`
/// (Keychain), keyed by `id`.
public struct Source: Codable, Sendable, Hashable, Identifiable {
    /// UUID string.
    public var id: String
    public var name: String
    public var type: SourceType
    /// Host only, for UI ("example.com"). Never contains credentials.
    public var displayHost: String
    /// True when the user set an EPG URL instead of using the playlist/panel one.
    public var epgUrlOverride: Bool
    /// User correction for wrong EPG offsets (−720…720, 15-minute steps in the UI).
    public var epgShiftMinutes: Int
    /// 0 = off; UI offers 6/12/24.
    public var autoRefreshHours: Int
    public var createdAt: Date
    public var lastRefreshAt: Date?
    public var lastRefreshResult: SourceStatus?
    public var xtreamAccount: XtreamAccountInfo?

    public init(id: String = UUID().uuidString, name: String, type: SourceType, displayHost: String,
                epgUrlOverride: Bool = false, epgShiftMinutes: Int = 0, autoRefreshHours: Int = 24,
                createdAt: Date = Date(), lastRefreshAt: Date? = nil,
                lastRefreshResult: SourceStatus? = nil, xtreamAccount: XtreamAccountInfo? = nil) {
        self.id = id
        self.name = name
        self.type = type
        self.displayHost = displayHost
        self.epgUrlOverride = epgUrlOverride
        self.epgShiftMinutes = epgShiftMinutes
        self.autoRefreshHours = autoRefreshHours
        self.createdAt = createdAt
        self.lastRefreshAt = lastRefreshAt
        self.lastRefreshResult = lastRefreshResult
        self.xtreamAccount = xtreamAccount
    }

    /// Creates a new source record for the given secrets (display host derived from them).
    public static func make(name: String, secrets: SourceSecrets, id: String = UUID().uuidString,
                            now: Date = Date()) -> Source {
        Source(id: id, name: name, type: secrets.type, displayHost: secrets.displayHost,
               epgUrlOverride: secrets.epgUrl != nil, createdAt: now)
    }

    /// True if an auto refresh is due at `now`.
    public func isRefreshDue(now: Date) -> Bool {
        guard autoRefreshHours > 0 else { return false }
        guard let last = lastRefreshAt else { return true }
        return now.timeIntervalSince(last) >= TimeInterval(autoRefreshHours) * 3600
    }
}

/// Secrets of an M3U source.
public struct M3USecrets: Codable, Sendable, Hashable {
    public var url: String
    public var epgUrl: String?
    public var userAgent: String?

    public init(url: String, epgUrl: String? = nil, userAgent: String? = nil) {
        self.url = url
        self.epgUrl = epgUrl
        self.userAgent = userAgent
    }
}

/// Secrets of an Xtream Codes source. `serverUrl` is the user input; it is normalized
/// (CONTRACT §4.1) whenever URLs are built.
public struct XtreamSecrets: Codable, Sendable, Hashable {
    public var serverUrl: String
    public var username: String
    public var password: String
    public var epgUrl: String?

    public init(serverUrl: String, username: String, password: String, epgUrl: String? = nil) {
        self.serverUrl = serverUrl
        self.username = username
        self.password = password
        self.epgUrl = epgUrl
    }
}

/// Secrets of a source – stored ONLY in the Keychain, keyed by `Source.id` (CONTRACT §1).
/// Encoded as a flat JSON object with a `type` discriminator ("m3u" | "xtream").
public enum SourceSecrets: Codable, Sendable, Hashable {
    case m3u(M3USecrets)
    case xtream(XtreamSecrets)

    public var type: SourceType {
        switch self {
        case .m3u: return .m3u
        case .xtream: return .xtream
        }
    }

    /// The EPG URL override, if any.
    public var epgUrl: String? {
        switch self {
        case .m3u(let s): return s.epgUrl
        case .xtream(let s): return s.epgUrl
        }
    }

    /// Host for UI display (never secrets).
    public var displayHost: String {
        switch self {
        case .m3u(let s): return URLNormalizer.host(of: s.url) ?? ""
        case .xtream(let s): return URLNormalizer.xtreamBase(s.serverUrl).flatMap(URLNormalizer.host(of:)) ?? ""
        }
    }

    /// Values that must be registered with the `Redactor` while this source exists.
    public var redactableValues: [String] {
        switch self {
        case .m3u(let s): return [s.url, s.epgUrl].compactMap { $0 }
        case .xtream(let s):
            return [s.username, s.password, PercentEncoding.encode(s.username), PercentEncoding.encode(s.password)]
                + [s.epgUrl].compactMap { $0 }
        }
    }

    private enum CodingKeys: String, CodingKey {
        case type, url, epgUrl, userAgent, serverUrl, username, password
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(SourceType.self, forKey: .type) {
        case .m3u:
            self = .m3u(M3USecrets(url: try c.decode(String.self, forKey: .url),
                                   epgUrl: try c.decodeIfPresent(String.self, forKey: .epgUrl),
                                   userAgent: try c.decodeIfPresent(String.self, forKey: .userAgent)))
        case .xtream:
            self = .xtream(XtreamSecrets(serverUrl: try c.decode(String.self, forKey: .serverUrl),
                                         username: try c.decode(String.self, forKey: .username),
                                         password: try c.decode(String.self, forKey: .password),
                                         epgUrl: try c.decodeIfPresent(String.self, forKey: .epgUrl)))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(type, forKey: .type)
        switch self {
        case .m3u(let s):
            try c.encode(s.url, forKey: .url)
            try c.encodeIfPresent(s.epgUrl, forKey: .epgUrl)
            try c.encodeIfPresent(s.userAgent, forKey: .userAgent)
        case .xtream(let s):
            try c.encode(s.serverUrl, forKey: .serverUrl)
            try c.encode(s.username, forKey: .username)
            try c.encode(s.password, forKey: .password)
            try c.encodeIfPresent(s.epgUrl, forKey: .epgUrl)
        }
    }
}
