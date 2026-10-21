package io.iptvplayer.shared.sync

import io.iptvplayer.core.backend.BackendClient
import io.iptvplayer.core.backend.BackendError
import io.iptvplayer.core.backend.BackendException
import io.iptvplayer.core.sync.SyncItem
import io.iptvplayer.core.sync.SyncMerge
import io.iptvplayer.shared.log.SafeLog
import io.iptvplayer.shared.settings.SettingsRepository
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlin.coroutines.cancellation.CancellationException

/** Local side of the sync (implemented by [io.iptvplayer.shared.repo.LibraryRepository]). */
interface SyncStore {
    suspend fun applyRemote(items: List<SyncItem>): Int
    suspend fun pendingPush(limit: Int): List<SyncItem>
    suspend fun markPushed(items: List<SyncItem>)
}

data class SyncStatus(val running: Boolean = false, val lastSyncMs: Long? = null, val error: BackendError? = null)

/**
 * Favorites/progress sync (ARCHITECTURE §6, CONTRACT §8): pull on start / foreground
 * (`GET /v1/sync?since=cursor`, pages of 500 until `hasMore == false`, LWW merge), push of local
 * changes debounced by 5 s in chunks of ≤ 500 items. Runs only with a session.
 */
class SyncManager(
    private val backend: BackendClient?,
    private val store: SyncStore,
    private val settings: SettingsRepository,
    private val sessionToken: () -> String?,
    private val scope: CoroutineScope,
    private val onUnauthorized: suspend () -> Unit = {},
    private val debounceMs: Long = 5_000,
    private val nowMs: () -> Long = System::currentTimeMillis,
) {
    private val _status = MutableStateFlow(SyncStatus())
    val status: StateFlow<SyncStatus> = _status
    private val mutex = Mutex()
    private var pushJob: Job? = null

    /** Observes local changes and schedules debounced pushes. */
    fun observe(changes: Flow<Unit>) {
        scope.launch {
            _status.update { it.copy(lastSyncMs = settings.syncCache().lastSyncMs) }
            changes.collect { schedulePush() }
        }
    }

    fun schedulePush() {
        if (sessionToken() == null) return
        pushJob?.cancel()
        pushJob = scope.launch {
            delay(debounceMs)
            push()
        }
    }

    /** Full sync: pull, then push. */
    suspend fun syncNow(): BackendError? = mutex.withLock {
        val token = sessionToken() ?: return@withLock null
        val client = backend ?: return@withLock null
        _status.update { it.copy(running = true) }
        try {
            var cache = settings.syncCache()
            var cursor = cache.cursor
            do {
                val page = client.syncPull(token, cursor, SyncMerge.MAX_ITEMS_PER_REQUEST)
                store.applyRemote(page.items)
                cursor = page.cursor
            } while (page.hasMore)
            cache = cache.copy(cursor = cursor)
            settings.saveSync(cache)
            pushLocked(client, token)
            val now = nowMs()
            settings.saveSync(settings.syncCache().copy(lastSyncMs = now))
            _status.update { it.copy(running = false, lastSyncMs = now, error = null) }
            null
        } catch (e: CancellationException) {
            throw e
        } catch (e: BackendException) {
            fail(e.error)
        }
    }

    /** Uploads pending local changes. */
    suspend fun push(): BackendError? = mutex.withLock {
        val token = sessionToken() ?: return@withLock null
        val client = backend ?: return@withLock null
        try {
            pushLocked(client, token)
            null
        } catch (e: CancellationException) {
            throw e
        } catch (e: BackendException) {
            fail(e.error)
        }
    }

    /** Pushes all dirty items in server-sized chunks; returns the number of requests made. */
    private suspend fun pushLocked(client: BackendClient, token: String): Int {
        var requests = 0
        while (true) {
            val batch = store.pendingPush(SyncMerge.MAX_ITEMS_PER_REQUEST)
            if (batch.isEmpty()) break
            val r = client.syncPush(token, batch)
            store.markPushed(batch)
            requests++
            val c = settings.syncCache()
            // The push cursor is not adopted: items of other devices between the cursors would be skipped.
            settings.saveSync(c.copy(lastPushMs = nowMs()))
            SafeLog.d(TAG, "pushed ${batch.size}, applied ${r.applied}")
            if (batch.size < SyncMerge.MAX_ITEMS_PER_REQUEST) break
        }
        return requests
    }

    private suspend fun fail(error: BackendError): BackendError {
        SafeLog.w(TAG, "sync failed: ${error.code}")
        _status.update { it.copy(running = false, error = error) }
        if (error is BackendError.Unauthorized) onUnauthorized()
        return error
    }

    /** Clears the cursor (sign-out / account switch). */
    suspend fun reset() {
        settings.saveSync(io.iptvplayer.shared.settings.SyncCache(0, 0, null))
        _status.value = SyncStatus()
    }

    companion object {
        private const val TAG = "Sync"
    }
}
