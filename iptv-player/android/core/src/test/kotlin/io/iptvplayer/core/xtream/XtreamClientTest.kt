package io.iptvplayer.core.xtream

import io.iptvplayer.core.Vectors
import io.iptvplayer.core.error.SourceError
import io.iptvplayer.core.error.SourceException
import io.iptvplayer.core.model.Channel
import io.iptvplayer.core.model.SourceSecrets
import io.iptvplayer.core.net.MockServerSupport
import io.iptvplayer.core.util.ContentKeys
import kotlinx.coroutines.runBlocking
import okhttp3.mockwebserver.Dispatcher
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okhttp3.mockwebserver.RecordedRequest
import org.junit.jupiter.api.AfterEach
import org.junit.jupiter.api.BeforeEach
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertTrue

/** XtreamClient end-to-end over MockWebServer with the shared vectors as panel responses. */
class XtreamClientTest {
    private lateinit var server: MockWebServer
    private val nowMs = 1_759_570_000_000L
    private val overrides = HashMap<String, MockResponse>()
    private val password = "p@ss/w rd"

    private fun file(name: String) = MockResponse().setBody(Vectors.text("xtream/$name")).addHeader("Content-Type", "application/json")

    @BeforeEach
    fun start() {
        server = MockWebServer()
        server.dispatcher = object : Dispatcher() {
            override fun dispatch(request: RecordedRequest): MockResponse {
                val url = request.requestUrl!!
                if (url.encodedPath != "/c/player_api.php") return MockResponse().setResponseCode(404)
                if (url.queryParameter("username") != "user1" || url.queryParameter("password") != password) {
                    return MockResponse().setResponseCode(401)
                }
                val action = url.queryParameter("action") ?: "account"
                overrides[action]?.let { return it }
                return when (action) {
                    "account" -> file("auth_ok.json")
                    "get_live_categories" -> file("live_categories.json")
                    "get_vod_categories", "get_series_categories" -> MockResponse().setBody("[]")
                    "get_live_streams" -> file("live_streams.json")
                    "get_vod_streams" -> file("vod_streams.json")
                    "get_series" -> file("series.json")
                    "get_series_info" -> file(if (url.queryParameter("series_id") == "8000") "series_info_list_variant.json" else "series_info.json")
                    "get_short_epg" -> file("short_epg.json")
                    else -> MockResponse().setResponseCode(404)
                }
            }
        }
        server.start()
    }

    @AfterEach
    fun stop() = server.shutdown()

    private fun client(user: String = "user1", pass: String = password): XtreamClient {
        val secrets = SourceSecrets.Xtream(server.url("/c/").toString(), user, pass)
        return XtreamClient(MockServerSupport.RecordingHttp().http, "src1", secrets, nowMs = { nowMs })
    }

    @Test
    fun fullCatalog(): Unit = runBlocking {
        val c = client()
        val catalog = c.fetchCatalog()
        assertEquals("Europe/Istanbul", catalog.account.serverTimezone)
        assertEquals(listOf("1", "2"), catalog.liveCategories.map { it.id })
        assertEquals(listOf("1001", "1002", "2001"), catalog.channels.map { it.id })
        assertEquals(listOf("5001", "5002"), catalog.movies.map { it.id })
        assertEquals(listOf("7000", "7100", "7200"), catalog.series.map { it.id })
        assertEquals(3, catalog.status.liveCount)
        // Credentials percent-encoded with the unreserved-only rule (space → %20, never '+').
        val first = server.takeRequest()
        assertTrue(first.path!!.contains("password=p%40ss%2Fw%20rd"), first.path)
        assertEquals(ContentKeys.xtreamFingerprint(server.hostName, "user1"), c.fingerprint)
    }

    @Test
    fun detailsAndShortEpg(): Unit = runBlocking {
        val c = client()
        assertEquals(3, c.seriesInfo("7000").episodes.size)
        assertEquals(listOf(1, 2), c.seriesInfo("8000").episodes.map { it.season })
        val epg = c.shortEpg("1001", limit = 2)
        assertEquals(listOf("Akşam Haberleri", "Dizi"), epg.map { it.title })
        val req = generateSequence { server.takeRequest(0, java.util.concurrent.TimeUnit.MILLISECONDS) }.last()
        assertTrue(req.path!!.endsWith("&action=get_short_epg&stream_id=1001&limit=2"), req.path)
    }

    @Test
    fun streamedBatchesKeepOrderAndSort(): Unit = runBlocking {
        val batches = ArrayList<List<Channel>>()
        val count = client().liveStreams(batchSize = 2) { batches += it }
        assertEquals(3, count)
        assertEquals(listOf(2, 1), batches.map { it.size })
        assertEquals(listOf(0, 1, 2), batches.flatten().map { it.sort })
    }

    @Test
    fun accountErrorsAreClassified(): Unit = runBlocking {
        assertEquals(SourceError.InvalidCredentials, assertFailsWith<SourceException> { client(pass = "wrong").authenticate() }.error)
        overrides["account"] = file("auth_expired_by_date.json")
        assertEquals(SourceError.AccountExpired(1_600_000_000_000), assertFailsWith<SourceException> { client().fetchCatalog() }.error)
        overrides["account"] = file("auth_banned.json")
        assertEquals(SourceError.AccountDisabled, assertFailsWith<SourceException> { client().authenticate() }.error)
        overrides["account"] = file("auth_html.txt")
        assertEquals(SourceError.InvalidResponse, assertFailsWith<SourceException> { client().authenticate() }.error)
    }

    @Test
    fun objectShapedAndEmptyLists(): Unit = runBlocking {
        overrides["get_live_streams"] = MockResponse().setBody("""{"1":{"stream_id":2,"name":"B"},"0":{"stream_id":1,"name":"A"}}""")
        assertEquals(listOf("A", "B"), client().liveStreams().map { it.name })
        overrides["get_live_streams"] = MockResponse().setBody("")
        assertEquals(emptyList(), client().liveStreams())
        overrides["get_live_streams"] = MockResponse().setBody("null")
        assertEquals(emptyList(), client().liveStreams())
        overrides["get_live_streams"] = MockResponse().setBody("﻿ [ {\"stream_id\": 9, \"name\": \"bom\"} ] ")
        assertEquals(listOf("9"), client().liveStreams().map { it.id })
        overrides["get_live_streams"] = MockResponse().setBody("""[{"stream_id":1,"name":"A"}, {"stream_id":""" ) // truncated
        assertEquals(SourceError.InvalidResponse, assertFailsWith<SourceException> { client().liveStreams() }.error)
    }

    @Test
    fun emptyCatalogIsEmptyError(): Unit = runBlocking {
        for (a in listOf("get_live_streams", "get_vod_streams", "get_series")) overrides[a] = MockResponse().setBody("[]")
        assertEquals(SourceError.Empty, assertFailsWith<SourceException> { client().fetchCatalog() }.error)
    }
}
