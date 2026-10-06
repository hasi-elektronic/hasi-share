package io.iptvplayer.core.xtream

import io.iptvplayer.core.Vectors
import io.iptvplayer.core.assertJsonEquals
import io.iptvplayer.core.error.PlaybackError
import io.iptvplayer.core.error.PlaybackException
import io.iptvplayer.core.error.SourceError
import io.iptvplayer.core.error.SourceException
import io.iptvplayer.core.media.PlayerEngine
import io.iptvplayer.core.model.Channel
import io.iptvplayer.core.model.ContentKind
import io.iptvplayer.core.model.Episode
import io.iptvplayer.core.model.Movie
import io.iptvplayer.core.model.Series
import io.iptvplayer.core.model.XtreamAccountInfo
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.long
import kotlinx.serialization.json.put
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertNull
import kotlin.test.assertTrue
import kotlin.test.fail

/** CONTRACT §4 against `spec/test-vectors/xtream`. */
class XtreamVectorsTest {
    private val src = "src1"

    private fun json(path: String): JsonElement = Vectors.json("xtream/$path")

    private fun num(v: Number?): JsonElement = if (v == null) JsonNull else JsonPrimitive(v)

    private fun str(v: String?): JsonElement = if (v == null) JsonNull else JsonPrimitive(v)

    private fun secs(ms: Long?): JsonElement = num(ms?.let { it / 1000 })

    @Test
    fun everyXtreamVectorFileIsUsed() {
        val used = setOf(
            "auth.expected.json", "auth_banned.json", "auth_disabled.json", "auth_empty_array.json", "auth_expired.json",
            "auth_expired_by_date.json", "auth_html.txt", "auth_invalid.json", "auth_null_exp.json", "auth_ok.json",
            "auth_user_info_array.json", "live_categories.expected.json", "live_categories.json", "live_streams.expected.json",
            "live_streams.json", "series.expected.json", "series.json", "series_info.expected.json", "series_info.json",
            "series_info_list_variant.json", "short_epg.expected.json", "short_epg.json", "url-vectors.json",
            "vod_streams.expected.json", "vod_streams.json", "series_categories.json", "series_categories.expected.json",
            "category_ids.json", "category_ids.expected.json",
        )
        val present = Vectors.file("xtream/auth_ok.json").parentFile.listFiles()!!.map { it.name }.toSet()
        assertEquals(present, used, "new xtream vector files must get a test")
    }

    @Test
    fun liveCategories() {
        val cats = XtreamMapper.categories(json("live_categories.json"), src, ContentKind.LIVE)
        val actual = JsonArray(cats.map { buildJsonObject { put("id", it.id); put("name", it.name) } })
        assertJsonEquals(json("live_categories.expected.json"), actual)
        assertEquals(listOf(0, 1), cats.map { it.sort })
        assertTrue(cats.all { it.kind == ContentKind.LIVE && it.sourceId == src })
    }

    /** `get_series_categories` with numeric/string ids, `parent_id` and Turkish names: nothing valid is dropped. */
    @Test
    fun seriesCategories() {
        val cats = XtreamMapper.categories(json("series_categories.json"), src, ContentKind.SERIES)
        val actual = JsonArray(cats.map { buildJsonObject { put("id", it.id); put("name", it.name) } })
        assertJsonEquals(json("series_categories.expected.json"), actual)
        assertEquals(cats.indices.toList(), cats.map { it.sort }, "provider order")
    }

    private fun categoryRow(id: String, categoryId: String?, categoryIds: List<String>) = buildJsonObject {
        put("id", id)
        put("categoryId", str(categoryId))
        put("categoryIds", JsonArray(categoryIds.map(::JsonPrimitive)))
    }

    /** XUI.one / newer panels: `category_ids` arrays (ints or strings), `category_id` null/""/only the first. */
    @Test
    fun categoryIds() {
        val input = json("category_ids.json").jsonObject
        val expected = json("category_ids.expected.json").jsonObject
        assertJsonEquals(expected.getValue("live"),
            JsonArray(XtreamMapper.channels(input["live"], src).map { categoryRow(it.id, it.categoryId, it.categoryIds) }))
        assertJsonEquals(expected.getValue("vod"),
            JsonArray(XtreamMapper.movies(input["vod"], src).map { categoryRow(it.id, it.categoryId, it.categoryIds) }))
        assertJsonEquals(expected.getValue("series"),
            JsonArray(XtreamMapper.series(input["series"], src).map { categoryRow(it.id, it.categoryId, it.categoryIds) }))
    }

