package io.iptvplayer.core.backend

import io.iptvplayer.core.CoreJson
import io.iptvplayer.core.Vectors
import io.iptvplayer.core.crypto.EcPublicJwk
import io.iptvplayer.core.error.ConnectivityProbe
import io.iptvplayer.core.error.NetworkReason
import io.iptvplayer.core.license.LicenseInfo
import io.iptvplayer.core.model.ContentKind
import io.iptvplayer.core.net.MockServerSupport
import io.iptvplayer.core.pairing.PairEnvelope
import io.iptvplayer.core.sync.SyncItem
import io.iptvplayer.core.util.CoreLogger
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okhttp3.mockwebserver.SocketPolicy
import org.junit.jupiter.api.AfterEach
import org.junit.jupiter.api.BeforeEach
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertIs
import kotlin.test.assertNull
import kotlin.test.assertTrue

/** BackendClient against spec/BACKEND_API.md shapes and the error mapping. */
class BackendClientTest {
    private lateinit var server: MockWebServer
    private lateinit var client: BackendClient
    private val logLines = mutableListOf<String>()
    private val session = "sess-TOKEN-123"

    @BeforeEach
    fun start() {
        server = MockWebServer()
        server.start()
        client = BackendClient(
            server.url("/").toString(),
            MockServerSupport.fastClient(readTimeoutMs = 300),
            logger = CoreLogger { _, _, m, _ -> logLines += m },
        )
    }

    @AfterEach
    fun stop() = server.shutdown()

    private fun json(body: String, code: Int = 200) =
        MockResponse().setResponseCode(code).setBody(body).addHeader("Content-Type", "application/json; charset=utf-8")

    private inline fun backendError(block: () -> Unit): BackendError = assertFailsWith<BackendException> { block() }.error

    @Test
    fun configAndLicenseSync(): Unit = runBlocking {
        server.enqueue(
            json(
                """{"trialDays":7,"minVersion":{"android":1,"apple":1},"products":{"google":"lifetime_access",
                |"appleLifetime":"a.l","appleTrial":"a.t"},"features":{"accounts":true,"pairing":true,"sync":false},
                |"serverTime":1759570000123,"newField":1}""".trimMargin(),
            ),
        )
        val cfg = client.config()
        assertEquals(7, cfg.trialDays)
        assertEquals("lifetime_access", cfg.products.google)
        assertFalse(cfg.features.sync)
        assertEquals(1759570000123, cfg.serverTime)
        assertEquals("/v1/config", server.takeRequest().path)

        val token = Vectors.json("license-token.json").jsonObject.getValue("cases").jsonArray[0].jsonObject.getValue("token").jsonPrimitive.content
        server.enqueue(
            json("""{"token":"$token","license":{"purchased":false,"src":null,"trialStart":1759570000,"trialEnd":1760174800,"acct":null},"serverTime":1759570000123}"""),
        )
        val req = LicenseSyncRequest(
            platform = BackendPlatform.ANDROID_TV,
            appId = "de.hasielektronik.novaplayer",
            appVersion = "1.0.0 (1)",
            deviceKey = "a".repeat(64),
            startTrial = true,
            google = GooglePurchases(listOf(GooglePurchase("lifetime_access", "tok"))),
        )
        val res = client.licenseSync(req, sessionToken = session)
        assertNull(res.partialError)
        assertEquals(token, res.response.token)
        assertEquals(LicenseInfo(false, null, 1759570000, 1760174800, null), res.response.license)
        val recorded = server.takeRequest()
        assertEquals("POST", recorded.method)
        assertEquals("Bearer $session", recorded.getHeader("Authorization"))
        assertTrue(recorded.getHeader("Content-Type")!!.startsWith("application/json"))
        val body = Json.parseToJsonElement(recorded.body.readUtf8()).jsonObject
        assertEquals("androidtv", body.getValue("platform").jsonPrimitive.content)
        assertEquals("true", body.getValue("startTrial").jsonPrimitive.content)
        assertEquals("tok", body.getValue("google").jsonObject.getValue("purchases").jsonArray[0].jsonObject.getValue("purchaseToken").jsonPrimitive.content)
        assertFalse(body.containsKey("apple"), "absent optional objects are omitted")
        assertTrue(logLines.none { it.contains(session) }, "session token never logged")
    }

