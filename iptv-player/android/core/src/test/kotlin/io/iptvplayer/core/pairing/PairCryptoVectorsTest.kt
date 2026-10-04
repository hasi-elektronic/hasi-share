package io.iptvplayer.core.pairing

import io.iptvplayer.core.CoreJson
import io.iptvplayer.core.Vectors
import io.iptvplayer.core.crypto.EcKeys
import io.iptvplayer.core.crypto.EcPrivateJwk
import io.iptvplayer.core.crypto.EcPublicJwk
import io.iptvplayer.core.model.SourceSecrets
import io.iptvplayer.core.util.Base64Codec
import io.iptvplayer.core.util.Hex
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/** CONTRACT §9 against pair-crypto.json (decrypt + deterministic encrypt). */
class PairCryptoVectorsTest {
    private val root: JsonObject = Vectors.json("pair-crypto.json").jsonObject

    private fun priv(k: String) = CoreJson.decodeFromJsonElement(EcPrivateJwk.serializer(), root.getValue(k))

    private fun pub(k: String) = CoreJson.decodeFromJsonElement(EcPublicJwk.serializer(), root.getValue(k))

    private fun s(k: String) = root.getValue(k).jsonPrimitive.content

    private val envelope: PairEnvelope get() = CoreJson.decodeFromJsonElement(PairEnvelope.serializer(), root.getValue("payload"))

    @Test
    fun sharedSecretAndKeyDerivation() {
        val tv = EcKeys.keyPair(priv("tvPrivateJwk"))
        val sender = EcKeys.keyPair(priv("senderPrivateJwk"))
        assertEquals(s("sharedSecretHex"), Hex.encode(PairCrypto.sharedSecret(sender.private, tv.public)))
        // ECDH is symmetric: the TV derives the same secret.
        assertEquals(s("sharedSecretHex"), Hex.encode(PairCrypto.sharedSecret(tv.private, sender.public)))
        assertEquals(s("aesKeyHex"), Hex.encode(PairCrypto.deriveKey(tv.private, sender.public)))
        assertEquals(pub("tvPublicJwk"), EcKeys.jwk(tv.public as java.security.interfaces.ECPublicKey))
        assertEquals(priv("tvPrivateJwk"), EcKeys.privateJwk(tv))
    }

    @Test
    fun tvDecryptsVectorPayload() {
        val tv = EcKeys.keyPair(priv("tvPrivateJwk"))
        assertEquals(pub("senderPublicJwk"), envelope.epk)
        val plain = PairCrypto.decrypt(envelope, tv.private).decodeToString()
        assertEquals(s("plaintext"), plain)
        val payload = PairCrypto.open(envelope, tv.private)
        val x = payload as PairPayload.Xtream
        assertEquals("Ev", x.name)
        assertEquals("http://iptv.example.com:8080", x.server)
        assertEquals("user1", x.username)
        assertEquals("p@ss/w rd çğ", x.password)
        assertEquals(SourceSecrets.Xtream("http://iptv.example.com:8080", "user1", "p@ss/w rd çğ"), x.secrets)
        assertFalse(x.toString().contains("p@ss"), "toString hides secrets")
    }

    @Test
    fun deterministicEncryptMatchesVector() {
        val sender = EcKeys.keyPair(priv("senderPrivateJwk"))
        val iv = Base64Codec.decode(envelope.iv)!!
        val out = PairCrypto.encrypt(s("plaintext").encodeToByteArray(), pub("tvPublicJwk"), sender, iv)
        assertEquals(envelope, out)
    }

    @Test
    fun randomRoundTripAndTamperDetection() {
        val tv = PairCrypto.generateKeyPair()
        val payload = PairPayload.M3u("Liste", "http://lists.example.com/a.m3u?token=1", "http://epg.example.com/e.xml.gz")
        val env = PairCrypto.encrypt(payload.toJson().encodeToByteArray(), PairCrypto.publicJwk(tv))
        assertEquals(payload, PairCrypto.open(env, tv.private))
        // Flip one ciphertext bit → GCM tag failure.
        val ct = Base64Codec.decode(env.ct)!!
        ct[0] = (ct[0].toInt() xor 1).toByte()
        val e = assertFailsWith<PairCryptoException> { PairCrypto.decrypt(env.copy(ct = Base64Codec.encodeUrl(ct)), tv.private) }
        assertEquals(PairCryptoFailure.DECRYPTION_FAILED, e.failure)
        // Wrong recipient key.
        assertEquals(
            PairCryptoFailure.DECRYPTION_FAILED,
            assertFailsWith<PairCryptoException> { PairCrypto.decrypt(env, PairCrypto.generateKeyPair().private) }.failure,
        )
        // Bad iv length / bad epk.
        assertEquals(PairCryptoFailure.INVALID_ENVELOPE, assertFailsWith<PairCryptoException> { PairCrypto.decrypt(env.copy(iv = "AAAA"), tv.private) }.failure)
        assertEquals(
            PairCryptoFailure.INVALID_KEY,
            assertFailsWith<PairCryptoException> { PairCrypto.decrypt(env.copy(epk = env.epk.copy(y = env.epk.x)), tv.private) }.failure,
        )
    }

    @Test
    fun payloadParsing() {
        assertEquals(PairPayload.M3u("", "http://a/b.m3u", null), PairPayload.parse("""{"type":"m3u","url":"http://a/b.m3u","epgUrl":""}"""))
        for (bad in listOf("""{"v":2,"type":"m3u","url":"x"}""", """{"v":1,"type":"zip"}""", """{"v":1,"type":"xtream","server":"s"}""", "nope")) {
            assertEquals(PairCryptoFailure.INVALID_PAYLOAD, assertFailsWith<PairCryptoException> { PairPayload.parse(bad) }.failure, bad)
        }
        val x = PairPayload.Xtream("n", "s", "u", "p")
        assertEquals(x, PairPayload.parse(x.toJson()))
    }

    @Test
    fun pairCodes() {
        assertEquals("ABC-123", PairCode.display("abc123"))
        assertEquals("ABC234", PairCode.normalize(" abc-234 "))
        assertTrue(PairCode.isValid("abc-234"))
        assertFalse(PairCode.isValid("ABC-120"), "0 and 1 are not in the alphabet")
        assertFalse(PairCode.isValid("ABCD"))
    }

    @Test
    fun hkdfRfc5869TestCase1() {
        val ikm = Hex.decode("0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b")
        val salt = Hex.decode("000102030405060708090a0b0c")
        val info = Hex.decode("f0f1f2f3f4f5f6f7f8f9")
        assertEquals(
            "3cb25f25faacd57a90434f64d0362f2a2d2d0a90cf1a5a4c5db02d56ecc4c5bf34007208d5b887185865",
            Hex.encode(PairCrypto.hkdfSha256(ikm, salt, info, 42)),
        )
    }
}