    private fun channelJson(c: Channel) = buildJsonObject {
        put("id", c.id)
        put("name", c.name)
        put("number", num(c.number))
        put("logoUrl", str(c.logoUrl))
        put("categoryId", str(c.categoryId))
        put("epgId", str(c.epgId))
        put("catchup", buildJsonObject { put("type", c.catchup.type.wire); put("days", c.catchup.days) })
    }

    @Test
    fun liveStreams() {
        val channels = XtreamMapper.channels(json("live_streams.json"), src)
        assertJsonEquals(json("live_streams.expected.json"), JsonArray(channels.map(::channelJson)))
        assertTrue(channels.all { it.url == null }, "Xtream URLs are never persisted")
    }

    private fun movieJson(m: Movie) = buildJsonObject {
        put("id", m.id)
        put("name", m.name)
        put("posterUrl", str(m.posterUrl))
        put("categoryId", str(m.categoryId))
        put("rating", num(m.rating))
        put("year", num(m.year))
        put("containerExt", str(m.containerExt))
        put("addedAt", secs(m.addedAtMs))
    }

    @Test
    fun vodStreams() {
        val movies = XtreamMapper.movies(json("vod_streams.json"), src)
        assertJsonEquals(json("vod_streams.expected.json"), JsonArray(movies.map(::movieJson)))
    }

    private fun seriesJson(s: Series) = buildJsonObject {
        put("id", s.id)
        put("name", s.name)
        put("posterUrl", str(s.posterUrl))
        put("categoryId", str(s.categoryId))
        put("plot", str(s.plot))
        put("rating", num(s.rating))
        put("year", num(s.year))
    }

    @Test
    fun series() {
        val series = XtreamMapper.series(json("series.json"), src)
        assertJsonEquals(json("series.expected.json"), JsonArray(series.map(::seriesJson)))
        assertEquals(1_700_000_000_000L, series[0].lastModifiedMs)
    }

    private fun episodeJson(e: Episode) = buildJsonObject {
        put("id", e.id)
        put("seriesId", e.seriesId)
        put("season", e.season)
        put("number", e.number)
        put("title", e.title)
        put("containerExt", str(e.containerExt))
        put("durationSec", num(e.durationSec))
        put("plot", str(e.plot))
        put("posterUrl", str(e.posterUrl))
    }

    @Test
    fun seriesInfoBothShapes() {
        val cases = json("series_info.expected.json").jsonObject.getValue("cases").jsonArray
        assertEquals(2, cases.size)
        for (c in cases.map { it.jsonObject }) {
            val file = c.getValue("file").jsonPrimitive.content
            val seriesId = c.getValue("seriesId").jsonPrimitive.content
            val info = XtreamMapper.seriesInfo(json(file), src, seriesId)
            assertJsonEquals(c.getValue("episodes"), JsonArray(info.episodes.map(::episodeJson)), file)
        }
        val details = XtreamMapper.seriesDetails(json("series_info.json"))
        assertEquals("Breaking Bad", details.name)
        assertEquals(2008, details.year)
        assertEquals(9.5, details.rating)
        assertEquals("20", details.categoryId)
        // `info: []` → empty details, not a failure.
        assertEquals(XtreamSeriesDetails(), XtreamMapper.seriesDetails(json("series_info_list_variant.json")))
    }

    @Test
    fun shortEpg() {
        val entries = XtreamMapper.shortEpg(json("short_epg.json"))
        val actual = JsonArray(
            entries.map {
                buildJsonObject {
                    put("start", it.startMs / 1000)
                    put("end", it.endMs / 1000)
                    put("title", str(it.title))
                    put("description", str(it.description))
                    put("hasArchive", it.hasArchive)
                }
            },
        )
        assertJsonEquals(json("short_epg.expected.json"), actual)
    }

