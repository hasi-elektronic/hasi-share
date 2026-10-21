import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Network failure reason (CONTRACT §2).
public enum NetworkReason: String, Codable, Sendable, Hashable, CaseIterable {
    case timeout, dns, refused, tls, offline, other
}

/// Errors when loading/refreshing a source (CONTRACT §2). Identical on all platforms.
public enum SourceError: Error, Sendable, Hashable {
    case network(NetworkReason)
    /// Xtream auth = 0, HTTP 401/403 on player_api, empty user_info.
    case invalidCredentials
    /// Status "Expired" or exp_date < now.
    case accountExpired(expiresAt: Date?)
    /// Status "Banned" | "Disabled".
    case accountDisabled
    /// HTTP 404 on list/EPG URL.
    case notFound
    /// 5xx and other non-2xx.
    case serverError(httpStatus: Int)
    /// Not an M3U / not XMLTV.
    case invalidFormat
    /// Xtream: body is not the expected JSON (e.g. HTML).
    case invalidResponse
    /// Parsed fine, zero playable items.
    case empty
    case cancelled

    /// Stable code used in persistence and logs.
    public var code: String {
        switch self {
        case .network: return "network"
        case .invalidCredentials: return "invalidCredentials"
        case .accountExpired: return "accountExpired"
        case .accountDisabled: return "accountDisabled"
        case .notFound: return "notFound"
        case .serverError: return "serverError"
        case .invalidFormat: return "invalidFormat"
        case .invalidResponse: return "invalidResponse"
        case .empty: return "empty"
        case .cancelled: return "cancelled"
        }
    }

    /// Whether a GET may be retried (CONTRACT §2: Network and 5xx only, never 4xx).
    public var isRetryable: Bool {
        switch self {
        case .network: return true
        case .serverError(let status): return status >= 500
        default: return false
        }
    }
}

extension SourceError: Codable {
    private enum CodingKeys: String, CodingKey { case code, reason, expiresAt, httpStatus }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .code) {
        case "network": self = .network(try c.decodeIfPresent(NetworkReason.self, forKey: .reason) ?? .other)
        case "invalidCredentials": self = .invalidCredentials
        case "accountExpired": self = .accountExpired(expiresAt: try c.decodeIfPresent(Date.self, forKey: .expiresAt))
        case "accountDisabled": self = .accountDisabled
        case "notFound": self = .notFound
        case "serverError": self = .serverError(httpStatus: try c.decodeIfPresent(Int.self, forKey: .httpStatus) ?? 0)
        case "invalidFormat": self = .invalidFormat
        case "invalidResponse": self = .invalidResponse
        case "empty": self = .empty
        default: self = .cancelled
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(code, forKey: .code)
        switch self {
        case .network(let reason): try c.encode(reason, forKey: .reason)
        case .accountExpired(let date): try c.encodeIfPresent(date, forKey: .expiresAt)
        case .serverError(let status): try c.encode(status, forKey: .httpStatus)
        default: break
        }
    }
}

/// Errors during playback (CONTRACT §2).
public enum PlaybackError: Error, Sendable, Hashable {
    case network(NetworkReason)
    /// HTTP 401/403 (connection limit, expired account…).
    case accessDenied(httpStatus: Int)
    /// HTTP 404/410.
    case streamOffline(httpStatus: Int)
    case serverError(httpStatus: Int)
    /// Container not playable by this player (`StreamContainer.rawValue`, e.g. "mpegts").
    case unsupportedFormat(container: String)
    case unsupportedCodec(codec: String?)
    case drm
    case unknown(message: String)
}

/// Pure classifiers from transport/HTTP failures to the error taxonomy.
public enum ErrorClassifier {
    /// Maps a `URLError` code to a network reason; nil means the request was cancelled.
    public static func networkReason(for code: URLError.Code) -> NetworkReason? {
        switch code {
        case .cancelled: return nil
        case .timedOut: return .timeout
        case .cannotFindHost, .dnsLookupFailed: return .dns
        case .cannotConnectToHost: return .refused
        case .secureConnectionFailed, .serverCertificateHasBadDate, .serverCertificateUntrusted,
             .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid,
             .clientCertificateRejected, .clientCertificateRequired:
            return .tls
        case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .internationalRoamingOff:
            return .offline
        default: return .other
        }
    }

    /// Maps any error thrown while loading a source to a `SourceError`.
    public static func sourceError(from error: Error) -> SourceError {
        if let e = error as? SourceError { return e }
        if error is CancellationError { return .cancelled }
        if let e = error as? URLError {
            return networkReason(for: e.code).map(SourceError.network) ?? .cancelled
        }
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain {
            return networkReason(for: URLError.Code(rawValue: ns.code)).map(SourceError.network) ?? .cancelled
        }
        return .network(.other)
    }

    /// Maps a non-2xx status of a list/EPG/API GET to a `SourceError` (nil for 2xx).
    public static func sourceError(httpStatus: Int) -> SourceError? {
        switch httpStatus {
        case 200..<300: return nil
        case 401, 403: return .invalidCredentials
        case 404: return .notFound
        default: return .serverError(httpStatus: httpStatus)
        }
    }

    /// Maps a non-2xx status of a stream request to a `PlaybackError` (nil for 2xx/3xx).
    public static func playbackError(httpStatus: Int) -> PlaybackError? {
        switch httpStatus {
        case 200..<400: return nil
        case 401, 403: return .accessDenied(httpStatus: httpStatus)
        case 404, 410: return .streamOffline(httpStatus: httpStatus)
        default: return .serverError(httpStatus: httpStatus)
        }
    }

    /// Maps a transport error during playback; nil when it was a cancellation.
    public static func playbackError(from error: Error) -> PlaybackError? {
        if let e = error as? PlaybackError { return e }
        if error is CancellationError { return nil }
        if let e = error as? URLError {
            return networkReason(for: e.code).map(PlaybackError.network)
        }
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain {
            return networkReason(for: URLError.Code(rawValue: ns.code)).map(PlaybackError.network)
        }
        return .unknown(message: String(describing: error))
    }
}
