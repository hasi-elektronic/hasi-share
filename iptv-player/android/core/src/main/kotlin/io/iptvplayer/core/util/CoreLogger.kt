package io.iptvplayer.core.util

/** Log levels of [CoreLogger]. Release builds should log nothing below [WARN] (CONTRACT §10). */
public enum class LogLevel { VERBOSE, DEBUG, INFO, WARN, ERROR }

/**
 * Logging sink used by core (no Android dependency). The Android layer adapts it to `Log`/Timber.
 * Core never logs secrets directly; wrap the sink in [RedactingLogger] anyway.
 */
public fun interface CoreLogger {
    /** Emits one log line. */
    public fun log(level: LogLevel, tag: String, message: String, throwable: Throwable?)

    public companion object {
        /** Discards everything. */
        public val NONE: CoreLogger = CoreLogger { _, _, _, _ -> }
    }
}

/**
 * A [CoreLogger] that drops lines below [minLevel] and passes every message (and the message
 * of every throwable in the cause chain) through [redactor] before delegating.
 */
public class RedactingLogger(
    private val delegate: CoreLogger,
    private val redactor: Redactor = Redactor.default,
    private val minLevel: LogLevel = LogLevel.VERBOSE,
) : CoreLogger {
    override fun log(level: LogLevel, tag: String, message: String, throwable: Throwable?) {
        if (level < minLevel) return
        delegate.log(level, tag, redactor.redact(message), throwable?.let { redactThrowable(it, 0) })
    }

    private fun redactThrowable(t: Throwable, depth: Int): Throwable {
        val redacted = RedactedThrowable(
            t.javaClass.name + (t.message?.let { ": " + redactor.redact(it) } ?: ""),
            t.cause?.takeIf { depth < 5 && it !== t }?.let { redactThrowable(it, depth + 1) },
        )
        redacted.stackTrace = t.stackTrace
        return redacted
    }
}

/** Stand-in for a throwable whose message was redacted; keeps the original stack trace. */
public class RedactedThrowable(message: String, cause: Throwable?) : Throwable(message, cause) {
    override fun toString(): String = message ?: "RedactedThrowable"
}

internal fun CoreLogger.d(tag: String, msg: String) = log(LogLevel.DEBUG, tag, msg, null)
internal fun CoreLogger.i(tag: String, msg: String) = log(LogLevel.INFO, tag, msg, null)
internal fun CoreLogger.w(tag: String, msg: String, t: Throwable? = null) = log(LogLevel.WARN, tag, msg, t)
