package io.iptvplayer.core.media

import io.iptvplayer.core.error.PlaybackError

/**
 * CONTRACT §6.2 "never give up early", Android part: Media3 is the only engine, so the useful rescue before the
 * first frame is the other format of an Xtream live URL (`/live/U/P/ID.ts` ⇄ `.m3u8`) – tried once, for any error
 * but DRM (a 403/404 on one format often plays in the other). Then the reconnect policy / error card as before.
 */
public object PlaybackRescue {
    /** The other format of an Xtream live URL, null for anything else (query strings are kept). */
    public fun liveAlternate(url: String): String? {
        val q = url.indexOf('?')
        val path = if (q >= 0) url.substring(0, q) else url
        val query = if (q >= 0) url.substring(q) else ""
        val parts = path.split('/').filter { it.isNotEmpty() }
        if (parts.size < 5 || parts[parts.size - 4] != "live") return null
        return when {
            path.endsWith(".m3u8") -> path.removeSuffix(".m3u8") + ".ts" + query
            path.endsWith(".ts") -> path.removeSuffix(".ts") + ".m3u8" + query
            else -> null
        }
    }

    /**
     * Everything but DRM – and, on Android's single engine, but an undecodable codec: the other format of the same
     * channel carries the same codec, and trying it would replace the true card ("codec not supported") with that
     * URL's error (seen: a 404 for the missing .m3u8 twin).
     */
    public fun isRescuable(error: PlaybackError): Boolean = error !is PlaybackError.Drm && error !is PlaybackError.UnsupportedCodec

    /** The single decision of the controller: the URL to try now, or null (go on with reconnect / error card). */
    public fun next(url: String, isLive: Boolean, playedOnce: Boolean, alreadyRescued: Boolean, error: PlaybackError): String? {
        if (!isLive || playedOnce || alreadyRescued || !isRescuable(error)) return null
        return liveAlternate(url)
    }
}
