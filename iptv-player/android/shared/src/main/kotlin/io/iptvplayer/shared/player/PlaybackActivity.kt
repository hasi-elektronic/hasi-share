package io.iptvplayer.shared.player

import java.util.concurrent.atomic.AtomicInteger

/**
 * Process-wide "a stream is open" flag (CONTRACT §6.2 / ARCHITECTURE §3.1 5a, Apple `waitUntilPlayerClosed`):
 * automatic catalog / EPG downloads must not compete with a playing stream on the same panel – most IPTV accounts
 * allow one connection, and a refresh mid-stream froze or dropped channels. [PlayerController] marks its ExoPlayer
 * here; [io.iptvplayer.shared.work.RefreshWorker] defers while it is set.
 */
object PlaybackActivity {
    private val open = AtomicInteger(0)

    val isActive: Boolean get() = open.get() > 0

    fun opened() { open.incrementAndGet() }

    fun closed() { open.updateAndGet { if (it > 0) it - 1 else 0 } }
}
