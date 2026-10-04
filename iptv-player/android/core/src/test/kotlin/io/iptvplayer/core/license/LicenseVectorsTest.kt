package io.iptvplayer.core.license

import io.iptvplayer.core.CoreJson
import io.iptvplayer.core.TestJson
import io.iptvplayer.core.Vectors
import io.iptvplayer.core.assertJsonEquals
import io.iptvplayer.core.crypto.EcKeys
import io.iptvplayer.core.crypto.EcPrivateJwk
import io.iptvplayer.core.crypto.EcPublicJwk
import io.iptvplayer.core.crypto.Es256
import io.iptvplayer.core.util.Base64Codec
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.long
import kotlinx.serialization.json.longOrNull
import kotlinx.serialization.json.put
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertIs
import kotlin.test.assertNull
import kotlin.test.assertTrue
import kotlin.test.fail

/** CONTRACT §7.2–§7.4 against license-token.json, trusted-clock.json, access-policy.json. */
class LicenseVectorsTest {
    private val tokenRoot = Vectors.json("license-token.json").jsonObject

    private fun verifier(): LicenseTokenVerifier {
        val keys = tokenRoot.getValue("keys").jsonObject.mapValues { (_, v) -> CoreJson.decodeFromJsonElement(EcPublicJwk.serializer(), v) }
        return LicenseTokenVerifier(keys, audience = tokenRoot.getValue("audience").jsonPrimitive.content)
    }

    @Test
    fun licenseTokens() {
        assertEquals("iptvp-license", tokenRoot.getValue("issuer").jsonPrimitive.content)
        val v = verifier()
        assertEquals("iptvp-license", v.issuer)
        val cases = tokenRoot.getValue("cases").jsonArray
        assertEquals(10, cases.size)
        for (c in cases.map { it.jsonObject }) {
            val name = c.getValue("name").jsonPrimitive.content
            val result = v.verify(c.getValue("token").jsonPrimitive.content, c.getValue("nowEpochSeconds").jsonPrimitive.long)
            val actual = when (result) {
                is LicenseVerification.Valid -> buildJsonObject {
                    put("valid", true)
                    put("stale", result.stale)
                    put("claims", TestJson.encodeToJsonElement(LicenseClaims.serializer(), result.claims))
                }
                is LicenseVerification.Invalid -> buildJsonObject {
                    put("valid", false)
                    put("reason", result.reason.wire)
                }
            }
            assertJsonEquals(c.getValue("expected"), actual, name)
        }
    }

    @Test
    fun signAndVerifyRoundTripWithBackendKey() {
        val priv = tokenRoot.getValue("privateKeyForBackendTests").jsonObject
        val jwk = CoreJson.decodeFromJsonElement(EcPrivateJwk.serializer(), priv.getValue("jwk"))
        val pair = EcKeys.keyPair(jwk)
        val header = Base64Codec.encodeUrl("""{"alg":"ES256","kid":"test-1","typ":"JWT"}""".encodeToByteArray())
        val payload = Base64Codec.encodeUrl(
            """{"iss":"iptvp-license","aud":"de.hasielektronik.novaplayer","sub":"x","iat":10,"exp":20,"lic":{"purchased":true,"src":"admin","trialStart":null,"trialEnd":null,"acct":null}}"""
                .encodeToByteArray(),
        )
        val sig = Es256.sign(pair.private as java.security.interfaces.ECPrivateKey, "$header.$payload".encodeToByteArray())
        assertEquals(64, sig.size)
        val token = "$header.$payload.${Base64Codec.encodeUrl(sig)}"
        val ok = assertIs<LicenseVerification.Valid>(verifier().verify(token, 15))
        assertFalse(ok.stale)
        assertEquals(LicenseInfo(purchased = true, src = LicenseSrc.ADMIN), ok.claims.lic)
        assertTrue(assertIs<LicenseVerification.Valid>(verifier().verify(token, 20)).stale, "exp reached = stale")
        // DER round trip.
        assertTrue(sig.contentEquals(Es256.derToRaw(Es256.rawToDer(sig))))
        // Truncated signature / wrong length is a signature failure, not a crash.
        assertEquals(
            LicenseVerification.Invalid(LicenseTokenFailure.SIGNATURE),
            verifier().verify("$header.$payload.${Base64Codec.encodeUrl(sig.copyOf(63))}", 15),
        )
        assertNull(verifier().claimsOrNull("not.a.token!", 0))
    }

