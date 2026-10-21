package io.iptvplayer.core.media

import io.iptvplayer.core.error.NetworkReason
import io.iptvplayer.core.error.PlaybackError
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

/** CONTRACT §6.2, Android: the live format variant before the first frame (parity with Apple PlaybackRescueTests). */
class PlaybackRescueTest {
    @Test
    fun liveAlternateSwapsTheXtreamLiveFormat() {
        assertEquals("http://h:8080/live/u/p/7.ts", PlaybackRescue.liveAlternate("http://h:8080/live/u/p/7.m3u8"))
        assertEquals("http://h/live/u/p/7.m3u8", PlaybackRescue.liveAlternate("http://h/live/u/p/7.ts"))
        assertEquals("http://h/live/u/p/7.m3u8?token=x", PlaybackRescue.liveAlternate("http://h/live/u/p/7.ts?token=x"))
        assertNull(PlaybackRescue.liveAlternate("http://h/hls/channel/index.m3u8"))
        assertNull(PlaybackRescue.liveAlternate("http://h/movie/u/p/1.ts"))
    }

    @Test
    fun nextOnlyBeforeTheFirstFrameOnceAndNotForDrm() {
        val url = "http://h/live/u/p/7.ts"
        val e = PlaybackError.StreamOffline(404)
        assertEquals("http://h/live/u/p/7.m3u8", PlaybackRescue.next(url, isLive = true, playedOnce = false, alreadyRescued = false, error = e))
        assertEquals("http://h/live/u/p/7.m3u8",
            PlaybackRescue.next(url, true, false, false, PlaybackError.AccessDenied(403)), "403 is rescued too")
        assertEquals("http://h/live/u/p/7.m3u8",
            PlaybackRescue.next(url, true, false, false, PlaybackError.Network(NetworkReason.TIMEOUT)))
        assertNull(PlaybackRescue.next(url, isLive = true, playedOnce = true, alreadyRescued = false, error = e), "after a frame: reconnect")
        assertNull(PlaybackRescue.next(url, isLive = true, playedOnce = false, alreadyRescued = true, error = e), "once")
        assertNull(PlaybackRescue.next(url, isLive = false, playedOnce = false, alreadyRescued = false, error = e), "VOD has no variant")
        assertNull(PlaybackRescue.next(url, true, false, false, PlaybackError.Drm))
        assertNull(PlaybackRescue.next(url, true, false, false, PlaybackError.UnsupportedCodec("video/hevc")), "same codec in the other format: keep the true card")
    }
}