    @Test
    fun licenseSyncPartialFailureStillReturnsToken(): Unit = runBlocking {
        server.enqueue(
            json(
                """{"error":"store_verification_failed","message":"Some purchases could not be verified.","details":[{"x":1}],
                |"token":"t.t.t","license":{"purchased":false,"src":null,"trialStart":null,"trialEnd":null,"acct":null},"serverTime":5}""".trimMargin(),
                422,
            ),
        )
        val r = client.licenseSync(LicenseSyncRequest("android", "app", "1", "k"))
        assertEquals("t.t.t", r.response.token)
        assertEquals(BackendError.Api(422, "store_verification_failed", "Some purchases could not be verified."), r.partialError)
        server.enqueue(json("""{"error":"store_unavailable","message":"x","token":"a.b.c","license":{"purchased":true},"serverTime":5}""", 503).addHeader("Retry-After", "60"))
        val r2 = client.licenseSync(LicenseSyncRequest("android", "app", "1", "k"))
        assertEquals(BackendError.ServerError(503, "store_unavailable"), r2.partialError)
        assertTrue(r2.response.license.purchased)
        server.enqueue(json("""{"error":"invalid_request","message":"'deviceKey' is required."}""", 400))
        assertEquals(
            BackendError.Api(400, "invalid_request", "'deviceKey' is required."),
            backendError { client.licenseSync(LicenseSyncRequest("android", "app", "1", "")) },
        )
    }

    @Test
    fun errorMapping(): Unit = runBlocking {
        server.enqueue(json("""{"error":"unauthorized","message":"Authentication required."}""", 401))
        assertEquals(BackendError.Unauthorized("unauthorized"), backendError { client.account(session) })
        server.enqueue(json("""{"error":"rate_limited","message":"slow"}""", 429).addHeader("Retry-After", "30"))
        val rl = backendError { client.emailStart("a@b.c", "tr") }
        assertEquals(BackendError.RateLimited(30, "rate_limited"), rl)
        assertTrue(rl.isRetryable)
        server.enqueue(json("""{"error":"invalid_code","message":"The code is invalid."}""", 400))
        assertEquals(BackendError.Api(400, "invalid_code", "The code is invalid."), backendError { client.emailVerify("a@b.c", "000000", "TV") })
        server.enqueue(json("""{"error":"feature_disabled","message":"off"}""", 403))
        assertEquals("api:403:feature_disabled", backendError { client.syncPull(session, 0) }.code)
        server.enqueue(MockResponse().setResponseCode(502).setBody("<html>Bad gateway</html>"))
        assertEquals(BackendError.ServerError(502), backendError { client.config() })
        server.enqueue(MockResponse().setResponseCode(404).setBody("not json"))
        assertEquals(BackendError.ServerError(404), backendError { client.config() }, "non-2xx without API body")
        server.enqueue(MockResponse().setBody("<html>captive portal</html>"))
        assertEquals(BackendError.InvalidResponse, backendError { client.config() })
        server.enqueue(json("""{"unexpected":true}"""))
        assertEquals(BackendError.InvalidResponse, backendError { client.emailVerify("a@b.c", "1", "d") }, "missing required fields")
        server.enqueue(MockResponse().setSocketPolicy(SocketPolicy.NO_RESPONSE))
        val timeout = backendError { client.config() }
        assertEquals(BackendError.Network(NetworkReason.TIMEOUT), timeout)
        assertTrue(timeout.isRetryable)
        assertEquals(9, server.requestCount, "no automatic retries")
    }