    // ------------------------------------------------------------- account

    private fun accountJson(a: XtreamAccountInfo) = buildJsonObject {
        put("result", "OK")
        put("status", str(a.status))
        put("expiresAt", secs(a.expiresAtMs))
        put("maxConnections", num(a.maxConnections))
        put("activeConnections", num(a.activeConnections))
        put("allowedOutputFormats", JsonArray(a.allowedOutputFormats.map { JsonPrimitive(it) }))
        put("serverTimezone", a.serverTimezone)
    }

    private fun errorJson(e: SourceError): JsonObject = when (e) {
        SourceError.InvalidCredentials -> buildJsonObject { put("result", "InvalidCredentials") }
        SourceError.AccountDisabled -> buildJsonObject { put("result", "AccountDisabled") }
        SourceError.InvalidResponse -> buildJsonObject { put("result", "InvalidResponse") }
        SourceError.NotFound -> buildJsonObject { put("result", "NotFound") }
        is SourceError.AccountExpired -> buildJsonObject { put("result", "AccountExpired"); put("expiresAt", secs(e.expiresAtMs)) }
        is SourceError.ServerError -> buildJsonObject { put("result", "ServerError"); put("httpStatus", e.httpStatus) }
        else -> fail("unexpected $e")
    }

    @Test
    fun accountClassification() {
        val root = json("auth.expected.json").jsonObject
        val nowMs = root.getValue("nowEpochSeconds").jsonPrimitive.long * 1000
        val cases = root.getValue("cases").jsonArray
        assertEquals(14, cases.size)
        for (c in cases.map { it.jsonObject }) {
            val file = c.getValue("file").jsonPrimitive.content
            val http = c.getValue("http").jsonPrimitive.int
            val body = Vectors.text("xtream/$file")
            val actual = try {
                accountJson(XtreamAccountClassifier.classify(http, body, nowMs))
            } catch (e: SourceException) {
                errorJson(e.error)
            }
            assertJsonEquals(c.getValue("expected"), actual, "$file/$http")
        }
    }

    @Test
    fun accountExtras() {
        val ok = XtreamAccountClassifier.classify(200, Vectors.text("xtream/auth_ok.json"), 1_759_570_000_000)
        assertEquals(false, ok.isTrial)
        assertEquals(1_700_000_000_000, ok.createdAtMs)
        // Status check precedes the date check: an Expired status without date is still expired.
        val e = assertFailsWith<SourceException> {
            XtreamAccountClassifier.classify(200, """{"user_info":{"auth":1,"status":"Expired"}}""", 0)
        }
        assertEquals(SourceError.AccountExpired(null), e.error)
        // Non-empty array / JSON string → InvalidResponse; missing user_info → InvalidCredentials.
        assertEquals(SourceError.InvalidResponse, assertFailsWith<SourceException> { XtreamAccountClassifier.classify(200, "[1]", 0) }.error)
        assertEquals(SourceError.InvalidResponse, assertFailsWith<SourceException> { XtreamAccountClassifier.classify(200, "\"x\"", 0) }.error)
        assertEquals(SourceError.InvalidCredentials, assertFailsWith<SourceException> { XtreamAccountClassifier.classify(200, "{}", 0) }.error)
        assertEquals(SourceError.InvalidCredentials, assertFailsWith<SourceException> { XtreamAccountClassifier.classify(200, """{"user_info":{"auth":"0"}}""", 0) }.error)
        // Boolean auth is accepted; missing server_info → UTC.
        val minimal = XtreamAccountClassifier.classify(200, """{"user_info":{"auth":true}}""", 0)
        assertNull(minimal.status)
        assertEquals("UTC", minimal.serverTimezone)
        assertEquals(emptyList(), minimal.allowedOutputFormats)
    }

    // ------------------------------------------------------------- URLs

