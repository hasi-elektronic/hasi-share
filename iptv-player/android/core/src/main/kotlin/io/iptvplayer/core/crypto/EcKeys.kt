package io.iptvplayer.core.crypto

import io.iptvplayer.core.util.Base64Codec
import kotlinx.serialization.Serializable
import java.math.BigInteger
import java.security.KeyFactory
import java.security.KeyPair
import java.security.KeyPairGenerator
import java.security.SecureRandom
import java.security.Signature
import java.security.interfaces.ECPrivateKey
import java.security.interfaces.ECPublicKey
import java.security.spec.ECGenParameterSpec
import java.security.spec.ECParameterSpec
import java.security.spec.ECPoint
import java.security.spec.ECPrivateKeySpec
import java.security.spec.ECPublicKeySpec

/** Public EC P-256 JWK `{kty:"EC", crv:"P-256", x, y}` (base64url, 32 bytes each). */
@Serializable
public data class EcPublicJwk(
    val kty: String = "EC",
    val crv: String = "P-256",
    val x: String,
    val y: String,
)

/** Private EC P-256 JWK (`d` = private scalar). Tests / diagnostics only. */
@Serializable
public data class EcPrivateJwk(
    val kty: String = "EC",
    val crv: String = "P-256",
    val x: String,
    val y: String,
    val d: String,
) {
    /** The public half. */
    val publicJwk: EcPublicJwk get() = EcPublicJwk(kty, crv, x, y)

    override fun toString(): String = "EcPrivateJwk(x=$x, y=$y, d=***)"
}

/** Thrown for malformed / unsupported keys. */
public class InvalidKeyException(message: String, cause: Throwable? = null) : Exception(message, cause)

/**
 * P-256 key helpers on plain JCA (`java.security`), available on every Android API level
 * (no `AlgorithmParameters("EC")`, no `SHA256withECDSAinP1363Format`).
 */
public object EcKeys {
    private const val COORD = 32

    /** secp256r1 parameters, taken from a generated key (portable across JCA providers). */
    public val P256: ECParameterSpec by lazy { (generateKeyPair().public as ECPublicKey).params }

    /** Generates a fresh P-256 key pair. */
    public fun generateKeyPair(random: SecureRandom = SecureRandom()): KeyPair =
        KeyPairGenerator.getInstance("EC").apply { initialize(ECGenParameterSpec("secp256r1"), random) }.generateKeyPair()

    /** JCA public key from a JWK. @throws InvalidKeyException */
    public fun publicKey(jwk: EcPublicJwk): ECPublicKey {
        if (jwk.kty != "EC" || jwk.crv != "P-256") throw InvalidKeyException("unsupported key type ${jwk.kty}/${jwk.crv}")
        val x = Base64Codec.decode(jwk.x)?.takeIf { it.size == COORD } ?: throw InvalidKeyException("bad x")
        val y = Base64Codec.decode(jwk.y)?.takeIf { it.size == COORD } ?: throw InvalidKeyException("bad y")
        val point = ECPoint(BigInteger(1, x), BigInteger(1, y))
        if (!isOnCurve(point)) throw InvalidKeyException("point not on P-256") // invalid-curve attacks
        return try {
            val spec = ECPublicKeySpec(point, P256)
            KeyFactory.getInstance("EC").generatePublic(spec) as ECPublicKey
        } catch (e: Exception) {
            throw InvalidKeyException("invalid public key", e)
        }
    }

    /** True when [p] satisfies `y² = x³ + ax + b (mod p)` on P-256 with coordinates in range. */
    public fun isOnCurve(p: ECPoint): Boolean {
        val curve = P256.curve
        val prime = (curve.field as java.security.spec.ECFieldFp).p
        val x = p.affineX
        val y = p.affineY
        if (x.signum() < 0 || y.signum() < 0 || x >= prime || y >= prime) return false
        val lhs = y.multiply(y).mod(prime)
        val rhs = x.pow(3).add(curve.a.multiply(x)).add(curve.b).mod(prime)
        return lhs == rhs
    }

