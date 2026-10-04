package io.iptvplayer.core.net

import io.iptvplayer.core.Vectors
import io.iptvplayer.core.error.NetworkReason
import io.iptvplayer.core.error.SourceError
import io.iptvplayer.core.error.SourceException
import io.iptvplayer.core.m3u.M3uClient
import io.iptvplayer.core.m3u.M3uEntry
import io.iptvplayer.core.model.SourceSecrets
import io.iptvplayer.core.net.MockServerSupport.RecordingHttp
import io.iptvplayer.core.xmltv.EpgClient
import io.iptvplayer.core.xmltv.XmltvParser
import io.iptvplayer.core.xtream.XtreamClient
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.async
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okhttp3.mockwebserver.SocketPolicy
import okio.Buffer
import org.junit.jupiter.api.AfterEach
import org.junit.jupiter.api.BeforeEach
import org.kxml2.io.KXmlParser
import java.util.concurrent.TimeUnit
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertTrue

/**
 * Error mapping of CONTRACT §2 / §4.4 over a real socket (OkHttp MockWebServer):
 * timeouts, 4xx/5xx, HTML instead of JSON, redirects, gzip, refused/DNS/offline, cancellation,
 * and the retry policy (2 retries, 2 s / 4 s, only Network/5xx before the body is consumed).
 */
class NetworkErrorsTest {
    private lateinit var server: MockWebServer

    @BeforeEach
    fun start() {
        server = MockWebServer()
        server.start()
    }

    @AfterEach
    fun stop() = server.shutdown()

    private val okM3u = "#EXTM3U\n#EXTINF:-1,One\nhttp://h/1.ts\n"

    private fun xtream(rec: RecordingHttp) =
        XtreamClient(rec.http, "s", SourceSecrets.Xtream(server.url("/").toString(), "u", "p"), nowMs = { 0L })

    private suspend fun m3u(rec: RecordingHttp, path: String = "/list.m3u"): List<M3uEntry> {
        val out = ArrayList<M3uEntry>()
        M3uClient(rec.http).fetch(server.url(path).toString()) { out += it }
        return out
    }

    private inline fun sourceError(block: () -> Unit): SourceError = assertFailsWith<SourceException> { block() }.error

    // ---------------------------------------------------------------- HTTP statuses

    @Test
    fun serverErrorsAreRetriedTwiceThenReported(): Unit = runBlocking {
        repeat(3) { server.enqueue(MockResponse().setResponseCode(503)) }
        val rec = RecordingHttp()
        assertEquals(SourceError.ServerError(503), sourceError { m3u(rec) })
        assertEquals(3, server.requestCount)
        assertEquals(listOf(2_000L, 4_000L), rec.sleeps)
    }

    @Test
    fun transientServerErrorRecovers(): Unit = runBlocking {
        server.enqueue(MockResponse().setResponseCode(502))
        server.enqueue(MockResponse().setBody(okM3u))
        val rec = RecordingHttp()
        assertEquals(listOf("One"), m3u(rec).map { it.name })
        assertEquals(listOf(2_000L), rec.sleeps)
    }

    @Test
    fun clientErrorsAreNeverRetried(): Unit = runBlocking {
        server.enqueue(MockResponse().setResponseCode(404))
        assertEquals(SourceError.NotFound, sourceError { m3u(RecordingHttp()) })
        server.enqueue(MockResponse().setResponseCode(401))
        assertEquals(SourceError.ServerError(401), sourceError { m3u(RecordingHttp()) }, "M3U: 401 is a generic non-2xx")
        server.enqueue(MockResponse().setResponseCode(401))
        assertEquals(SourceError.InvalidCredentials, sourceError { xtream(RecordingHttp()).authenticate() })
        server.enqueue(MockResponse().setResponseCode(403).setBody("<html>Forbidden</html>"))
        assertEquals(SourceError.InvalidCredentials, sourceError { xtream(RecordingHttp()).liveStreams() })
        server.enqueue(MockResponse().setResponseCode(404))
        assertEquals(SourceError.NotFound, sourceError { xtream(RecordingHttp()).authenticate() })
        server.enqueue(MockResponse().setResponseCode(410))
        assertEquals(SourceError.ServerError(410), sourceError { xtream(RecordingHttp()).vodStreams() })
        assertEquals(6, server.requestCount)
    }

