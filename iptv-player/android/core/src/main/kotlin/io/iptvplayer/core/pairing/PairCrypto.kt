package io.iptvplayer.core.pairing

import io.iptvplayer.core.CoreConstants
import io.iptvplayer.core.crypto.EcKeys
import io.iptvplayer.core.crypto.EcPublicJwk
import io.iptvplayer.core.model.SourceSecrets
import io.iptvplayer.core.util.Base64Codec
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import java.security.KeyPair
import java.security.PrivateKey
import java.security.PublicKey
import java.security.SecureRandom
import java.security.interfaces.ECPublicKey
import javax.crypto.Cipher
import javax.crypto.KeyAgreement
import javax.crypto.Mac
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

/** Wire envelope of a pairing payload (`POST …/payload`, 200 body of the TV poll). */
@Serializable
public data class PairEnvelope(
    /** Sender's ephemeral public key. */
    val epk: EcPublicJwk,
    /** 12-byte GCM nonce, base64url. */
    val iv: String,
    /** Ciphertext ‖ 16-byte tag, base64url. */
    val ct: String,
)

/** Failure kinds of [PairCrypto]. */
public enum class PairCryptoFailure { INVALID_KEY, INVALID_ENVELOPE, DECRYPTION_FAILED, INVALID_PAYLOAD }

/** Thrown by [PairCrypto] / [PairPayload.parse]. */
public class PairCryptoException(public val failure: PairCryptoFailure, cause: Throwable? = null) :
    Exception(failure.name, cause)

/**
 * End-to-end encryption of TV pairing (CONTRACT §9), JCA only:
 * `Z = ECDH(e.priv, tv.pub)` (32-byte x), `K = HKDF-SHA256(ikm=Z, salt=empty,
 * info="iptvp-pair-v1", L=32)`, `ct = AES-256-GCM(K, iv=12 bytes)` with the 16-byte tag appended.
 */
public object PairCrypto {
    private const val IV_BYTES = 12
    private const val TAG_BITS = 128

    /** The TV's ephemeral key pair (keep it in memory only). */
    public fun generateKeyPair(): KeyPair = EcKeys.generateKeyPair()

    /** Public JWK to send in `POST /v1/pair/sessions`. */
    public fun publicJwk(pair: KeyPair): EcPublicJwk = EcKeys.jwk(pair.public as ECPublicKey)

    /** Raw ECDH shared secret Z (x coordinate, 32 bytes). */
    public fun sharedSecret(privateKey: PrivateKey, peer: PublicKey): ByteArray = try {
        KeyAgreement.getInstance("ECDH").run {
            init(privateKey)
            doPhase(peer, true)
            generateSecret()
        }
    } catch (e: Exception) {
        throw PairCryptoException(PairCryptoFailure.INVALID_KEY, e)
    }

    /** HKDF-SHA256 (RFC 5869) with [salt] (empty → 32 zero bytes) producing [length] bytes. */
    public fun hkdfSha256(ikm: ByteArray, salt: ByteArray, info: ByteArray, length: Int): ByteArray {
        require(length in 1..255 * 32)
        val mac = Mac.getInstance("HmacSHA256")
        mac.init(SecretKeySpec(if (salt.isEmpty()) ByteArray(32) else salt, "HmacSHA256"))
        val prk = mac.doFinal(ikm)
        mac.init(SecretKeySpec(prk, "HmacSHA256"))
        val out = ByteArray(length)
        var t = ByteArray(0)
        var pos = 0
        var counter = 1
        while (pos < length) {
            mac.update(t)
            mac.update(info)
            mac.update(counter.toByte())
            t = mac.doFinal()
            val n = minOf(t.size, length - pos)
            System.arraycopy(t, 0, out, pos, n)
            pos += n
            counter++
        }
        return out
    }

    /** AES-256 key K for [privateKey] and [peer]. */
    public fun deriveKey(privateKey: PrivateKey, peer: PublicKey): ByteArray =
        hkdfSha256(sharedSecret(privateKey, peer), ByteArray(0), CoreConstants.PAIR_HKDF_INFO.encodeToByteArray(), 32)

    /**
     * Encrypts [plaintext] for the TV's public key (what the pairing web page does).
     * [ephemeral] and [iv] are injectable for deterministic tests.
     */
    public fun encrypt(
        plaintext: ByteArray,
        recipient: EcPublicJwk,
        ephemeral: KeyPair = EcKeys.generateKeyPair(),
        iv: ByteArray = ByteArray(IV_BYTES).also { SecureRandom().nextBytes(it) },
    ): PairEnvelope {
        if (iv.size != IV_BYTES) throw PairCryptoException(PairCryptoFailure.INVALID_ENVELOPE)
        val peer = publicKey(recipient)
        val key = deriveKey(ephemeral.private, peer)
        val ct = Cipher.getInstance("AES/GCM/NoPadding").run {
            init(Cipher.ENCRYPT_MODE, SecretKeySpec(key, "AES"), GCMParameterSpec(TAG_BITS, iv))
            doFinal(plaintext) // JCA appends the tag
        }
        return PairEnvelope(EcKeys.jwk(ephemeral.public as ECPublicKey), Base64Codec.encodeUrl(iv), Base64Codec.encodeUrl(ct))
    }

