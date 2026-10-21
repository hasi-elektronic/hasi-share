package io.iptvplayer.core.xmltv

import io.iptvplayer.core.Vectors
import io.iptvplayer.core.assertJsonEquals
import io.iptvplayer.core.error.SourceError
import io.iptvplayer.core.error.SourceException
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.longOrNull
import okio.Buffer
import okio.buffer
import okio.gzip
import okio.source
import org.kxml2.io.KXmlParser
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertNull
import kotlin.test.assertTrue

class XmltvVectorsTest {
    private val parser = XmltvParser { KXmlParser() }

    @Test
    fun timeParsing() {
        val cases = Vectors.json("xmltv/time-parsing.json").jsonObject.getValue("cases").jsonArray
        assertEquals(10, cases.size)
        for (c in cases.map { it.jsonObject }) {
            val input = c.getValue("input").jsonPrimitive.content
            val expected = c.getValue("expected").jsonPrimitive.longOrNull
            assertEquals(expected?.times(1000), XmltvTime.parse(input), "input '$input'")
        }
        assertNull(XmltvTime.parse("20251304120000"))
        assertEquals(XmltvTime.parse("20251004120000 +0200"), XmltvTime.parse("20251004120000 +02:00"))
    }

    private fun bytesOf(gzip: Boolean): ByteArray {
        val raw = Vectors.file("xmltv/epg_basic.xml").readBytes()
        if (!gzip) return raw
        val out = Buffer()
        (out as okio.Sink).gzip().buffer().use { it.write(raw) }
        return out.readByteArray().also { assertEquals(0x1f, it[0].toInt() and 0xff) }
    }

    private fun run(bytes: ByteArray, language: String, shift: Int, batchSize: Int = 1000): Pair<List<XmltvChannel>, List<XmltvProgramme>> {
        val channels = ArrayList<XmltvChannel>()
        val programmes = ArrayList<XmltvProgramme>()
        val result = runBlocking {
            parser.parse(
                Buffer().write(bytes),
                XmltvOptions(preferredLanguage = language, shiftMinutes = shift, batchSize = batchSize),
                onChannels = { channels += it },
            ) {
                assertTrue(it.size <= batchSize)
                programmes += it
            }
        }
        assertEquals(programmes.size, result.programmeCount)
        assertEquals(2, result.dropped, "Zero length + Broken")
        assertEquals(setOf("trt1.tr", "ard.de"), result.programmeChannelIds)
        return channels to programmes
    }

    @Test
    fun epgBasicAllCasesPlainAndGzip() {
        val expected = Vectors.json("xmltv/epg_basic.expected.json").jsonObject
        val cases = expected.getValue("cases").jsonArray
        assertEquals(3, cases.size)
        for (gzip in listOf(false, true)) {
            for (c in cases.map { it.jsonObject }) {
                for (batch in listOf(1000, 1)) {
                    val (channels, programmes) = run(
                        bytesOf(gzip),
                        c.getValue("language").jsonPrimitive.content,
                        c.getValue("shiftMinutes").jsonPrimitive.int,
                        batch,
                    )
                    val sorted = programmes.sortedWith(compareBy({ it.channel }, { it.startMs }))
                    val actual = JsonArray(sorted.map { p ->
                        buildJsonObject {
                            put("channel", JsonPrimitive(p.channel))
                            put("start", JsonPrimitive(p.startMs / 1000))
                            put("end", JsonPrimitive(p.endMs / 1000))
                            put("title", JsonPrimitive(p.title))
                            put("description", p.description?.let { JsonPrimitive(it) } ?: JsonNull)
                            put("category", p.category?.let { JsonPrimitive(it) } ?: JsonNull)
                        }
                    })
                    assertJsonEquals(c.getValue("programmes"), actual, "gzip=$gzip case=$c")
                    val actualChannels = JsonArray(channels.map { ch ->
                        buildJsonObject {
                            put("id", JsonPrimitive(ch.id))
                            put("displayNames", JsonArray(ch.displayNames.map { JsonPrimitive(it) }))
                            put("icon", ch.icon?.let { JsonPrimitive(it) } ?: JsonNull)
                        }
                    })
                    assertJsonEquals(expected.getValue("channels"), actualChannels)
                }
            }
        }
    }

    @Test
    fun retentionWindowFiltersProgrammes() {
        val window = 1759591800_000L..1759600000_000L
        val programmes = ArrayList<XmltvProgramme>()
        val result = runBlocking {
            parser.parse(Buffer().write(bytesOf(false)), XmltvOptions(preferredLanguage = "tr", window = window)) { programmes += it }
        }
        assertTrue(programmes.all { EpgRetention.keep(it.startMs, it.endMs, window) })
        assertEquals(6 - programmes.size, result.outsideWindow)
        val w = EpgRetention.window(1_000_000_000_000L, 0)
        assertEquals(1_000_000_000_000L - 86_400_000L, w.first)
        assertEquals(1_000_000_000_000L + 7 * 86_400_000L, w.last)
        assertEquals(1_000_000_000_000L - 3 * 86_400_000L, EpgRetention.purgeBefore(1_000_000_000_000L, 3))
    }

    @Test
    fun invalidDocumentsAreInvalidFormat() {
        for (text in listOf("<!DOCTYPE html><html><body>403</body></html>", "not xml at all", "", "<?xml version=\"1.0\"?><rss/>")) {
            val e = assertFailsWith<SourceException>(text) {
                runBlocking { parser.parse(Buffer().writeUtf8(text)) { } }
            }
            assertEquals(SourceError.InvalidFormat, e.error, text)
        }
    }

    @Test
    fun truncatedDocumentKeepsWhatWasParsed() {
        // Relaxed mode: a truncated file is not fatal; the incomplete programme is dropped.
        val xml = "<tv><programme start=\"20251004120000\" stop=\"20251004130000\" channel=\"A\"><title>T</title></programme><programme"
        val out = ArrayList<XmltvProgramme>()
        val r = runBlocking { parser.parse(Buffer().writeUtf8(xml)) { out += it } }
        assertEquals(1, r.programmeCount)
        assertEquals("T", out.single().title)
    }

    @Test
    fun relaxedEntitiesAndNestedMarkup() {
        val xml = """<?xml version="1.0"?><tv><programme start="20251004120000" stop="20251004130000" channel="A">
            <title>Tom &amp; Jerry&nbsp;Show</title><desc><b>bold</b> text</desc></programme></tv>"""
        val out = ArrayList<XmltvProgramme>()
        runBlocking { parser.parse(Buffer().writeUtf8(xml)) { out += it } }
        assertEquals(1, out.size)
        assertTrue(out[0].title.startsWith("Tom & Jerry"))
        assertEquals("bold text", out[0].description)
    }

    @Test
    fun epgMatcher() {
        val (channels, _) = run(bytesOf(false), "tr", 0)
        val m = EpgMatcher(channels, listOf("orphan.id"))
        assertEquals("trt1.tr", m.match("TRT1.TR", "whatever"))
        assertEquals("trt1.tr", m.match(null, "TRT 1 FHD"))
        assertEquals("trt1.tr", m.match("unknown", "TR: TRT 1"))
        assertEquals("ard.de", m.match("", "Das Erste (DE)"))
        assertEquals("orphan.id", m.match("Orphan.ID", null))
        assertNull(m.match("x", "ZDF"))
        assertEquals("ard.de", m.match("x", "nope", "Das Erste HD"))
    }

    @Suppress("unused")
    private fun unusedObj(o: JsonObject) = o
}
