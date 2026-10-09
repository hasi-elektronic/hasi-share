package io.iptvplayer.core.util

import io.iptvplayer.core.Vectors
import io.iptvplayer.core.model.ContentKind
import io.iptvplayer.core.model.SourceSecrets
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.long
import java.util.Locale
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

class UtilVectorsTest {
    private fun s(o: kotlinx.serialization.json.JsonObject, k: String) = o.getValue(k).jsonPrimitive.content

    @Test
    fun contentKeys() {
        val root = Vectors.json("content-keys.json").jsonObject
        val cases = root.getValue("cases").jsonArray
        assertEquals(7, cases.size)
        for (c in cases.map { it.jsonObject }) {
            val kind = ContentKind.fromWire(s(c, "kind"))!!
            when (s(c, "type")) {
                "xtream" -> {
                    val fp = ContentKeys.xtreamFingerprint(s(c, "host"), s(c, "username"))
                    assertEquals(s(c, "fingerprint"), fp, "fingerprint for $c")
                    assertEquals(s(c, "contentKey"), ContentKeys.contentKey(fp, kind, s(c, "itemId")))
                    // Same result when starting from a user-typed server URL.
                    assertEquals(fp, ContentKeys.xtreamFingerprintForServer("http://${s(c, "host")}:8080/", s(c, "username")))
                }
                "m3u" -> {
                    assertEquals(s(c, "normalizedUrl"), UrlNormalizer.normalizeUrl(s(c, "url")))
                    val fp = ContentKeys.m3uFingerprint(s(c, "url"))
                    assertEquals(s(c, "fingerprint"), fp)
                    val itemId = ContentKeys.m3uItemId(s(c, "entryUrl"))
                    assertEquals(s(c, "itemId"), itemId)
                    assertEquals(s(c, "contentKey"), ContentKeys.contentKey(fp, kind, itemId))
                    assertEquals(fp, ContentKeys.fingerprint(SourceSecrets.M3u(s(c, "url"))))
                }
                else -> error("unknown type")
            }
            val parsed = ContentKeys.parse(s(c, "contentKey"))!!
            assertEquals(kind, parsed.kind)
            assertEquals(s(c, "fingerprint"), parsed.fingerprint)
        }
    }

    @Test
    fun deviceKeys() {
        val list = Vectors.json("content-keys.json").jsonObject.getValue("deviceKeys").jsonArray
        assertEquals(2, list.size)
        for (c in list.map { it.jsonObject }) {
            assertEquals(s(c, "expected"), DeviceKey.compute(s(c, "appId"), s(c, "rawId")))
        }
    }

    @Test
    fun redaction() {
        val cases = Vectors.json("redaction.json").jsonObject.getValue("cases").jsonArray
        assertEquals(11, cases.size)
        for (c in cases.map { it.jsonObject }) {
            val secrets = c.getValue("secrets").jsonArray.map { it.jsonPrimitive.content }
            assertEquals(s(c, "expected"), Redactor.redact(s(c, "input"), secrets), "input: ${s(c, "input")}")
            // Same through the registry.
            val r = Redactor()
            r.register(*secrets.toTypedArray())
            assertEquals(s(c, "expected"), r.redact(s(c, "input")))
        }
    }

    @Test
    fun redactorRegistryIsRefCountedAndCoversEncodedForm() {
        val r = Redactor()
        r.register("p@ss/w rd", "ab", null)
        assertEquals(listOf("p%40ss%2Fw%20rd", "p@ss/w rd"), r.secrets())
        assertEquals("x *** y ***", r.redact("x p@ss/w rd y p%40ss%2Fw%20rd"))
        r.register("p@ss/w rd")
        r.unregister("p@ss/w rd")
        assertEquals("x *** y", r.redact("x p@ss/w rd y"))
        r.unregister("p@ss/w rd")
        assertEquals("x p@ss/w rd y", r.redact("x p@ss/w rd y"))
    }

