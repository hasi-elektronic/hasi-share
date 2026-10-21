package io.iptvplayer.core.m3u

import io.iptvplayer.core.TestJson
import io.iptvplayer.core.Vectors
import io.iptvplayer.core.assertJsonEquals
import io.iptvplayer.core.error.SourceError
import io.iptvplayer.core.error.SourceException
import io.iptvplayer.core.model.CatchupType
import io.iptvplayer.core.model.ContentKind
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import okio.Buffer
import okio.buffer
import okio.source
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertNull
import kotlin.test.assertTrue

class M3uVectorsTest {
    private val fixtures = listOf("valid_basic", "no_header", "partially_broken", "empty", "empty_file", "broken_html")

    @Test
    fun allFixturesMatchExpected() {
        val dirFiles = Vectors.file("m3u/valid_basic.m3u").parentFile.listFiles()!!.filter { it.name.endsWith(".m3u") }
        assertEquals(fixtures.toSet(), dirFiles.map { it.name.removeSuffix(".m3u") }.toSet(), "every M3U fixture is covered")
        for (name in fixtures) runBlocking { checkFixture(name, batchSize = 1000) }
        // Tiny batches exercise the batching path.
        for (name in fixtures) runBlocking { checkFixture(name, batchSize = 1) }
    }

    private suspend fun checkFixture(name: String, batchSize: Int) {
        val expected = Vectors.json("m3u/$name.expected.json").jsonObject
        val entries = ArrayList<M3uEntry>()
        val source = Vectors.file("m3u/$name.m3u").source().buffer()
        val error = expected["error"]?.jsonPrimitive?.content
        if (error != null) {
            val e = assertFailsWith<SourceException>("$name should fail") {
                M3uParser.parse(source, batchSize) { entries += it }
            }
            val expectedError = when (error) {
                "InvalidFormat" -> SourceError.InvalidFormat
                "Empty" -> SourceError.Empty
                else -> error("unknown $error")
            }
            assertEquals(expectedError, e.error, name)
            return
        }
        val batches = ArrayList<Int>()
        val result = M3uParser.parse(source, batchSize) {
            assertTrue(it.size <= batchSize)
            batches += it.size
            entries += it
        }
        val actual = buildJsonObject {
            put("epgUrls", JsonArray(result.epgUrls.map { JsonPrimitive(it) }))
            put("skipped", JsonPrimitive(result.skipped))
            put("entries", JsonArray(entries.map { TestJson.encodeToJsonElement(M3uEntry.serializer(), it) }))
        }
        assertJsonEquals(expected, actual, name)
        assertEquals(entries.size, result.count)
        assertEquals(entries.size, batches.sum())
    }

    @Test
    fun incrementalFeedLineMatchesStreaming() {
        val text = Vectors.text("m3u/valid_basic.m3u")
        val (entries, result) = M3uParser.parseText(text)
        assertEquals(10, entries.size)
        assertEquals(0, result.skipped)
        // CRLF line endings and no trailing newline give the same result.
        val crlf = text.replace("\n", "\r\n").trimEnd()
        val (entries2, _) = M3uParser.parseText(crlf)
        assertEquals(entries, entries2)
        runBlocking {
            val streamed = ArrayList<M3uEntry>()
            M3uParser.parse(Buffer().writeUtf8(crlf)) { streamed += it }
            assertEquals(entries, streamed)
        }
    }

