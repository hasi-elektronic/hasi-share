package io.iptvplayer.shared

import androidx.media3.common.PlaybackException
import io.iptvplayer.core.error.NetworkReason
import io.iptvplayer.core.error.PlaybackError
import io.iptvplayer.core.media.Container
import io.iptvplayer.shared.player.ChannelSwitcher
import io.iptvplayer.shared.player.FormatProber
import io.iptvplayer.shared.player.FormatResult
import io.iptvplayer.shared.player.PlaybackErrorMapper
import io.iptvplayer.shared.vm.SourceFormValidation
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class PlayerLogicTest {
    @Test
    fun mapperConstants_matchMedia3() {
        assertEquals(PlaybackException.ERROR_CODE_BEHIND_LIVE_WINDOW, PlaybackErrorMapper.ERROR_CODE_BEHIND_LIVE_WINDOW)
        assertEquals(PlaybackException.ERROR_CODE_IO_BAD_HTTP_STATUS, PlaybackErrorMapper.ERROR_CODE_IO_BAD_HTTP_STATUS)
        assertEquals(PlaybackException.ERROR_CODE_IO_NETWORK_CONNECTION_FAILED, PlaybackErrorMapper.ERROR_CODE_IO_NETWORK_CONNECTION_FAILED)
        assertEquals(PlaybackException.ERROR_CODE_IO_NETWORK_CONNECTION_TIMEOUT, PlaybackErrorMapper.ERROR_CODE_IO_NETWORK_CONNECTION_TIMEOUT)
        assertEquals(PlaybackException.ERROR_CODE_IO_FILE_NOT_FOUND, PlaybackErrorMapper.ERROR_CODE_IO_FILE_NOT_FOUND)
        assertEquals(PlaybackException.ERROR_CODE_PARSING_CONTAINER_UNSUPPORTED, PlaybackErrorMapper.ERROR_CODE_PARSING_CONTAINER_UNSUPPORTED)
        assertEquals(PlaybackException.ERROR_CODE_DECODER_INIT_FAILED, PlaybackErrorMapper.ERROR_CODE_DECODER_INIT_FAILED)
        assertEquals(PlaybackException.ERROR_CODE_DECODING_FORMAT_UNSUPPORTED, PlaybackErrorMapper.ERROR_CODE_DECODING_FORMAT_UNSUPPORTED)
        assertEquals(PlaybackException.ERROR_CODE_DRM_UNSPECIFIED, PlaybackErrorMapper.ERROR_CODE_DRM_UNSPECIFIED)
        assertEquals(PlaybackException.ERROR_CODE_DRM_LICENSE_EXPIRED, PlaybackErrorMapper.ERROR_CODE_DRM_LAST)
    }

    @Test
    fun errorMapping_perScreensTable() {
        val m = PlaybackErrorMapper
        // HTTP statuses (CONTRACT §2): 401/403 → AccessDenied, 404/410 → StreamOffline, 5xx → ServerError (reconnect).
        assertEquals(PlaybackError.AccessDenied(403), m.map(m.ERROR_CODE_IO_BAD_HTTP_STATUS, 403).error)
        assertFalse(m.map(m.ERROR_CODE_IO_BAD_HTTP_STATUS, 401).recoverable)
        assertEquals(PlaybackError.StreamOffline(404), m.map(m.ERROR_CODE_IO_BAD_HTTP_STATUS, 404).error)
        assertEquals(PlaybackError.StreamOffline(410), m.map(m.ERROR_CODE_IO_BAD_HTTP_STATUS, 410).error)
        assertEquals(PlaybackError.ServerError(502), m.map(m.ERROR_CODE_IO_BAD_HTTP_STATUS, 502).error)
        assertTrue(m.map(m.ERROR_CODE_IO_BAD_HTTP_STATUS, 502).recoverable)
        // Network → reconnect; offline is reported as such.
        val net = m.map(m.ERROR_CODE_IO_NETWORK_CONNECTION_FAILED)
        assertTrue(net.recoverable)
        assertEquals(PlaybackError.Network(NetworkReason.OTHER), net.error)
        assertEquals(PlaybackError.Network(NetworkReason.OFFLINE), m.map(m.ERROR_CODE_IO_NETWORK_CONNECTION_FAILED, offline = true).error)
        assertEquals(PlaybackError.Network(NetworkReason.TIMEOUT), m.map(m.ERROR_CODE_IO_NETWORK_CONNECTION_TIMEOUT).error)
        // Behind live window → silent jump to the live edge.
        assertTrue(m.map(m.ERROR_CODE_BEHIND_LIVE_WINDOW).behindLiveWindow)
        // Format / codec / DRM.
        assertEquals(PlaybackError.UnsupportedFormat("mkv"), m.map(m.ERROR_CODE_PARSING_CONTAINER_UNSUPPORTED, container = Container.MKV).error)
        assertEquals(PlaybackError.UnsupportedCodec(), m.map(m.ERROR_CODE_DECODER_INIT_FAILED).error)
        assertEquals(PlaybackError.Drm, m.map(6004).error)
        assertEquals(PlaybackError.Unknown("x"), m.map(7000, message = "x").error)
    }

    @Test
    fun channelSwitch_isDebounced400ms_infoCardImmediate() = runTest(StandardTestDispatcher()) {
        val opened = mutableListOf<Int>()
        val s = ChannelSwitcher<Int>(backgroundScope) { opened += it }
        s.request(1)
        assertEquals(1, s.pending.value)
        advanceTimeBy(200)
        s.request(2)
        advanceTimeBy(300)
        s.request(3)
        assertEquals(3, s.pending.value)
        advanceTimeBy(399)
        runCurrent()
        assertTrue(opened.isEmpty())
        advanceTimeBy(2)
        runCurrent()
        assertEquals(listOf(3), opened)
        assertNull(s.pending.value)
        s.request(4)
        advanceTimeBy(401)
        runCurrent()
        assertEquals(listOf(3, 4), opened)
    }

    @Test
    fun formatTestJudgement() {
        assertEquals(FormatResult.Playing, FormatProber.judge("play", null))
        assertTrue(FormatProber.judge("error:UnsupportedFormat", PlaybackError.UnsupportedFormat("rtmp")) is FormatResult.ExpectedError)
        assertTrue(FormatProber.judge("play", PlaybackError.StreamOffline(404)) is FormatResult.Unexpected)
        assertTrue(FormatProber.judge("error:Drm", null) is FormatResult.Unexpected)
    }

    @Test
    fun formValidation() {
        assertTrue(SourceFormValidation.m3uValid("http://example.com/list.m3u", ""))
        assertFalse(SourceFormValidation.m3uValid("example.com/list.m3u", ""))
        assertFalse(SourceFormValidation.m3uValid("http://a.b/x.m3u", "ftp://x"))
        assertTrue(SourceFormValidation.xtreamValid("host.tld:8080", "u", "p"))
        assertFalse(SourceFormValidation.xtreamValid("host.tld:8080", "", "p"))
    }
}