    // ---------------------------------------------------------------- wrong content

    @Test
    fun htmlInsteadOfJsonIsInvalidResponseAndNotRetried(): Unit = runBlocking {
        val html = Vectors.text("xtream/auth_html.txt")
        server.enqueue(MockResponse().setBody(html).addHeader("Content-Type", "text/html"))
        assertEquals(SourceError.InvalidResponse, sourceError { xtream(RecordingHttp()).authenticate() })
        server.enqueue(MockResponse().setBody(html))
        assertEquals(SourceError.InvalidResponse, sourceError { xtream(RecordingHttp()).liveStreams() })
        server.enqueue(MockResponse().setBody(html))
        assertEquals(SourceError.InvalidResponse, sourceError { xtream(RecordingHttp()).seriesInfo("1") })
        assertEquals(3, server.requestCount)
    }

    @Test
    fun htmlInsteadOfPlaylistOrGuideIsInvalidFormat(): Unit = runBlocking {
        server.enqueue(MockResponse().setBody(Vectors.text("m3u/broken_html.m3u")))
        assertEquals(SourceError.InvalidFormat, sourceError { m3u(RecordingHttp()) })
        server.enqueue(MockResponse().setBody("<html><body>Login</body></html>"))
        val epg = EpgClient(RecordingHttp().http, XmltvParser { KXmlParser() })
        assertEquals(SourceError.InvalidFormat, sourceError { epg.fetch(server.url("/epg.xml").toString()) {} })
    }

    // ---------------------------------------------------------------- redirects & gzip

    @Test
    fun redirectsAreFollowed(): Unit = runBlocking {
        server.enqueue(MockResponse().setResponseCode(302).addHeader("Location", "/moved.m3u"))
        server.enqueue(MockResponse().setResponseCode(301).addHeader("Location", server.url("/final.m3u").toString()))
        server.enqueue(MockResponse().setBody(okM3u))
        assertEquals(1, m3u(RecordingHttp()).size)
        assertEquals(listOf("/list.m3u", "/moved.m3u", "/final.m3u"), List(3) { server.takeRequest().path })
        // Redirect to a 404 → NotFound of the final URL.
        server.enqueue(MockResponse().setResponseCode(307).addHeader("Location", "/gone"))
        server.enqueue(MockResponse().setResponseCode(404))
        assertEquals(SourceError.NotFound, sourceError { m3u(RecordingHttp()) })
    }

    @Test
    fun gzipWithAndWithoutContentEncoding(): Unit = runBlocking {
        // Transparent: Content-Encoding header (OkHttp adds Accept-Encoding and inflates).
        server.enqueue(MockResponse().setBody(MockServerSupport.gzip(okM3u)).addHeader("Content-Encoding", "gzip"))
        assertEquals(1, m3u(RecordingHttp()).size)
        assertEquals("gzip", server.takeRequest().getHeader("Accept-Encoding"))
        // Raw .gz file without header: magic-byte detection.
        server.enqueue(MockResponse().setBody(MockServerSupport.gzip(okM3u)).addHeader("Content-Type", "application/octet-stream"))
        assertEquals(1, m3u(RecordingHttp(), "/list.m3u.gz").size)
        // Xtream JSON, both ways.
        val json = """[{"stream_id":1,"name":"A"},{"stream_id":2,"name":"B"}]"""
        server.enqueue(MockResponse().setBody(MockServerSupport.gzip(json)).addHeader("Content-Encoding", "gzip"))
        assertEquals(2, xtream(RecordingHttp()).liveStreams().size)
        server.enqueue(MockResponse().setBody(MockServerSupport.gzip(json)))
        assertEquals(2, xtream(RecordingHttp()).liveStreams().size)
        // XMLTV gz.
        server.enqueue(MockResponse().setBody(MockServerSupport.gzip(Vectors.text("xmltv/epg_basic.xml"))))
        var programmes = 0
        EpgClient(RecordingHttp().http, XmltvParser { KXmlParser() }).fetch(server.url("/e.xml.gz").toString()) { programmes += it.size }
        assertTrue(programmes > 0)
    }

