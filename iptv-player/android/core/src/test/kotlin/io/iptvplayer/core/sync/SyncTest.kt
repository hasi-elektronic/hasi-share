package io.iptvplayer.core.sync

import io.iptvplayer.core.CoreJson
import io.iptvplayer.core.Vectors
import io.iptvplayer.core.model.ContentKind
import io.iptvplayer.core.util.ContentKeys
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/** CONTRACT §8 (LWW merge, key format, home-screen selections). */
class SyncTest {
    private val ck = "d11e55fa87364ff0:movie:5001"

    @Test
    fun keysUseContentKeysFromVectors() {
        // Sync keys are built on the shared content keys (content-keys.json).
        val cases = Vectors.json("content-keys.json").jsonObject.getValue("cases").jsonArray
        for (c in cases.map { it.jsonObject }) {
            val key = c.getValue("contentKey").jsonPrimitive.content
            val fav = SyncItem.favorite(key, "t", ContentKind.MOVIE, null, 1)
            assertEquals("fav:$key", fav.key)
            assertEquals(key, fav.contentKey)
            assertTrue(fav.isWellFormed)
            assertEquals(key, ContentKeys.parse(fav.contentKey)!!.let { "${it.fingerprint}:${it.kind.wire}:${it.itemId}" })
            assertEquals("prog:$key", SyncItem.progressKey(key))
        }
    }

    @Test
    fun lwwMergeTiesKeepStored() {
        val stored = SyncItem.favorite(ck, "A", ContentKind.MOVIE, null, updatedAt = 100)
        val older = stored.copy(data = stored.data.copy(title = "old"), updatedAt = 99)
        val tie = stored.copy(data = stored.data.copy(title = "tie"), updatedAt = 100)
        val newer = stored.copy(deleted = true, updatedAt = 101)
        assertFalse(SyncMerge.shouldApply(older, stored))
        assertFalse(SyncMerge.shouldApply(tie, stored))
        assertTrue(SyncMerge.shouldApply(newer, stored))
        assertTrue(SyncMerge.shouldApply(older, null))

        val other = SyncItem.progress("x:live:1", "Live", ContentKind.LIVE, 5_000, 0, updatedAt = 5)
        val r = SyncMerge.merge(mapOf(stored.key to stored), listOf(older, tie, other, newer))
        assertEquals(listOf(other, newer), r.applied)
        assertEquals(newer, r.merged[stored.key])
        assertEquals(0L, r.merged.getValue(other.key).data.positionMs, "live progress stores position 0")
        // Order independence for distinct timestamps: newest wins either way.
        val r2 = SyncMerge.merge(emptyMap(), listOf(newer, older))
        assertEquals(newer, r2.merged[stored.key])
    }

    @Test
    fun pendingAndChunks() {
        val items = (1..1200L).map { SyncItem.favorite("$ck$it", "t", ContentKind.MOVIE, null, updatedAt = it) }
        val pending = SyncMerge.pending(items.shuffled(), lastPushMs = 200)
        assertEquals(1000, pending.size)
        assertEquals(201L, pending.first().updatedAt)
        assertEquals(listOf(500, 500), SyncMerge.chunks(pending).map { it.size })
    }

    @Test
    fun wireFormat() {
        val p = SyncItem.progress(ck, "Inception", ContentKind.MOVIE, 60_000, 600_000, updatedAt = 1_759_570_000_123, posterUrl = "http://p")
        val json = p.copy(seq = 7).toWireJson().toString()
        assertEquals(
            """{"key":"prog:$ck","kind":"progress","data":{"title":"Inception","contentKind":"movie","posterUrl":"http://p","positionMs":60000,"durationMs":600000},"updatedAt":1759570000123,"deleted":false}""",
            json,
        )
        // Server items (with seq, unknown fields) decode.
        val fromServer = CoreJson.decodeFromString(
            SyncItem.serializer(),
            """{"key":"fav:$ck","kind":"favorite","data":{"title":"X","contentKind":"series","extra":1},"updatedAt":5,"deleted":true,"seq":42}""",
        )
        assertEquals(42L, fromServer.seq)
        assertEquals(ContentKind.SERIES, fromServer.data.contentKind)
        assertTrue(fromServer.deleted)
    }

    @Test
    fun continueAndRecentlyWatched() {
        fun prog(id: Int, pos: Long, dur: Long, at: Long, kind: ContentKind = ContentKind.MOVIE, deleted: Boolean = false) =
            SyncItem.progress("fp:${kind.wire}:$id", "t$id", kind, pos, dur, updatedAt = at).copy(deleted = deleted)
        val items = listOf(
            prog(1, 50, 1000, 1), // exactly 5 % → not started enough
            prog(2, 51, 1000, 2), // > 5 %
            prog(3, 949, 1000, 3), // < 95 %
            prog(4, 950, 1000, 4), // completed
            prog(5, 500, 0, 5), // no duration
            prog(6, 500, 1000, 6, deleted = true),
            prog(7, 0, 0, 7, ContentKind.LIVE),
            SyncItem.favorite("fp:movie:8", "fav", ContentKind.MOVIE, null, 8),
        )
        assertEquals(listOf("t3", "t2"), WatchHistory.continueWatching(items).map { it.data.title })
        assertEquals(listOf("t3"), WatchHistory.continueWatching(items, limit = 1).map { it.data.title })
        assertEquals(listOf("t7", "t5", "t4", "t3", "t2", "t1"), WatchHistory.recentlyWatched(items).map { it.data.title })
        assertEquals(listOf("t7"), WatchHistory.recentlyWatched(items, kind = ContentKind.LIVE).map { it.data.title })
        assertTrue(WatchHistory.isCompleted(950, 1000))
        assertFalse(WatchHistory.isCompleted(949, 1000))
        assertFalse(WatchHistory.isCompleted(10, 0))
        val many = (1..80).map { prog(it, 1, 2, it.toLong()) }
        assertEquals(50, WatchHistory.recentlyWatched(many).size)
    }
}