    @Test
    fun redactingLoggerRedactsMessagesAndThrowables() {
        val lines = mutableListOf<String>()
        val r = Redactor().apply { register("hunter22") }
        val logger = RedactingLogger({ _, _, m, t -> lines += m + "|" + t?.message }, r, LogLevel.INFO)
        logger.log(LogLevel.DEBUG, "t", "dropped hunter22", null)
        logger.log(LogLevel.WARN, "t", "GET http://h/live/u/hunter22/1.ts", RuntimeException("pw=hunter22"))
        assertEquals(1, lines.size)
        assertEquals("GET http://h/live/***/***/1.ts|java.lang.RuntimeException: pw=***", lines[0])
    }

    @Test
    fun nameNormalization() {
        val cases = Vectors.json("xmltv/name-normalization.json").jsonObject.getValue("cases").jsonArray
        assertEquals(14, cases.size)
        val saved = Locale.getDefault()
        try {
            // Must be locale independent – run under a Turkish default locale.
            Locale.setDefault(Locale.forLanguageTag("tr-TR"))
            for (c in cases.map { it.jsonObject }) {
                assertEquals(s(c, "expected"), NameNormalizer.normalize(s(c, "input")), "input ${s(c, "input")}")
            }
        } finally {
            Locale.setDefault(saved)
        }
    }

    @Test
    fun xtreamBaseNormalization() {
        val list = Vectors.json("xtream/url-vectors.json").jsonObject.getValue("normalize").jsonArray
        assertEquals(7, list.size)
        for (c in list.map { it.jsonObject }) {
            assertEquals(s(c, "expected"), UrlNormalizer.xtreamBase(s(c, "input")), "input '${s(c, "input")}'")
        }
    }

    @Test
    fun normalizeUrlEdgeCases() {
        assertEquals("http://[::1]:8080/a?b#C", UrlNormalizer.normalizeUrl(" HTTP://[::1]:8080/a?b#C "))
        assertEquals("https://u:P@host.example/x", UrlNormalizer.normalizeUrl("HTTPS://u:P@HOST.example:443/x"))
        assertEquals("http://host.example:8443/%7Ea", UrlNormalizer.normalizeUrl("http://Host.Example:8443/%7Ea"))
        assertEquals("not a url", UrlNormalizer.normalizeUrl(" not a url "))
        assertEquals("example.com", UrlNormalizer.displayHost("https://user:pw@Example.com:8080/x"))
        assertEquals("example.com", UrlNormalizer.displayHost("example.com:8080"))
        assertTrue(UrlNormalizer.isHttpUrl("https://a.b/c"))
        assertEquals("channel9", UrlNormalizer.lastPathSegment("http://h/stream/channel9/?x=1"))
        assertEquals("mkv", UrlNormalizer.pathExtension("http://h/v/movie.MKV?x=1.ts"))
        assertNull(UrlNormalizer.pathExtension("http://h/v/movie"))
    }

    @Test
    fun percentEncoding() {
        assertEquals("p%40ss%2Fw%20rd", PercentEncoding.encode("p@ss/w rd"))
        assertEquals("AZaz09-._~", PercentEncoding.encode("AZaz09-._~"))
        assertEquals("%C3%A7%C4%9F%2B%3D%26", PercentEncoding.encode("çğ+=&"))
        assertEquals("p@ss/w rd çğ+%zz", PercentEncoding.decode("p%40ss%2Fw%20rd%20%C3%A7%C4%9F+%zz"))
    }

    @Test
    fun base64AndHex() {
        assertEquals("AQIDBAUGBwgJCgsM", Base64Codec.encodeUrl(byteArrayOf(1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12)))
        assertEquals(12, Base64Codec.decode("AQIDBAUGBwgJCgsM")!!.size)
        assertEquals("Dizi", Base64Codec.decodeUtf8OrNull("RGl6aQ=="))
        assertNull(Base64Codec.decodeUtf8OrNull("!!!not-base64!!!"))
        assertEquals("00ff10", Hex.encode(Hex.decode("00FF10")))
        assertEquals(64, Sha256.hex("x").length)
        assertEquals(JsonNull, JsonNull)
        assertEquals(1, 1.toString().toInt())
        assertEquals(1L, kotlinx.serialization.json.JsonPrimitive(1).long)
        assertEquals(1, kotlinx.serialization.json.JsonPrimitive(1).int)
    }
}