    // ---------------------------------------------------------------- network failures

    @Test
    fun noResponseTimesOutAndIsRetried(): Unit = runBlocking {
        repeat(3) { server.enqueue(MockResponse().setSocketPolicy(SocketPolicy.NO_RESPONSE)) }
        val rec = RecordingHttp(MockServerSupport.fastClient(readTimeoutMs = 200))
        assertEquals(SourceError.Network(NetworkReason.TIMEOUT), sourceError { xtream(rec).authenticate() })
        assertEquals(3, server.requestCount)
        assertEquals(listOf(2_000L, 4_000L), rec.sleeps)
    }

    @Test
    fun stallWhileReadingBodyTimesOutWithoutRetry(): Unit = runBlocking {
        // Headers arrive, then the body trickles in slower than the read timeout.
        val body = Buffer().writeUtf8(okM3u.repeat(50))
        server.enqueue(MockResponse().setBody(body).throttleBody(16, 1, TimeUnit.SECONDS))
        val rec = RecordingHttp(MockServerSupport.fastClient(readTimeoutMs = 200))
        assertEquals(SourceError.Network(NetworkReason.TIMEOUT), sourceError { m3u(rec) })
        assertEquals(1, server.requestCount, "failures while consuming the body are not retried")
        assertEquals(emptyList(), rec.sleeps)
    }

    @Test
    fun wholeCallTimeoutApplies(): Unit = runBlocking {
        // Each chunk arrives within the read timeout, but the whole call exceeds the call timeout.
        server.enqueue(MockResponse().setBody(Buffer().writeUtf8(okM3u.repeat(40))).throttleBody(64, 100, TimeUnit.MILLISECONDS))
        val rec = RecordingHttp(MockServerSupport.fastClient(readTimeoutMs = 1_000))
        val e = sourceError {
            M3uClient(rec.http).fetch(server.url("/l.m3u").toString(), callTimeoutMs = 300) {}
        }
        assertEquals(SourceError.Network(NetworkReason.TIMEOUT), e)
    }

    @Test
    fun connectionRefused(): Unit = runBlocking {
        val url = server.url("/x.m3u").toString()
        server.shutdown()
        val rec = RecordingHttp()
        val e = assertFailsWith<SourceException> { M3uClient(rec.http).fetch(url) {} }
        assertEquals(SourceError.Network(NetworkReason.REFUSED), e.error)
        assertEquals(2, rec.sleeps.size, "network errors are retried")
    }

    @Test
    fun dnsFailure(): Unit = runBlocking {
        val noDns = MockServerSupport.NO_DNS
        val rec = RecordingHttp(MockServerSupport.fastClient(dns = noDns))
        val e = assertFailsWith<SourceException> { M3uClient(rec.http).fetch("http://iptv.invalid/list.m3u") {} }
        assertEquals(SourceError.Network(NetworkReason.DNS), e.error)
    }

    @Test
    fun offlineIsReportedAndNotRetried(): Unit = runBlocking {
        val noDns = MockServerSupport.NO_DNS
        val rec = RecordingHttp(MockServerSupport.fastClient(dns = noDns), offline = true)
        val e = assertFailsWith<SourceException> { M3uClient(rec.http).fetch("http://iptv.invalid/list.m3u") {} }
        assertEquals(SourceError.Network(NetworkReason.OFFLINE), e.error)
        assertEquals(emptyList(), rec.sleeps)
    }

    @Test
    fun cancellationAbortsBlockedCall(): Unit = runBlocking {
        server.enqueue(MockResponse().setSocketPolicy(SocketPolicy.NO_RESPONSE))
        val rec = RecordingHttp(MockServerSupport.fastClient(readTimeoutMs = 30_000))
        val started = System.nanoTime()
        val job = async { xtream(rec).authenticate() }
        delay(200)
        job.cancel()
        assertFailsWith<CancellationException> { withTimeout(5_000) { job.await() } }
        assertTrue((System.nanoTime() - started) / 1_000_000 < 5_000, "cancel must not wait for the read timeout")
        assertEquals(emptyList(), rec.sleeps)
    }
}
