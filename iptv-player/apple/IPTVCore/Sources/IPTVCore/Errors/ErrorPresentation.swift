import Foundation

/// Actions offered on an error card (docs/SCREENS.md §4).
public enum ErrorAction: String, Sendable, Hashable, CaseIterable {
    case retry, edit, deleteSource, refresh, channelList, back
}

/// Localizable presentation of an error: keys from `spec/strings.json`
/// (`Localizable.xcstrings`) with positional string arguments (`{0}`, `{1}`).
public struct ErrorPresentation: Sendable, Hashable {
    public var titleKey: String
    public var titleArgs: [String]
    public var bodyKey: String
    public var bodyArgs: [String]
    /// Optional extra hint line (e.g. Apple + MPEG-TS: "ask your provider for HLS").
    public var hintKey: String?
    public var actions: [ErrorAction]

    public init(titleKey: String, titleArgs: [String] = [], bodyKey: String, bodyArgs: [String] = [],
                hintKey: String? = nil, actions: [ErrorAction]) {
        self.titleKey = titleKey
        self.titleArgs = titleArgs
        self.bodyKey = bodyKey
        self.bodyArgs = bodyArgs
        self.hintKey = hintKey
        self.actions = actions
    }
}

extension SourceError {
    /// Localization keys and actions for this error. `formatDate` renders the expiry date
    /// (the UI passes a formatter in the user's locale/time zone).
    public func presentation(formatDate: (Date) -> String = { ISO8601DateFormatter().string(from: $0) }) -> ErrorPresentation {
        switch self {
        case .network(.offline):
            return ErrorPresentation(titleKey: "err_offline_title", bodyKey: "err_offline_body", actions: [.retry])
        case .network(let reason):
            let body: String
            switch reason {
            case .timeout: body = "err_timeout_body"
            case .dns: body = "err_dns_body"
            case .refused: body = "err_refused_body"
            case .tls: body = "err_tls_body"
            case .offline, .other: body = "err_network_body"
            }
            return ErrorPresentation(titleKey: "err_unreachable_title", bodyKey: body, actions: [.retry, .edit])
        case .invalidCredentials:
            return ErrorPresentation(titleKey: "err_credentials_title", bodyKey: "err_credentials_body", actions: [.edit])
        case .accountExpired(let date):
            if let date {
                return ErrorPresentation(titleKey: "err_expired_title", bodyKey: "err_expired_body",
                                         bodyArgs: [formatDate(date)], actions: [.edit, .deleteSource])
            }
            return ErrorPresentation(titleKey: "err_expired_title", bodyKey: "err_expired_body_nodate", actions: [.edit, .deleteSource])
        case .accountDisabled:
            return ErrorPresentation(titleKey: "err_disabled_title", bodyKey: "err_disabled_body", actions: [.edit])
        case .notFound:
            return ErrorPresentation(titleKey: "err_notfound_title", bodyKey: "err_notfound_body", actions: [.edit])
        case .serverError(let status):
            return ErrorPresentation(titleKey: "err_server_title", titleArgs: [String(status)], bodyKey: "err_server_body", actions: [.retry])
        case .invalidFormat:
            return ErrorPresentation(titleKey: "err_format_title", bodyKey: "err_format_body", actions: [.edit])
        case .invalidResponse:
            return ErrorPresentation(titleKey: "err_response_title", bodyKey: "err_response_body", actions: [.edit])
        case .empty:
            return ErrorPresentation(titleKey: "err_empty_title", bodyKey: "err_empty_body", actions: [.refresh])
        case .cancelled:
            // Cancellation is never shown; a neutral fallback keeps the API total.
            return ErrorPresentation(titleKey: "err_unreachable_title", bodyKey: "err_network_body", actions: [.retry])
        }
    }
}

extension PlaybackError {
    /// Localization keys and actions for this playback error.
    public var presentation: ErrorPresentation {
        switch self {
        case .network:
            return ErrorPresentation(titleKey: "perr_network_title", bodyKey: "perr_network_body", actions: [.retry, .channelList, .back])
        case .accessDenied:
            return ErrorPresentation(titleKey: "perr_denied_title", bodyKey: "perr_denied_body", actions: [.retry])
        case .streamOffline:
            return ErrorPresentation(titleKey: "perr_offline_title", bodyKey: "perr_offline_body", actions: [.retry, .channelList])
        case .serverError(let status):
            return ErrorPresentation(titleKey: "err_server_title", titleArgs: [String(status)], bodyKey: "err_server_body", actions: [.retry])
        case .unsupportedFormat(let container):
            return ErrorPresentation(titleKey: "perr_format_title", bodyKey: "perr_format_body",
                                     bodyArgs: [StreamContainer(rawValue: container)?.displayName ?? container],
                                     hintKey: container == StreamContainer.mpegts.rawValue ? "perr_format_apple_ts" : nil,
                                     actions: [.back])
        case .unsupportedCodec:
            return ErrorPresentation(titleKey: "perr_codec_title", bodyKey: "perr_codec_body", actions: [.back])
        case .drm:
            return ErrorPresentation(titleKey: "perr_drm_title", bodyKey: "perr_drm_body", actions: [.back])
        case .unknown(let message):
            return ErrorPresentation(titleKey: "perr_unknown_title", bodyKey: "err_network_body", bodyArgs: [message], actions: [.retry, .back])
        }
    }
}
