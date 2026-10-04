package io.iptvplayer.shared.log

import android.util.Log
import io.iptvplayer.core.util.CoreLogger
import io.iptvplayer.core.util.LogLevel
import io.iptvplayer.core.util.RedactingLogger
import io.iptvplayer.core.util.Redactor

/**
 * The only logging entry point of the Android apps (docs/SECURITY.md §2, CONTRACT §10).
 * Every line passes [Redactor.default] (registered source secrets + generic rules). Release builds
 * call [init] with [LogLevel.WARN]; additionally R8 strips `v/d/i` calls (app/proguard-rules.pro).
 */
object SafeLog {
    @Volatile
    var minLevel: LogLevel = LogLevel.WARN
        private set

    /** Sink, replaceable in JVM unit tests (android.util.Log is not available there). */
    @Volatile
    internal var sink: (LogLevel, String, String, Throwable?) -> Unit = ::androidLog

    /** Configures the minimum level: debug builds VERBOSE, release WARN. */
    @JvmStatic
    fun init(debug: Boolean) {
        minLevel = if (debug) LogLevel.VERBOSE else LogLevel.WARN
    }

    /** A [CoreLogger] for core clients (already redacting). */
    val core: CoreLogger = RedactingLogger(
        delegate = { level, tag, message, t -> emit(level, tag, message, t) },
        redactor = Redactor.default,
        minLevel = LogLevel.VERBOSE,
    )

    @JvmStatic fun v(tag: String, msg: String) = log(LogLevel.VERBOSE, tag, msg, null)
    @JvmStatic fun d(tag: String, msg: String) = log(LogLevel.DEBUG, tag, msg, null)
    @JvmStatic fun i(tag: String, msg: String) = log(LogLevel.INFO, tag, msg, null)
    @JvmStatic fun w(tag: String, msg: String, t: Throwable? = null) = log(LogLevel.WARN, tag, msg, t)
    @JvmStatic fun e(tag: String, msg: String, t: Throwable? = null) = log(LogLevel.ERROR, tag, msg, t)

    private fun log(level: LogLevel, tag: String, msg: String, t: Throwable?) {
        if (level < minLevel) return
        core.log(level, tag, msg, t)
    }

    private fun emit(level: LogLevel, tag: String, message: String, t: Throwable?) {
        if (level < minLevel) return
        sink(level, tag, message, t)
    }

    private fun androidLog(level: LogLevel, tag: String, message: String, t: Throwable?) {
        val tg = "IPTV/$tag".take(23)
        val text = if (t != null) message + "\n" + Log.getStackTraceString(t) else message
        when (level) {
            LogLevel.VERBOSE -> Log.v(tg, text)
            LogLevel.DEBUG -> Log.d(tg, text)
            LogLevel.INFO -> Log.i(tg, text)
            LogLevel.WARN -> Log.w(tg, text)
            LogLevel.ERROR -> Log.e(tg, text)
        }
    }
}
