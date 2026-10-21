package io.iptvplayer.core.media

import io.iptvplayer.core.Vectors
import io.iptvplayer.core.error.PlaybackError
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.contentOrNull
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

class MediaVectorsTest {
    private val expected = Vectors.json("media/expected.json").jsonObject

    @Test
    fun realFilesAreSniffedFromFirst1024Bytes() {
        val files = expected.getValue("files").jsonArray.map { it.jsonObject }
        assertEquals(9, files.size)
        for (f in files) {
            val name = f.getValue("file").jsonPrimitive.content
            val bytes = Vectors.file("media/$name").inputStream().use { it.readNBytes(StreamFormatDetector.SNIFF_BYTES) }
            // Fake URL without a useful extension so that sniffing is exercised.
            val got = StreamFormatDetector.detect("http://x.example.com/stream?id=1", null, bytes)
            assertEquals(f.getValue("expected").jsonPrimitive.content, got.wire, name)
        }
    }

    @Test
    fun urlsAndContentTypes() {
        val urls = expected.getValue("urls").jsonArray.map { it.jsonObject }
        assertEquals(13, urls.size)
        for (u in urls) {
            val url = u.getValue("url").jsonPrimitive.content
            val ct = u["contentType"]?.jsonPrimitive?.contentOrNull
            assertEquals(u.getValue("expected").jsonPrimitive.content, StreamFormatDetector.detect(url, ct, null).wire, "$url / $ct")
        }
    }

    @Test
    fun supportMatrix() {
        val support = expected.getValue("support").jsonObject
        for ((engineName, engine) in listOf("media3" to PlayerEngine.MEDIA3, "avplayer" to PlayerEngine.AVPLAYER)) {
            val m = support.getValue(engineName).jsonObject
            assertEquals(Container.entries.map { it.wire }.toSet(), m.keys, "matrix covers all containers")
            for ((wire, ok) in m) {
                val c = Container.fromWire(wire)
                assertEquals(ok.jsonPrimitive.boolean, PlatformSupport.isSupported(c, engine), "$engineName/$wire")
                val check = PlatformSupport.check(c, engine)
                if (ok.jsonPrimitive.boolean) assertNull(check) else assertEquals(PlaybackError.UnsupportedFormat(wire), check)
            }
        }
    }

    @Test
    fun sniffEdgeCases() {
        assertNull(StreamFormatDetector.sniff(byteArrayOf(0x47, 0, 0)))
        assertEquals(Container.HLS, StreamFormatDetector.sniff("﻿  #EXTM3U\n#EXT-X-VERSION:3".toByteArray()))
        assertEquals(Container.DASH, StreamFormatDetector.sniff("<MPD xmlns=\"urn:mpeg:dash\">".toByteArray()))
        assertEquals(Container.UNKNOWN, StreamFormatDetector.detect("http://h/x", "text/html", "<html>".toByteArray()))
        // Scheme wins over everything.
        assertEquals(Container.RTMP, StreamFormatDetector.detect("rtmps://h/app", "video/mp4", "#EXTM3U".toByteArray()))
    }
}
