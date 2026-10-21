import Foundation
import IPTVCore
import os

/// The only logging entry point (docs/SECURITY.md §2): every message passes the `Redactor`
/// (registered source secrets, URL user-info, Xtream path credentials, `password=` …, Bearer
/// tokens). Release builds drop everything below WARNING.
public enum SafeLog {
    private static let logger = Logger(subsystem: "io.iptvplayer", category: "app")

    /// Redacted text exactly as it would be logged (tests).
    public static func redacted(_ message: String) -> String {
        Redactor.shared.redact(message)
    }

    public static func debug(_ message: @autoclosure () -> String) {
        #if DEBUG
        let text = redacted(message())
        logger.debug("\(text, privacy: .public)")
        #endif
    }

    public static func info(_ message: @autoclosure () -> String) {
        #if DEBUG
        let text = redacted(message())
        logger.info("\(text, privacy: .public)")
        #endif
    }

    public static func warning(_ message: @autoclosure () -> String) {
        let text = redacted(message())
        logger.warning("\(text, privacy: .private)")
    }

    public static func error(_ message: @autoclosure () -> String) {
        let text = redacted(message())
        logger.error("\(text, privacy: .private)")
    }
}
