package io.iptvplayer.shared.player

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** The flag RefreshWorker defers on (no catalog / EPG download while a stream plays). */
class PlaybackActivityTest {
    @Test
    fun openAndCloseAreBalancedAndNeverNegative() {
        assertFalse(PlaybackActivity.isActive)
        PlaybackActivity.opened()
        assertTrue(PlaybackActivity.isActive)
        PlaybackActivity.closed()
        assertFalse(PlaybackActivity.isActive)
        PlaybackActivity.closed()   // an extra close (release twice) must not hide the next open
        PlaybackActivity.opened()
        assertTrue(PlaybackActivity.isActive)
        PlaybackActivity.closed()
        assertFalse(PlaybackActivity.isActive)
    }
}