    /** Decrypts [envelope] with the TV's [privateKey]. */
    public fun decrypt(envelope: PairEnvelope, privateKey: PrivateKey): ByteArray {
        val iv = Base64Codec.decode(envelope.iv)?.takeIf { it.size == IV_BYTES }
            ?: throw PairCryptoException(PairCryptoFailure.INVALID_ENVELOPE)
        val ct = Base64Codec.decode(envelope.ct)?.takeIf { it.size >= 16 }
            ?: throw PairCryptoException(PairCryptoFailure.INVALID_ENVELOPE)
        val key = deriveKey(privateKey, publicKey(envelope.epk))
        return try {
            Cipher.getInstance("AES/GCM/NoPadding").run {
                init(Cipher.DECRYPT_MODE, SecretKeySpec(key, "AES"), GCMParameterSpec(TAG_BITS, iv))
                doFinal(ct)
            }
        } catch (e: Exception) {
            throw PairCryptoException(PairCryptoFailure.DECRYPTION_FAILED, e)
        }
    }

    /** Decrypts and parses the pairing payload. */
    public fun open(envelope: PairEnvelope, privateKey: PrivateKey): PairPayload =
        PairPayload.parse(decrypt(envelope, privateKey).decodeToString())

    private fun publicKey(jwk: EcPublicJwk): PublicKey = try {
        EcKeys.publicKey(jwk)
    } catch (e: Exception) {
        throw PairCryptoException(PairCryptoFailure.INVALID_KEY, e)
    }
}

/** Plaintext of a pairing payload (CONTRACT §9.5), version 1. [toString] hides secrets. */
public sealed class PairPayload {
    /** Display name of the new source. */
    public abstract val name: String

    /** M3U source. */
    public data class M3u(override val name: String, val url: String, val epgUrl: String? = null) : PairPayload() {
        override fun toString(): String = "PairPayload.M3u(name=$name, url=***)"
    }

    /** Xtream source. */
    public data class Xtream(
        override val name: String,
        val server: String,
        val username: String,
        val password: String,
    ) : PairPayload() {
        override fun toString(): String = "PairPayload.Xtream(name=$name, server=***, username=***, password=***)"
    }

    /** Secrets to store (Keystore-encrypted) for the new source. */
    public val secrets: SourceSecrets
        get() = when (this) {
            is M3u -> SourceSecrets.M3u(url = url, epgUrl = epgUrl)
            is Xtream -> SourceSecrets.Xtream(serverUrl = server, username = username, password = password)
        }

    /** Wire JSON (`{"v":1,"type":…}`). */
    public fun toJson(): String = buildJsonObject {
        put("v", 1)
        when (val p = this@PairPayload) {
            is M3u -> {
                put("type", "m3u")
                put("name", p.name)
                put("url", p.url)
                p.epgUrl?.let { put("epgUrl", it) }
            }
            is Xtream -> {
                put("type", "xtream")
                put("name", p.name)
                put("server", p.server)
                put("username", p.username)
                put("password", p.password)
            }
        }
    }.toString()

    public companion object {
        private val JSON = Json { ignoreUnknownKeys = true }

        /** Parses the decrypted JSON. @throws PairCryptoException INVALID_PAYLOAD */
        public fun parse(json: String): PairPayload {
            fun bad(e: Throwable? = null): Nothing = throw PairCryptoException(PairCryptoFailure.INVALID_PAYLOAD, e)
            val o: JsonObject = try {
                JSON.parseToJsonElement(json).jsonObject
            } catch (e: Exception) {
                bad(e)
            }
            fun str(k: String): String? = try {
                o[k]?.jsonPrimitive?.contentOrNull
            } catch (_: Exception) {
                null
            }
            val v = try {
                o["v"]?.jsonPrimitive?.int ?: 1
            } catch (e: Exception) {
                bad(e)
            }
            if (v != 1) bad()
            val name = str("name") ?: ""
            return when (str("type")) {
                "m3u" -> M3u(name, str("url")?.takeIf { it.isNotBlank() } ?: bad(), str("epgUrl")?.takeIf { it.isNotBlank() })
                "xtream" -> Xtream(
                    name,
                    str("server")?.takeIf { it.isNotBlank() } ?: bad(),
                    str("username") ?: bad(),
                    str("password") ?: bad(),
                )
                else -> bad()
            }
        }
    }
}

/** Pairing code helpers (6 chars from [ALPHABET], shown as `ABC-123`). */
public object PairCode {
    public const val ALPHABET: String = "ABCDEFGHJKMNPQRSTUVWXYZ23456789"

    /** Uppercases and strips separators / whitespace (`abc-123` → `ABC123`). */
    public fun normalize(input: String): String = input.uppercase(java.util.Locale.ROOT).filter { it.isLetterOrDigit() }

    /** `ABC123` → `ABC-123`. */
    public fun display(code: String): String {
        val c = normalize(code)
        return if (c.length == 6) c.substring(0, 3) + "-" + c.substring(3) else c
    }

    /** True for a well-formed 6-character code. */
    public fun isValid(input: String): Boolean {
        val c = normalize(input)
        return c.length == 6 && c.all { it in ALPHABET }
    }
}