    @Test
    fun jwkSetShapes() {
        val x = "1mZSl5DlTBlGPZy7C3MOMolrHsu5lPP-LqcXvghmRQI"
        val y = "bXxHgwdgkp-Xrru35KYQv97qM2OgRRllDuada1qBxBU"
        val jwk = """{"kty":"EC","crv":"P-256","x":"$x","y":"$y"}"""
        val expected = mapOf("k1" to EcPublicJwk(x = x, y = y))
        assertEquals(expected, LicenseTokenVerifier.parseJwkSet("""{"k1":$jwk}"""))
        assertEquals(expected, LicenseTokenVerifier.parseJwkSet("""{"keys":{"k1":$jwk}}"""))
        assertEquals(expected, LicenseTokenVerifier.parseJwkSet("""{"keys":[{"kid":"k1","kty":"EC","crv":"P-256","x":"$x","y":"$y","use":"sig"}]}"""))
        assertFailsWith<IllegalArgumentException> { LicenseTokenVerifier.parseJwkSet("{}") }
        // A point not on the curve is rejected (ignored by the verifier).
        val bad = LicenseTokenVerifier(mapOf("k" to EcPublicJwk(x = x, y = x)), "a")
        assertEquals(emptySet(), bad.keyIds)
    }

    @Test
    fun trustedClock() {
        val root = Vectors.json("trusted-clock.json").jsonObject
        fun state(o: kotlinx.serialization.json.JsonElement): TrustedClockState? =
            if (o is JsonNull) null else CoreJson.decodeFromJsonElement(TrustedClockState.serializer(), o)
        val cases = root.getValue("cases").jsonArray
        assertEquals(7, cases.size)
        for (c in cases.map { it.jsonObject }) {
            val now = TrustedClock.now(
                state(c.getValue("state")),
                c.getValue("wallMs").jsonPrimitive.long,
                c.getValue("monoMs").jsonPrimitive.long,
                c.getValue("bootId").jsonPrimitive.content,
            )
            assertEquals(c.getValue("expected").jsonPrimitive.long, now, c.getValue("name").jsonPrimitive.content)
        }
        val updates = root.getValue("updates").jsonArray
        assertEquals(2, updates.size)
        for (u in updates.map { it.jsonObject }) {
            val next = TrustedClock.update(state(u.getValue("state")), state(u.getValue("update"))!!)
            assertEquals(state(u.getValue("expectedState")), next, u.getValue("name").jsonPrimitive.content)
        }
        val first = TrustedClockState(1, 2, "b")
        assertEquals(first, TrustedClock.update(null, first))
    }

    @Test
    fun accessPolicy() {
        val cases = Vectors.json("access-policy.json").jsonObject.getValue("cases").jsonArray
        assertEquals(14, cases.size)
        for (c in cases.map { it.jsonObject }) {
            val name = c.getValue("name").jsonPrimitive.content
            val i = c.getValue("input").jsonObject
            val token = i.getValue("token").let { if (it is JsonNull) null else CoreJson.decodeFromJsonElement(LicenseInfo.serializer(), it) }
            val d = AccessPolicy.evaluate(
                platformStore = PlatformStore.fromWire(i.getValue("platformStore").jsonPrimitive.content),
                store = StoreState.fromWire(i.getValue("store").jsonPrimitive.content),
                token = token,
                localTrialStartMs = i.getValue("localTrialStartMs").jsonPrimitive.longOrNull,
                trialDays = i.getValue("trialDays").jsonPrimitive.int,
                nowMs = i.getValue("nowMs").jsonPrimitive.long,
            )
            val actual = JsonObject(
                mapOf(
                    "state" to JsonPrimitive(d.state.name),
                    "trialEndMs" to (d.trialEndMs?.let { JsonPrimitive(it) } ?: JsonNull),
                    "canPlay" to JsonPrimitive(d.canPlay),
                    "pendingPurchase" to JsonPrimitive(d.pendingPurchase),
                ),
            )
            assertJsonEquals(c.getValue("expected"), actual, name)
        }
    }

    @Test
    fun unknownWireValuesFail() {
        assertFailsWith<NoSuchElementException> { StoreState.fromWire("bogus") }
        if (PlatformStore.entries.size != 2) fail("two platform stores")
    }
}
