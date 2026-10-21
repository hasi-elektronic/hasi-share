package io.iptvplayer.shared.player

import android.content.Context
import androidx.annotation.OptIn
import androidx.media3.common.MediaItem
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.common.util.UnstableApi
import androidx.media3.datasource.HttpDataSource
import androidx.media3.datasource.okhttp.OkHttpDataSource
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.source.DefaultMediaSourceFactory
import io.iptvplayer.core.CoreJson
import io.iptvplayer.core.error.PlaybackError
import io.iptvplayer.core.media.Container
import io.iptvplayer.core.media.PlatformSupport
import io.iptvplayer.core.media.PlayerEngine
import io.iptvplayer.core.media.StreamFormatDetector
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import okhttp3.OkHttpClient
import kotlin.coroutines.resume

/** One entry of `spec/test-vectors/stream-samples.json` (bundled asset). */
data class StreamSample(val id: String, val name: String, val url: String, val container: String, val expect: String)

sealed interface FormatResult {
    data object Pending : FormatResult
    data object Running : FormatResult
    data object Playing : FormatResult
    data class ExpectedError(val code: String) : FormatResult
    data class Unexpected(val detail: String) : FormatResult
    data object Skipped : FormatResult
}

/**
 * Diagnostics "Format test" (STREAM_COMPATIBILITY §3.2): pre-checks the container like the real
 * player, then prepares a headless ExoPlayer and waits for READY (or an error) – 20 s timeout.
 */
@OptIn(UnstableApi::class)
class FormatProber(private val context: Context, private val okHttp: OkHttpClient) {

    fun parse(json: String): List<StreamSample> =
        CoreJson.parseToJsonElement(json).jsonObject["samples"]!!.jsonArray.mapNotNull { e ->
            val o = e as? JsonObject ?: return@mapNotNull null
            fun s(k: String) = o[k]?.jsonPrimitive?.contentOrNull
            StreamSample(
                id = s("id") ?: return@mapNotNull null,
                name = s("name") ?: "",
                url = s("url") ?: return@mapNotNull null,
                container = s("container") ?: "unknown",
                expect = (o["expect"] as? JsonObject)?.get("media3")?.jsonPrimitive?.contentOrNull ?: "play",
            )
        }

    /** [lanHost] replaces `<LAN-IP>` in local samples (null → those are skipped). */
    suspend fun probe(sample: StreamSample, lanHost: String?): FormatResult {
        val url = if (sample.url.contains("<LAN-IP>")) lanHost?.let { sample.url.replace("<LAN-IP>", it) } ?: return FormatResult.Skipped else sample.url
        val container = StreamFormatDetector.detect(url).takeIf { it != Container.UNKNOWN } ?: Container.fromWire(sample.container)
        val pre = PlatformSupport.check(container, PlayerEngine.MEDIA3)
        val outcome: PlaybackError? = pre ?: withContext(Dispatchers.Main) { playOnce(url) }
        return judge(sample.expect, outcome)
    }

    private suspend fun playOnce(url: String): PlaybackError? {
        val player = ExoPlayer.Builder(context)
            .setMediaSourceFactory(DefaultMediaSourceFactory(OkHttpDataSource.Factory(okHttp)))
            .build()
        return try {
            withTimeoutOrNull(20_000) {
                suspendCancellableCoroutine<Outcome> { cont ->
                    player.addListener(object : Player.Listener {
                        override fun onPlaybackStateChanged(state: Int) {
                            if (state == Player.STATE_READY && cont.isActive) cont.resume(Outcome(null))
                        }

                        override fun onPlayerError(error: PlaybackException) {
                            val http = generateSequence<Throwable>(error) { it.cause }.filterIsInstance<HttpDataSource.InvalidResponseCodeException>().firstOrNull()?.responseCode
                            if (cont.isActive) cont.resume(Outcome(PlaybackErrorMapper.map(error.errorCode, http).error))
                        }
                    })
                    player.volume = 0f
                    player.setMediaItem(MediaItem.fromUri(url))
                    player.prepare()
                }
            }?.error ?: if (timedOut(player)) PlaybackError.Network(io.iptvplayer.core.error.NetworkReason.TIMEOUT) else null
        } finally {
            player.release()
        }
    }

    private class Outcome(val error: PlaybackError?)

    private fun timedOut(p: ExoPlayer) = p.playbackState != Player.STATE_READY

    companion object {
        /** Compares the outcome with the `expect.media3` value (`play` or `error:<Kind>`). */
        fun judge(expect: String, outcome: PlaybackError?): FormatResult {
            val kind = outcome?.let { it::class.simpleName } ?: "play"
            return when {
                expect == "play" && outcome == null -> FormatResult.Playing
                expect.startsWith("error:") && outcome != null && expect.removePrefix("error:") == kind -> FormatResult.ExpectedError(outcome.code)
                outcome == null -> FormatResult.Unexpected("playing (expected $expect)")
                else -> FormatResult.Unexpected(outcome.code)
            }
        }
    }
}
