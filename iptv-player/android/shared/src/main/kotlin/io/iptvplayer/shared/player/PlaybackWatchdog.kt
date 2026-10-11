package io.iptvplayer.shared.player

/** Pure rules of the player's watchdogs (unit-tested; [PlayerController] applies them). */
object PlaybackWatchdog {
    /** Same as Apple's stall timer (CONTRACT §2). */
    const val STALL_TIMEOUT_MS: Long = 12_000L

    /** Still buffering, the whole timeout passed and the position did not move (≤ 0.5 s). */
    fun stalled(stillBuffering: Boolean, sinceMs: Long, nowMs: Long, positionAtStartMs: Long, positionNowMs: Long): Boolean =
        stillBuffering && nowMs - sinceMs >= STALL_TIMEOUT_MS && positionNowMs - positionAtStartMs <= 500

    /** Startup: time until a decoder that never outputs a frame is called stuck. */
    const val DECODE_CHECK_MS: Long = 10_000L

    /** Startup: not playing at all after this long → network timeout (rescue / reconnect / card). */
    const val STARTUP_TIMEOUT_MS: Long = 20_000L

    /** Video selected, no frame rendered, yet ≥ 3 s of media buffered → decoding, not the network, is the problem. */
    fun decoderStuck(hasVideoFormat: Boolean, firstFrameRendered: Boolean, bufferedAheadMs: Long): Boolean =
        hasVideoFormat && !firstFrameRendered && bufferedAheadMs >= 3_000

    /** The stream has video, but none of its video tracks can be decoded on this device. */
    fun videoUndecodable(hasVideo: Boolean, videoSupported: Boolean): Boolean = hasVideo && !videoSupported
}