    @Test
    fun networkReasons(): Unit = runBlocking {
        val noDns = MockServerSupport.NO_DNS
        val dnsClient = BackendClient("https://backend.invalid", MockServerSupport.fastClient(dns = noDns))
        assertEquals(BackendError.Network(NetworkReason.DNS), backendError { dnsClient.config() })
        val offline = BackendClient("https://backend.invalid", MockServerSupport.fastClient(dns = noDns), connectivity = ConnectivityProbe { true })
        val e = backendError { offline.config() }
        assertEquals(BackendError.Network(NetworkReason.OFFLINE), e)
        assertFalse(e.isRetryable)
        val url = server.url("/").toString()
        server.shutdown()
        assertEquals(BackendError.Network(NetworkReason.REFUSED), backendError { BackendClient(url, MockServerSupport.fastClient()).config() })
    }

    @Test
    fun accountsAndDeviceFlow(): Unit = runBlocking {
        server.enqueue(json("""{"ok":true,"devCode":"123456"}"""))
        assertEquals("123456", client.emailStart("a@b.c", "tr").devCode)
        server.enqueue(json("""{"sessionToken":"s1","account":{"id":"acc_1","email":"a@b.c"}}"""))
        val s = client.emailVerify("a@b.c", "123456", "Pixel")
        assertEquals("acc_1", s.account.id)
        assertFalse(s.toString().contains("s1"))
        server.enqueue(json("""{"id":"acc_1","email":"a@b.c","createdAt":1,"licenses":[{"store":"google","status":"active","purchasedAt":2,"productId":"lifetime_access"}],"trial":{"start":10,"end":20}}"""))
        val acc = client.account("s1")
        assertEquals(AccountTrial(10, 20), acc.trial)
        assertEquals("google", acc.licenses.single().store)
        server.enqueue(json("""{"ok":true}"""))
        client.logout("s1")
        server.enqueue(json("""{"ok":true}"""))
        client.deleteAccount("s1")
        val methods = List(5) { server.takeRequest().method }
        assertEquals(listOf("POST", "POST", "GET", "POST", "DELETE"), methods)
        server.enqueue(json("""{"deviceCode":"dc","userCode":"ABCD-EFGH","verificationUrl":"https://x/link","verificationUrlComplete":"https://x/link?c=ABCDEFGH","interval":5,"expiresIn":600}"""))
        val start = client.deviceStart(BackendPlatform.ANDROID_TV, "Living room")
        assertEquals("ABCD-EFGH", start.userCode)
        server.enqueue(json("""{"error":"authorization_pending","message":"Waiting"}""", 428))
        assertEquals(DevicePollResult.Pending, client.devicePoll("dc"))
        server.enqueue(json("""{"error":"slow_down","message":"x","interval":5}""", 429))
        assertEquals(DevicePollResult.SlowDown(5), client.devicePoll("dc"))
        server.enqueue(json("""{"error":"expired_token","message":"x"}""", 410))
        assertEquals(DevicePollResult.Expired, client.devicePoll("dc"))
        server.enqueue(json("""{"sessionToken":"s2","account":{"id":"acc_1","email":"a@b.c"}}"""))
        assertEquals("s2", assertIs<DevicePollResult.Approved>(client.devicePoll("dc")).session.sessionToken)
        server.enqueue(json("""{"ok":true}"""))
        client.deviceApprove("s1", "ABCD-EFGH")
        server.enqueue(json("""{"error":"rate_limited","message":"x"}""", 429))
        assertIs<BackendError.RateLimited>(backendError { client.devicePoll("dc") }, "429 without slow_down is a plain rate limit")
    }

