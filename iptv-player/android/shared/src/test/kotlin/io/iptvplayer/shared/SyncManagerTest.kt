package io.iptvplayer.shared

import io.iptvplayer.core.backend.BackendClient
import io.iptvplayer.core.model.ContentKind
import io.iptvplayer.core.sync.SyncItem
import io.iptvplayer.shared.settings.InMemorySettings
import io.iptvplayer.shared.sync.SyncManager
import io.iptvplayer.shared.sync.SyncStore
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import okhttp3.OkHttpClient
import okhttp3.mockwebserver.Dispatcher
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okhttp3.mockwebserver.RecordedRequest
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Before
import org.junit.Test

/** SyncManager: paged pull with LWW apply, chunked push (≤ 500), 5 s debounce (CONTRACT §8). */
@OptIn(ExperimentalCoroutinesApi::class)
class SyncManagerTest {
    private val server = MockWebServer()
    private val pushSizes = mutableListOf<Int>()
    private val pulls = mutableListOf<String>()

    private class FakeStore(var pending: MutableList<SyncItem>) : SyncStore {
        val applied = mutableListOf<SyncItem>()
        override suspend fun applyRemote(items: List<SyncItem>): Int { applied += items; return items.size }
        override suspend fun pendingPush(limit: Int): List<SyncItem> = pending.take(limit)
        override suspend fun markPushed(items: List<SyncItem>) { pending.removeAll(items.toSet()) }
    }

    private fun item(i: Int, t: Long = 1000L + i) = SyncItem.favorite("fp:live:$i", "Ch $i", ContentKind.LIVE, null, t)

    @Before
    fun setUp() {
        server.dispatcher = object : Dispatcher() {
            override fun dispatch(request: RecordedRequest): MockResponse {
                if (request.method == "POST") {
                    val body = request.body.readUtf8()
                    pushSizes += Regex("\"key\"").findAll(body).count()
                    return MockResponse().setBody("""{"applied":1,"cursor":999}""")
                }
                pulls += request.path!!
                val since = request.requestUrl!!.queryParameter("since")!!.toLong()
                val (items, cursor, more) = if (since == 0L) Triple("""[{"key":"fav:fp:live:1","kind":"favorite","data":{"title":"A","contentKind":"live"},"updatedAt":5,"deleted":false,"seq":1}]""", 1, true)
                else Triple("""[{"key":"prog:fp:movie:9","kind":"progress","data":{"title":"M","contentKind":"movie","positionMs":10,"durationMs":100},"updatedAt":6,"deleted":false,"seq":2},{"bad":true}]""", 2, false)
                return MockResponse().setBody("""{"items":$items,"cursor":$cursor,"hasMore":$more}""")
            }
        }
        server.start()
    }

    @After
    fun tearDown() = server.shutdown()

    private fun backend() = BackendClient(server.url("/").toString(), OkHttpClient(), dispatcher = Dispatchers.Unconfined)

    @Test
    fun syncNow_pullsAllPages_thenPushesInChunksOf500() = runTest(StandardTestDispatcher()) {
        val store = FakeStore((1..1200).map { item(it) }.toMutableList())
        val settings = InMemorySettings()
        val m = SyncManager(backend(), store, settings, { "session" }, backgroundScope, nowMs = { 42L })
        m.syncNow()
        assertEquals(2, pulls.size)
        assertEquals(2, store.applied.size) // malformed item skipped
        assertEquals(2L, settings.syncCache().cursor)
        assertEquals(listOf(500, 500, 200), pushSizes)
        assertEquals(0, store.pending.size)
        assertEquals(42L, m.status.value.lastSyncMs)
    }

    @Test
    fun localChanges_areDebouncedInto_onePush() = runTest(StandardTestDispatcher()) {
        val store = FakeStore(mutableListOf(item(1), item(2)))
        val changes = MutableSharedFlow<Unit>(extraBufferCapacity = 8)
        val m = SyncManager(backend(), store, InMemorySettings(), { "session" }, backgroundScope, debounceMs = 5_000)
        m.observe(changes)
        runCurrent()
        repeat(5) {
            changes.emit(Unit)
            advanceTimeBy(1_000)
        }
        assertEquals(0, pushSizes.size)
        advanceTimeBy(5_001)
        runCurrent()
        assertEquals(listOf(2), pushSizes)
    }

    @Test
    fun withoutSession_nothingHappens() = runTest(StandardTestDispatcher()) {
        val store = FakeStore(mutableListOf(item(1)))
        val m = SyncManager(backend(), store, InMemorySettings(), { null }, backgroundScope)
        m.syncNow()
        assertEquals(0, pulls.size + pushSizes.size)
    }
}