    @Test
    fun urlVectors() {
        val root = json("url-vectors.json").jsonObject
        val cred = root.getValue("credentials").jsonObject
        val b = XtreamUrlBuilder(
            cred.getValue("base").jsonPrimitive.content,
            cred.getValue("username").jsonPrimitive.content,
            cred.getValue("password").jsonPrimitive.content,
        )
        val urls = root.getValue("urls").jsonArray
        assertEquals(8, urls.size)
        for (u in urls.map { it.jsonObject }) {
            fun s(k: String) = u[k]?.let { if (it is JsonNull) null else it.jsonPrimitive.content }
            val actual = when (s("kind")) {
                "api" -> b.api(s("action"))
                "xmltv" -> b.xmltv()
                "live" -> b.live(s("streamId")!!, s("ext")!!)
                "movie" -> b.movie(s("streamId")!!, s("ext")!!)
                "episode" -> b.episode(s("streamId")!!, s("ext")!!)
                "timeshift" -> b.timeshift(
                    s("streamId")!!,
                    u.getValue("start").jsonPrimitive.long * 1000,
                    u.getValue("end").jsonPrimitive.long * 1000,
                    s("serverTimezone"),
                    s("ext")!!,
                )
                else -> fail("unknown kind $u")
            }
            assertEquals(s("expected"), actual, u.toString())
        }
        val live = root.getValue("liveExt").jsonArray
        assertEquals(7, live.size)
        for (c in live.map { it.jsonObject }) {
            val engine = when (c.getValue("platform").jsonPrimitive.content) {
                "android" -> PlayerEngine.MEDIA3
                "apple" -> PlayerEngine.AVPLAYER
                else -> fail("platform")
            }
            val allowed = c.getValue("allowed").jsonArray.map { it.jsonPrimitive.content }
            val expected = c.getValue("expected").jsonPrimitive.content
            val actual = try {
                XtreamUrlBuilder.liveExtension(engine, allowed)
            } catch (e: PlaybackException) {
                assertEquals(PlaybackError.UnsupportedFormat("mpegts"), e.error)
                "error:UnsupportedFormat"
            }
            assertEquals(expected, actual, c.toString())
        }
    }

    // ------------------------------------------------------------- leniency

    @Test
    fun lenientScalars() {
        val p = { s: String -> XtreamJson.parseOrNull(s) }
        assertEquals(7, XtreamJson.int(p("7")))
        assertEquals(7, XtreamJson.int(p("\"7\"")))
        assertEquals(7, XtreamJson.int(p("\" 7.0 \"")))
        assertNull(XtreamJson.int(p("\"\"")))
        assertNull(XtreamJson.int(p("null")))
        assertNull(XtreamJson.int(p("\"abc\"")))
        assertEquals(8.8, XtreamJson.double(p("\"8.8\"")))
        assertTrue(XtreamJson.bool(p("1")))
        assertTrue(XtreamJson.bool(p("\"1\"")))
        assertTrue(XtreamJson.bool(p("true")))
        assertTrue(!XtreamJson.bool(p("\"0\"")))
        assertTrue(!XtreamJson.bool(p("\"yes\"")))
        assertEquals("1001", XtreamJson.string(p("1001")))
        assertEquals("1001", XtreamJson.string(p("1001.0")))
        assertNull(XtreamJson.string(p("\"\"")))
        assertEquals(JsonObject(emptyMap()), XtreamJson.obj(p("[]")))
        assertNull(XtreamJson.parseOrNull("<html>"))
        // Object-shaped list (`{"1": {...}, "0": {...}}`) is ordered by numeric key.
        val cats = XtreamMapper.categories(p("""{"1":{"category_id":"b","category_name":"B"},"0":{"category_id":"a","category_name":"A"}}"""), src, ContentKind.MOVIE)
        assertEquals(listOf("a", "b"), cats.map { it.id })
        // Malformed items are skipped, never fatal.
        assertEquals(1, XtreamMapper.channels(p("""[42, "x", null, {"stream_id": 5, "name": "ok"}, {"name": "no id"}]"""), src).size)
        // HTML entities are left as-is.
        assertEquals("Tom &amp; Jerry", XtreamMapper.movies(p("""[{"stream_id":1,"name":"Tom &amp; Jerry"}]"""), src)[0].name)
        assertEquals(3480, XtreamMapper.parseClock("00:58:00"))
        assertEquals("plain title", XtreamMapper.decodeBase64Text("plain title"))
    }
}
