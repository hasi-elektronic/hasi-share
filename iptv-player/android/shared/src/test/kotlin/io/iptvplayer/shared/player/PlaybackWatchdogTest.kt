package io.iptvplayer.shared.player

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class PlaybackWatchdogTest {
    @Test
    fun stallNeedsBufferingTheFullTimeoutAndNoProgress() {
        assertTrue(PlaybackWatchdog.stalled(true, 0, 12_000, 60_000, 60_200))
        assertFalse("recovered meanwhile", PlaybackWatchdog.stalled(false, 0, 12_000, 60_000, 60_000))
        assertFalse("not yet", PlaybackWatchdog.stalled(true, 0, 11_999, 60_000, 60_000))
        assertFalse("the position moved (slow, not stuck)", PlaybackWatchdog.stalled(true, 0, 12_000, 60_000, 63_000))
    }

    @Test
    fun undecodableVideoOnlyWhenVideoIsPresent() {
        assertTrue(PlaybackWatchdog.videoUndecodable(hasVideo = true, videoSupported = false))
        assertFalse(PlaybackWatchdog.videoUndecodable(hasVideo = true, videoSupported = true))
        assertFalse("radio: audio only is fine", PlaybackWatchdog.videoUndecodable(hasVideo = false, videoSupported = false))
    }

    @Test
    fun decoderStuckNeedsBufferedDataAndNoFrame() {
        assertTrue(PlaybackWatchdog.decoderStuck(hasVideoFormat = true, firstFrameRendered = false, bufferedAheadMs = 6_000))
        assertFalse("still loading: a network matter", PlaybackWatchdog.decoderStuck(true, false, 1_000))
        assertFalse("a frame was shown", PlaybackWatchdog.decoderStuck(true, true, 6_000))
        assertFalse("radio", PlaybackWatchdog.decoderStuck(false, false, 6_000))
    }
}
