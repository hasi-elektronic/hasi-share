package io.iptvplayer.shared

import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import io.iptvplayer.core.error.SourceError
import io.iptvplayer.core.model.ContentKind
import io.iptvplayer.core.model.SourceSecrets
import io.iptvplayer.core.net.SourceHttp
import io.iptvplayer.core.retry.SourceRetryPolicy
import io.iptvplayer.core.util.Redactor
import io.iptvplayer.shared.db.AppDatabase
import io.iptvplayer.shared.repo.CatalogRepository
import io.iptvplayer.shared.repo.LibraryRepository
import io.iptvplayer.shared.repo.RefreshOutcome
import io.iptvplayer.shared.repo.RefreshProgress
import io.iptvplayer.shared.repo.SourceRepository
import io.iptvplayer.shared.secure.InMemorySecretStore
import io.iptvplayer.shared.secure.SecretKeys
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import okhttp3.OkHttpClient
import okhttp3.mockwebserver.Dispatcher
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okhttp3.mockwebserver.RecordedRequest
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.kxml2.io.KXmlParser
import org.robolectric.annotation.Config

/**
 * Room (in-memory, Robolectric) + repositories: add with batched writes, atomic refresh
 * (old catalog stays visible on failure, old generation purged on success), FTS search,
 * EPG import with channel matching, library LWW merge.
 */
@RunWith(AndroidJUnit4::class)
@Config(sdk = [34])
class RepositoryTest {
    private val server = MockWebServer()
    private lateinit var db: AppDatabase
    private lateinit var repo: SourceRepository
    private lateinit var catalog: CatalogRepository
    private val secrets = InMemorySecretStore()
    private var playlist = PLAYLIST_1
    private var playlistStatus = 200
    private val now = 1_759_570_000_000L

    @Before
    fun setUp() {
        server.dispatcher = object : Dispatcher() {
            override fun dispatch(request: RecordedRequest): MockResponse = when (request.requestUrl!!.encodedPath) {
                "/list.m3u" -> MockResponse().setResponseCode(playlistStatus).setBody(if (playlistStatus == 200) playlist else "")
                "/epg.xml" -> MockResponse().setBody(epg())
                else -> MockResponse().setResponseCode(404)
            }
        }
        server.start()
        db = AppDatabase.inMemory(ApplicationProvider.getApplicationContext())
        val http = SourceHttp(OkHttpClient(), retryPolicy = SourceRetryPolicy.NONE, dispatcher = Dispatchers.IO)
        repo = SourceRepository(db, secrets, http, { KXmlParser() }, Redactor(), nowMs = { now }, batchSize = 2)
        catalog = CatalogRepository(db, repo)
    }

    @After
    fun tearDown() {
        db.close()
        server.shutdown()
    }

    private fun url(p: String) = server.url(p).toString()

    @Test
    fun addRefreshAndAtomicSwap() = runBlocking {
        val progress = mutableListOf<RefreshProgress>()
        val r = repo.add("Test", SourceSecrets.M3u(url("/list.m3u")), onProgress = { progress += it })
        assertTrue(r is RefreshOutcome.Success)
        val src = (r as RefreshOutcome.Success).source
        assertEquals(3, r.status.liveCount)
        assertEquals(1, r.status.movieCount)
        assertEquals(1, r.status.seriesCount)
        assertTrue(progress.first() == RefreshProgress.Connecting)
        assertTrue(progress.any { it is RefreshProgress.Channels })
        // Secrets only in the secret store; the DB row has none.
        assertNotNull(secrets.get(SecretKeys.source(src.id)))
        assertEquals(server.hostName, src.displayHost)
        assertEquals(3, catalog.channelList(src.id, null).size)
        assertEquals(listOf("News"), catalog.categories(src.id, ContentKind.LIVE).first().filter { it.name == "News" }.map { it.name })

        // FTS prefix search.
        assertEquals(listOf("Sport HD"), catalog.search(src.id, "spo").channels.map { it.name })
        assertTrue(catalog.search(src.id, "zzz").isEmpty)

        // Failed refresh: old catalog stays, failure recorded.
        playlistStatus = 404
        val failed = repo.refresh(src.id)
        assertEquals(RefreshOutcome.Failure(SourceError.NotFound), failed)
        assertEquals(3, catalog.channelList(src.id, null).size)
        assertFalse(repo.get(src.id)!!.lastRefreshResult!!.ok)

        // Successful refresh: new generation replaces the old one completely.
        playlistStatus = 200
        playlist = PLAYLIST_2
        val ok = repo.refresh(src.id)
        assertTrue(ok is RefreshOutcome.Success)
        assertEquals(listOf("Kids"), catalog.channelList(src.id, null).map { it.name })
        assertEquals(1, db.catalog().channelCount(src.id))
        val allRows = db.query("SELECT COUNT(*) FROM channels", null).use { it.moveToFirst(); it.getInt(0) }
        assertEquals(1, allRows)
        assertEquals(2, repo.get(src.id).let { db.sources().get(src.id)!!.activeGen })
    }