    @Test
    fun syncPullAndPush(): Unit = runBlocking {
        val ck = "d11e55fa87364ff0:movie:5001"
        server.enqueue(
            json(
                """{"items":[
                |{"key":"fav:$ck","kind":"favorite","data":{"title":"Inception","contentKind":"movie"},"updatedAt":10,"deleted":false,"seq":1},
                |{"key":"prog:$ck","kind":"progress","data":{"title":"Inception","contentKind":"movie","positionMs":5,"durationMs":10},"updatedAt":11,"deleted":false,"seq":2},
                |{"key":"bogus","kind":"favorite","data":{},"updatedAt":12,"seq":3},
                |{"kind":"nope"}],"cursor":3,"hasMore":true}""".trimMargin(),
            ),
        )
        val page = client.syncPull(session, since = 0)
        assertEquals(2, page.items.size)
        assertEquals(2, page.skipped)
        assertEquals(3L, page.cursor)
        assertTrue(page.hasMore)
        assertEquals(2L, page.items[1].seq)
        assertEquals("/v1/sync?since=0&limit=500", server.takeRequest().path)

        server.enqueue(json("""{"applied":1,"cursor":4,"rejected":[{"key":"fav:x","reason":"invalid_key"}]}"""))
        val pushed = client.syncPush(session, listOf(SyncItem.favorite(ck, "Inception", ContentKind.MOVIE, null, 20).copy(seq = 99)))
        assertEquals(1, pushed.applied)
        assertEquals("invalid_key", pushed.rejected.single().reason)
        val sent = Json.parseToJsonElement(server.takeRequest().body.readUtf8()).jsonObject.getValue("items").jsonArray.single().jsonObject
        assertFalse(sent.containsKey("seq"), "seq is server-only")
        assertEquals("fav:$ck", sent.getValue("key").jsonPrimitive.content)
        assertFailsWith<IllegalArgumentException> { client.syncPush(session, List(501) { SyncItem.favorite("$it", "t", ContentKind.LIVE, null, 1) }) }
    }

    @Test
    fun pairingEndpoints(): Unit = runBlocking {
        val jwk = EcPublicJwk(x = "eg6jmM7r9ZWlHuODNLnDYC2uKnBJRyTmMQgN5xQTSqU", y = "P8Bd87gq4iiYweVi2K5pQinz3vmwaLssw0NQtqo8O1w")
        server.enqueue(json("""{"code":"ABC234","secret":"sec ret","expiresAt":1759570600000,"expiresIn":600,"pairUrl":"https://x/pair?c=ABC234"}"""))
        val session = client.pairCreate(jwk)
        assertEquals("ABC234", session.code)
        assertFalse(session.toString().contains("sec ret"))
        val created = Json.parseToJsonElement(server.takeRequest().body.readUtf8()).jsonObject
        assertEquals(jwk, CoreJson.decodeFromJsonElement(EcPublicJwk.serializer(), created.getValue("publicKey")))

        server.enqueue(json("""{"status":"pending"}""", 202))
        assertEquals(PairPollResult.Pending, client.pairPoll("abc-234", "sec ret"))
        assertEquals("/v1/pair/sessions/ABC234?secret=sec%20ret", server.takeRequest().path)
        val envelope = CoreJson.decodeFromJsonElement(PairEnvelope.serializer(), Vectors.json("pair-crypto.json").jsonObject.getValue("payload"))
        server.enqueue(json(CoreJson.encodeToString(PairEnvelope.serializer(), envelope)))
        assertEquals(PairPollResult.Ready(envelope), client.pairPoll("ABC234", "sec ret"))
        server.enqueue(json("""{"error":"expired","message":"x"}""", 410))
        assertEquals(PairPollResult.Expired, client.pairPoll("ABC234", "s"))
        server.enqueue(json("""{"error":"not_found","message":"x"}""", 404))
        assertEquals(PairPollResult.NotFound, client.pairPoll("ABC234", "s"))
        repeat(3) { server.takeRequest() }

        server.enqueue(json("""{"publicKey":{"kty":"EC","crv":"P-256","x":"${jwk.x}","y":"${jwk.y}"},"expiresAt":1}"""))
        assertEquals(jwk, client.pairKey("abc234").publicKey)
        assertEquals("/v1/pair/sessions/ABC234/key", server.takeRequest().path)
        server.enqueue(json("""{"ok":true}"""))
        client.pairSend("ABC234", envelope)
        server.enqueue(json("""{"error":"already_used","message":"x"}""", 409))
        assertEquals(BackendError.Api(409, "already_used", "x"), backendError { client.pairSend("ABC234", envelope) })
    }
}
