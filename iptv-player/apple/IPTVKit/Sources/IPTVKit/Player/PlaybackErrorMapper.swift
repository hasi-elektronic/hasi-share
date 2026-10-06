import Foundation
import IPTVCore
#if canImport(AVFoundation)
import AVFoundation
#endif

/// Maps AVFoundation / CoreMedia / URL errors to the shared `PlaybackError` taxonomy
/// (CONTRACT §2) and decides whether the reconnect policy applies.
public enum PlaybackErrorMapper {
    static let avFoundationDomain = "AVFoundationErrorDomain"
    static let coreMediaDomain = "CoreMediaErrorDomain"

    // AVError codes (stable raw values, avoid availability differences).
    static let contentIsProtected = -11831
    static let decoderNotFound = -11833
    static let decodeFailed = -11821
    static let fileFormatNotRecognized = -11828
    static let failedToParse = -11853
    static let contentIsNotAuthorized = -11835
    static let noLongerPlayable = -11867
    static let serverIncorrectlyConfigured = -11850
    static let contentIsUnavailable = -11863
    static let unsupportedOutputSettings = -11861

    /// Maps an error reported by `AVPlayerItem` (`error`, failed-to-play notification, error log).
    /// - Parameter container: detected container, used for "format not supported" messages.
    public static func map(_ error: Error, container: StreamContainer = .unknown) -> PlaybackError {
        let ns = error as NSError
        // Walk the underlying-error chain; HTTP statuses and URL errors usually sit deeper.
        var chain: [NSError] = [ns]
        var cursor = ns
        while let underlying = cursor.userInfo[NSUnderlyingErrorKey] as? NSError, chain.count < 6 {
            chain.append(underlying)
            cursor = underlying
        }
        for e in chain {
            if let status = httpStatus(in: e) ?? httpStatus(forCode: e), let mapped = ErrorClassifier.playbackError(httpStatus: status) {
                return mapped
            }
            if e.domain == NSURLErrorDomain {
                if let reason = ErrorClassifier.networkReason(for: URLError.Code(rawValue: e.code)) { return .network(reason) }
            }
        }
        for e in chain where e.domain == avFoundationDomain {
            switch e.code {
            case contentIsProtected, contentIsNotAuthorized: return .drm
            case decoderNotFound, decodeFailed, unsupportedOutputSettings: return .unsupportedCodec(codec: nil)
            case fileFormatNotRecognized, failedToParse:
                return .unsupportedFormat(container: container == .unknown ? "unknown" : container.rawValue)
            case contentIsUnavailable: return .streamOffline(httpStatus: 404)
            default: continue
            }
        }
        for e in chain where e.domain == coreMediaDomain {
            switch e.code {
            case -12971, -12318, -12888: return .network(.other)    // segment/playlist load failures, stalls
            default: continue
            }
        }
        return .unknown(message: "\(ns.domain) \(ns.code)")
    }

    /// HTTP status behind the codes AVPlayer reports for a progressive file / playlist answering an
    /// HTTP error: NSURLErrorDomain (userAuthenticationRequired 401, noPermissionsToReadFile 403,
    /// fileDoesNotExist 404) and the underlying CoreMedia/OSStatus code (-12937 401, -12660 403,
    /// -12938 404). 410/5xx come as NSURLErrorResourceUnavailable with undocumented OSStatus codes –
    /// those are left to the HTTP probe (`PlayerController`).
    static func httpStatus(forCode error: NSError) -> Int? {
        switch error.domain {
        case NSURLErrorDomain:
            switch error.code {
            case NSURLErrorUserAuthenticationRequired: return 401
            case NSURLErrorNoPermissionsToReadFile: return 403
            case NSURLErrorFileDoesNotExist: return 404
            default: return nil
            }
        case coreMediaDomain, NSOSStatusErrorDomain:
            switch error.code {
            case -12937: return 401
            case -12660: return 403
            case -12938: return 404
            default: return nil
            }
        default: return nil
        }
    }

    /// Status from "HTTP 404: File Not Found"-style descriptions CoreMedia uses.
    static func httpStatus(in error: NSError) -> Int? {
        let text = (error.userInfo[NSLocalizedDescriptionKey] as? String ?? "") + " " +
            (error.userInfo["NSDescription"] as? String ?? "")
        guard let range = text.range(of: #"HTTP (\d{3})"#, options: .regularExpression) else { return nil }
        return Int(text[range].dropFirst(5))
    }

    /// Errors handled by the reconnect policy (1-2-4-8-15 s, 5 attempts): transient network
    /// and server problems. Format/codec/DRM/denied errors go straight to the error card.
    public static func isRecoverable(_ error: PlaybackError) -> Bool {
        switch error {
        case .network: return true
        case .serverError(let status): return status >= 500
        case .unknown: return true
        default: return false
        }
    }
}