    @Test
    fun invalidPlaylist_isNotStored() = runBlocking {
        playlist = "<html>nope</html>"
        val r = repo.add("Bad", SourceSecrets.M3u(url("/list.m3u")))
        assertEquals(RefreshOutcome.Failure(SourceError.InvalidFormat), r)
        assertTrue(repo.all().isEmpty())
        assertTrue(secrets.keys().isEmpty())
        val rows = db.query("SELECT COUNT(*) FROM channels", null).use { it.moveToFirst(); it.getInt(0) }
        assertEquals(0, rows)
    }

    @Test
    fun epgImport_matchesChannelsAndNowNext() = runBlocking {
        val r = repo.add("Test", SourceSecrets.M3u(url("/list.m3u"), epgUrl = url("/epg.xml"))) as RefreshOutcome.Success
        assertNull(repo.importEpg(r.source.id))
        val rows = catalog.channelRows(r.source.id, null, now)
        val news = rows.first { it.channel.name == "News One" }
        assertEquals("news.one", news.channel.epgKey)
        assertEquals("Morning News", news.nowTitle)
        assertEquals("Weather", news.nextTitle)
        val sport = rows.first { it.channel.name == "Sport HD" }
        assertEquals("sport", sport.channel.epgKey) // matched by normalized name
        assertEquals(2, r.source.let { db.sources().get(it.id)!!.epgGen }.let { it + 1 })
    }

    @Test
    fun library_favoritesProgressAndLww() = runBlocking {
        val lib = LibraryRepository(db, nowMs = { now })
        lib.setFavorite("fp:live:1", "Ch 1", ContentKind.LIVE, null, true)
        assertTrue(lib.isFavorite("fp:live:1"))
        assertEquals(1, lib.pendingPush(10).size)
        lib.markPushed(lib.pendingPush(10))
        assertEquals(0, lib.pendingCount())
        // Older remote tombstone loses, newer wins.
        val older = io.iptvplayer.core.sync.SyncItem.favorite("fp:live:1", "Ch 1", ContentKind.LIVE, null, now - 1, deleted = true)
        assertEquals(0, lib.applyRemote(listOf(older)))
        assertTrue(lib.isFavorite("fp:live:1"))
        val newer = older.copy(updatedAt = now + 1)
        assertEquals(1, lib.applyRemote(listOf(newer)))
        assertFalse(lib.isFavorite("fp:live:1"))
        assertEquals(0, lib.pendingCount()) // remote items are not re-pushed

        lib.saveProgress("fp:movie:9", "Film", ContentKind.MOVIE, 30_000, 100_000)
        assertEquals(listOf("fp:movie:9"), lib.continueWatching.first().map { it.contentKey })
        lib.saveProgress("fp:movie:9", "Film", ContentKind.MOVIE, 99_000, 100_000)
        assertTrue(lib.continueWatching.first().isEmpty())
    }

    private fun epg(): String {
        fun t(ms: Long) = java.time.format.DateTimeFormatter.ofPattern("yyyyMMddHHmmss Z").withZone(java.time.ZoneOffset.UTC).format(java.time.Instant.ofEpochMilli(ms))
        val h = 3_600_000L
        return """<?xml version="1.0" encoding="UTF-8"?>
<tv>
  <channel id="news.one"><display-name>News One</display-name></channel>
  <channel id="sport"><display-name>Sport</display-name></channel>
  <channel id="unrelated"><display-name>Other</display-name></channel>
  <programme start="${t(now - h)}" stop="${t(now + h)}" channel="news.one"><title>Morning News</title></programme>
  <programme start="${t(now + h)}" stop="${t(now + 2 * h)}" channel="news.one"><title>Weather</title></programme>
  <programme start="${t(now - h)}" stop="${t(now + h)}" channel="sport"><title>Match</title></programme>
  <programme start="${t(now - h)}" stop="${t(now + h)}" channel="unrelated"><title>Skip me</title></programme>
</tv>"""
    }

    companion object {
        val PLAYLIST_1 = """#EXTM3U
#EXTINF:-1 tvg-id="news.one" tvg-chno="1" group-title="News",News One
http://stream.example/news.ts
#EXTINF:-1 tvg-chno="2" group-title="Sport",Sport HD
http://stream.example/sport.m3u8
#EXTINF:-1 group-title="Music",Music Box
http://stream.example/music.ts
#EXTINF:-1 group-title="Movies",Big Film (2020)
http://vod.example/movie/film.mp4
#EXTINF:-1 group-title="Shows",My Show S01E02
http://vod.example/series/show-s1e2.mkv
"""
        val PLAYLIST_2 = """#EXTM3U
#EXTINF:-1 group-title="Kids",Kids
http://stream.example/kids.ts
"""
    }
}