    @Test
    fun titleSplittingAndAttributes() {
        assertEquals("-1 tvg-name=\"Unclosed quote" to "Weird", M3uParser.splitTitle("-1 tvg-name=\"Unclosed quote,Weird"))
        assertEquals("-1 group-title='A, B'" to "Title, with comma", M3uParser.splitTitle("-1 group-title='A, B',Title, with comma"))
        assertEquals("-1 x=\"a,b\"" to "", M3uParser.splitTitle("-1 x=\"a,b\""))
        assertEquals("-1" to "", M3uParser.splitTitle("-1"))
        // A quote not directly after '=' does not open a quoted section.
        assertEquals("-1 a=b \"c" to "d", M3uParser.splitTitle("-1 a=b \"c,d"))
        val attrs = HashMap<String, String?>()
        M3uParser.parseAttributes("-1 TVG-ID=\"x\" tvg-id=\"y\" empty=\"\" bare a=b c='d e' f=\"unterminated", 2, attrs)
        assertEquals("x", attrs["tvg-id"])
        assertNull(attrs["empty"])
        assertTrue(attrs.containsKey("empty"))
        assertEquals("b", attrs["a"])
        assertEquals("d e", attrs["c"])
        assertEquals("unterminated", attrs["f"])
    }

    @Test
    fun classificationAndSeries() {
        assertEquals(ContentKind.MOVIE, M3uParser.classify("http://h/movie/u/p/1.ts", "X S01E01"))
        assertEquals(ContentKind.EPISODE, M3uParser.classify("http://h/series/u/p/1.ts", "X"))
        assertEquals(ContentKind.MOVIE, M3uParser.classify("http://h/a/b.MP4?x=1", "Film"))
        assertEquals(ContentKind.EPISODE, M3uParser.classify("http://h/a/b.mkv", "Show s1e10"))
        assertEquals(ContentKind.LIVE, M3uParser.classify("http://h/a/b.ts", "Show S01E01"))
        assertEquals(M3uSeriesInfo("Dark", 2, 103), M3uParser.detectSeries("Dark - S02 E103 [720p]"))
        assertNull(M3uParser.detectSeries("Season 1 Episode 2"))
        assertEquals("rtp", M3uParser.schemeOf("RTP://239.1.1.1:5000"))
        assertNull(M3uParser.schemeOf("garbage line"))
    }

    @Test
    fun mapperBuildsDomainObjects() {
        val (entries, _) = M3uParser.parseText(Vectors.text("m3u/valid_basic.m3u"))
        val mapper = M3uMapper("src1")
        val first = mapper.map(entries.take(5))
        val second = mapper.map(entries.drop(5))
        assertEquals(5, first.channels.size)
        assertEquals(listOf("Ulusal", "Ulusal, Eğlence", "Deutsch", "Çocuk", "Premium"), first.categories.map { it.id })
        val trt = first.channels[0]
        assertEquals("u" + io.iptvplayer.core.util.Sha256.hex(trt.url!!).take(16), trt.id)
        assertEquals(CatchupType.DEFAULT, trt.catchup.type)
        assertEquals(7, trt.catchup.days)
        assertEquals("trt1.tr", trt.epgId)
        assertTrue(first.channels[4].drm)
        assertEquals(-1.5, first.channels[2].tvgShiftHours)
        assertEquals(listOf("Inception (2010)", "Local Movie.Night"), second.movies.map { it.name })
        assertEquals(2010, second.movies[0].year)
        assertEquals("mkv", second.movies[0].containerExt)
        assertEquals(listOf("Breaking Bad", "The Office"), second.series.map { it.name })
        assertEquals(listOf(1 to 2, 3 to 5), second.episodes.map { it.season to it.number })
        assertEquals(second.series[0].id, second.episodes[0].seriesId)
        assertEquals(1, second.channels.size) // channel9
        assertEquals(listOf(0, 1, 2, 3, 4), first.channels.map { it.sort })
        assertEquals(5, second.channels[0].sort)
    }

    @Test
    fun overlongLinesAreTruncatedNotBuffered() {
        val big = "#EXTINF:-1 tvg-logo=\"" + "x".repeat(3_000_000) + "\",Huge\nhttp://h/1.ts\n"
        val entries = ArrayList<M3uEntry>()
        runBlocking { M3uParser.parse(Buffer().writeUtf8("#EXTM3U\n$big#EXTINF:-1,Ok\nhttp://h/2.ts\n")) { entries += it } }
        // The truncated EXTINF lost its title (comma beyond the limit) → name from URL.
        assertEquals(listOf("1.ts", "Ok"), entries.map { it.name })
    }
}