    /** JCA private key from a JWK. @throws InvalidKeyException */
    public fun privateKey(jwk: EcPrivateJwk): ECPrivateKey {
        if (jwk.kty != "EC" || jwk.crv != "P-256") throw InvalidKeyException("unsupported key type")
        val d = Base64Codec.decode(jwk.d)?.takeIf { it.size == COORD } ?: throw InvalidKeyException("bad d")
        return try {
            KeyFactory.getInstance("EC").generatePrivate(ECPrivateKeySpec(BigInteger(1, d), P256)) as ECPrivateKey
        } catch (e: Exception) {
            throw InvalidKeyException("invalid private key", e)
        }
    }

    /** Key pair from a private JWK (public part from its x/y). */
    public fun keyPair(jwk: EcPrivateJwk): KeyPair = KeyPair(publicKey(jwk.publicJwk), privateKey(jwk))

    /** JWK of a public key. */
    public fun jwk(publicKey: ECPublicKey): EcPublicJwk = EcPublicJwk(
        x = Base64Codec.encodeUrl(fixed(publicKey.w.affineX)),
        y = Base64Codec.encodeUrl(fixed(publicKey.w.affineY)),
    )

    /** Private JWK of a key pair. */
    public fun privateJwk(pair: KeyPair): EcPrivateJwk {
        val pub = jwk(pair.public as ECPublicKey)
        return EcPrivateJwk(x = pub.x, y = pub.y, d = Base64Codec.encodeUrl(fixed((pair.private as ECPrivateKey).s)))
    }

    /** Big-endian unsigned, left-padded to 32 bytes. */
    internal fun fixed(v: BigInteger): ByteArray {
        val raw = v.toByteArray()
        return when {
            raw.size == COORD -> raw
            raw.size > COORD -> raw.copyOfRange(raw.size - COORD, raw.size) // leading sign byte
            else -> ByteArray(COORD - raw.size) + raw
        }
    }
}

/** ES256 (ECDSA P-256 + SHA-256) with the JWS raw `r‖s` signature format. */
public object Es256 {
    /** Verifies a raw 64-byte `r‖s` [signature] over [data]. Never throws. */
    public fun verify(publicKey: ECPublicKey, data: ByteArray, signature: ByteArray): Boolean {
        if (signature.size != 64) return false
        return try {
            Signature.getInstance("SHA256withECDSA").run {
                initVerify(publicKey)
                update(data)
                verify(rawToDer(signature))
            }
        } catch (_: Exception) {
            false
        }
    }

    /** Signs [data]; returns raw 64-byte `r‖s` (tests / tooling). */
    public fun sign(privateKey: ECPrivateKey, data: ByteArray): ByteArray {
        val der = Signature.getInstance("SHA256withECDSA").run {
            initSign(privateKey)
            update(data)
            sign()
        }
        return derToRaw(der)
    }

    /** Raw `r‖s` → ASN.1 DER `SEQUENCE { INTEGER r, INTEGER s }`. */
    public fun rawToDer(raw: ByteArray): ByteArray {
        require(raw.size == 64)
        val r = derInteger(raw.copyOfRange(0, 32))
        val s = derInteger(raw.copyOfRange(32, 64))
        val body = r + s
        return byteArrayOf(0x30, body.size.toByte()) + body // body ≤ 70 bytes: short form length
    }

    /** ASN.1 DER ECDSA signature → raw `r‖s`. */
    public fun derToRaw(der: ByteArray): ByteArray {
        var i = 0
        require(der[i++] == 0x30.toByte()) { "not a sequence" }
        var len = der[i++].toInt() and 0xFF
        if (len and 0x80 != 0) i += len and 0x7F
        fun readInt(): BigInteger {
            require(der[i++] == 0x02.toByte()) { "not an integer" }
            len = der[i++].toInt() and 0xFF
            val v = BigInteger(1, der.copyOfRange(i, i + len))
            i += len
            return v
        }
        val r = readInt()
        val s = readInt()
        return EcKeys.fixed(r) + EcKeys.fixed(s)
    }

    private fun derInteger(unsigned: ByteArray): ByteArray {
        var start = 0
        while (start < unsigned.size - 1 && unsigned[start] == 0.toByte()) start++
        var v = unsigned.copyOfRange(start, unsigned.size)
        if (v[0].toInt() and 0x80 != 0) v = byteArrayOf(0) + v
        return byteArrayOf(0x02, v.size.toByte()) + v
    }
}
