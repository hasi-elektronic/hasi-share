package io.iptvplayer.core.xtream

import io.iptvplayer.core.error.SourceError
import io.iptvplayer.core.error.SourceException
import io.iptvplayer.core.model.XtreamAccountInfo
import io.iptvplayer.core.xtream.XtreamJson.get
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import java.util.Locale

/**
 * Account classification of `player_api.php` without action (CONTRACT §4.4), first match:
 *
 * | Condition | Result |
 * |---|---|
 * | HTTP 401 / 403 | InvalidCredentials |
 * | HTTP 404 | NotFound |
 * | other non-2xx | ServerError(code) |
 * | body not a JSON object (`[]` = empty object, §4.3) | InvalidResponse |
 * | `user_info` missing, `[]`, or `auth` ≠ 1 | InvalidCredentials |
 * | `status` = `Expired` | AccountExpired(exp_date) |
 * | `status` ∈ {Banned, Disabled} | AccountDisabled |
 * | `exp_date` present and < now | AccountExpired(exp_date) |
 * | otherwise | OK |
 *
 * Network failures are classified by the HTTP layer before this runs.
 */
public object XtreamAccountClassifier {
    /**
     * Classifies an HTTP response.
     * @throws SourceException with the error of the table above.
     */
    public fun classify(httpStatus: Int, body: String, nowMs: Long): XtreamAccountInfo {
        if (httpStatus !in 200..299) throw SourceException(SourceError.fromXtreamHttpStatus(httpStatus))
        return classifyJson(XtreamJson.parseOrNull(body), nowMs)
    }

    /**
     * Classifies an already parsed body (null = not JSON).
     * @throws SourceException on every non-OK result.
     */
    public fun classifyJson(json: JsonElement?, nowMs: Long): XtreamAccountInfo {
        val root: JsonObject = when (json) {
            is JsonObject -> json
            is JsonArray -> if (json.isEmpty()) JsonObject(emptyMap()) else fail(SourceError.InvalidResponse)
            else -> fail(SourceError.InvalidResponse)
        }
        val userInfo = XtreamJson.obj(root["user_info"])
        if (userInfo == null || userInfo.isEmpty() || !isAuthenticated(userInfo["auth"])) fail(SourceError.InvalidCredentials)
        val status = XtreamJson.trimmed(userInfo["status"])
        val expiresAtMs = XtreamMapper.epochMs(userInfo["exp_date"])
        when (status?.lowercase(Locale.ROOT)) {
            "expired" -> fail(SourceError.AccountExpired(expiresAtMs))
            "banned", "disabled" -> fail(SourceError.AccountDisabled)
        }
        if (expiresAtMs != null && expiresAtMs < nowMs) fail(SourceError.AccountExpired(expiresAtMs))
        val serverInfo = root["server_info"]
        val formats = XtreamJson.listItems(userInfo["allowed_output_formats"])
            .mapNotNull { XtreamJson.trimmed(it)?.lowercase(Locale.ROOT) }
        return XtreamAccountInfo(
            status = status,
            expiresAtMs = expiresAtMs,
            maxConnections = XtreamJson.int(userInfo["max_connections"]),
            activeConnections = XtreamJson.int(userInfo["active_cons"]),
            allowedOutputFormats = formats,
            serverTimezone = XtreamJson.trimmed(serverInfo["timezone"]) ?: "UTC",
            isTrial = XtreamJson.bool(userInfo["is_trial"]),
            createdAtMs = XtreamMapper.epochMs(userInfo["created_at"]),
        )
    }

    private fun isAuthenticated(auth: JsonElement?): Boolean = XtreamJson.bool(auth)

    private fun fail(error: SourceError): Nothing = throw SourceException(error)
}
