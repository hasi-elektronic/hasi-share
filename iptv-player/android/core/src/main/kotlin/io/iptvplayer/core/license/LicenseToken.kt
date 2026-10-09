package io.iptvplayer.core.license

import io.iptvplayer.core.CoreConstants
import io.iptvplayer.core.crypto.EcKeys
import io.iptvplayer.core.crypto.EcPublicJwk
import io.iptvplayer.core.crypto.Es256
import io.iptvplayer.core.util.Base64Codec
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import java.security.interfaces.ECPublicKey

/** `lic.src` wire values (CONTRACT §7.2). Kept as strings so unknown future values decode. */
public object LicenseSrc {
    public const val GOOGLE: String = "google"
    public const val APPLE: String = "apple"
    public const val ACCOUNT: String = "account"
    public const val ADMIN: String = "admin"
}

/** `lic` claim of a license token (CONTRACT §7.2). Times are epoch **seconds**. */
@Serializable
public data class LicenseInfo(
    val purchased: Boolean = false,
    val src: String? = null,
    val trialStart: Long? = null,
    val trialEnd: Long? = null,
    val acct: String? = null,
)

/** Claims of a license token (CONTRACT §7.2). `iat`/`exp` are epoch **seconds**. */
@Serializable
public data class LicenseClaims(
    val iss: String,
    val aud: String,
    val sub: String,
    val iat: Long,
    val exp: Long,
    val lic: LicenseInfo,
)

/** Why a token was rejected (vector `reason` values, checked in this order). */
public enum class LicenseTokenFailure(public val wire: String) {
    FORMAT("format"),
    ALG("alg"),
    KID("kid"),
    SIGNATURE("signature"),
    ISS("iss"),
    AUD("aud"),
}

/** Result of [LicenseTokenVerifier.verify]. */
public sealed interface LicenseVerification {
    /**
     * Signature, issuer and audience are valid. [stale] = `exp` passed: the token is still
     * usable (all trial times are absolute) but the client should refresh it.
     */
    public data class Valid(val token: String, val claims: LicenseClaims, val stale: Boolean) : LicenseVerification

    /** Rejected for [reason]; the token must be ignored. */
    public data class Invalid(val reason: LicenseTokenFailure) : LicenseVerification
}

/**
 * Verifies ES256 license tokens (CONTRACT §7.2). Checks in order: compact format, `alg ==
 * ES256`, known `kid`, signature (raw `r‖s`), payload decodable, `iss`, `aud`.
 *
 * @param keys `kid → JWK` set embedded at build time (invalid entries are ignored).
 * @param audience the app's applicationId.
 */
public class LicenseTokenVerifier(
    keys: Map<String, EcPublicJwk>,
    public val audience: String,
    public val issuer: String = CoreConstants.LICENSE_ISSUER,
) {
    private val keys: Map<String, ECPublicKey> = keys.mapNotNull { (kid, jwk) ->
        try {
            kid to EcKeys.publicKey(jwk)
        } catch (_: Exception) {
            null
        }
    }.toMap()

    /** Known key ids. */
    public val keyIds: Set<String> get() = keys.keys

    /** Verifies [token] at [nowEpochSeconds]. Never throws. */
    public fun verify(token: String, nowEpochSeconds: Long): LicenseVerification {
        val parts = token.trim().split('.')
        if (parts.size != 3 || parts[0].isEmpty() || parts[1].isEmpty()) return invalid(LicenseTokenFailure.FORMAT)
        val header = Base64Codec.decode(parts[0])?.let { decodeObject(it) } ?: return invalid(LicenseTokenFailure.FORMAT)
        val payloadBytes = Base64Codec.decode(parts[1]) ?: return invalid(LicenseTokenFailure.FORMAT)
        val alg = header["alg"]?.let { runCatching { it.jsonPrimitive.content }.getOrNull() }
        if (alg != "ES256") return invalid(LicenseTokenFailure.ALG)
        val kid = header["kid"]?.let { runCatching { it.jsonPrimitive.content }.getOrNull() }
        val key = kid?.let { keys[it] } ?: return invalid(LicenseTokenFailure.KID)
        val signature = if (parts[2].isEmpty()) null else Base64Codec.decode(parts[2])
        val signingInput = (parts[0] + "." + parts[1]).encodeToByteArray()
        if (signature == null || !Es256.verify(key, signingInput, signature)) return invalid(LicenseTokenFailure.SIGNATURE)
        val claims = try {
            JSON.decodeFromString(LicenseClaims.serializer(), payloadBytes.decodeToString())
        } catch (_: Exception) {
            return invalid(LicenseTokenFailure.FORMAT)
        }
        if (claims.iss != issuer) return invalid(LicenseTokenFailure.ISS)
        if (claims.aud != audience) return invalid(LicenseTokenFailure.AUD)
        return LicenseVerification.Valid(token.trim(), claims, stale = nowEpochSeconds >= claims.exp)
    }

    /** Convenience: verified claims or null. */
    public fun claimsOrNull(token: String, nowEpochSeconds: Long): LicenseClaims? =
        (verify(token, nowEpochSeconds) as? LicenseVerification.Valid)?.claims

    private fun decodeObject(bytes: ByteArray): JsonObject? = try {
        JSON.parseToJsonElement(bytes.decodeToString()).jsonObject
    } catch (_: Exception) {
        null
    }

    private fun invalid(r: LicenseTokenFailure) = LicenseVerification.Invalid(r)

    public companion object {
        private val JSON = Json { ignoreUnknownKeys = true }

        /**
         * Parses an embedded JWK set (`license-keys.json`). Accepted shapes:
         * `{"kid": {jwk}}`, `{"keys": {"kid": {jwk}}}` and `{"keys": [{"kid": "…", …jwk}]}`.
         * @throws IllegalArgumentException when no key can be read.
         */
        public fun parseJwkSet(json: String): Map<String, EcPublicJwk> {
            val root = JSON.parseToJsonElement(json).jsonObject
            val out = LinkedHashMap<String, EcPublicJwk>()
            fun add(kid: String?, e: kotlinx.serialization.json.JsonElement) {
                if (kid.isNullOrEmpty() || e !is JsonObject) return
                runCatching { JSON.decodeFromJsonElement(EcPublicJwk.serializer(), e) }.getOrNull()?.let { out[kid] = it }
            }
            when (val keys = root["keys"]) {
                is JsonArray -> keys.forEach { k ->
                    add((k as? JsonObject)?.get("kid")?.let { runCatching { it.jsonPrimitive.content }.getOrNull() }, k)
                }
                is JsonObject -> keys.forEach { (kid, v) -> add(kid, v) }
                else -> root.forEach { (kid, v) -> add(kid, v) }
            }
            require(out.isNotEmpty()) { "no keys in JWK set" }
            return out
        }

        /** Verifier from an embedded JWK-set JSON (see [parseJwkSet]). */
        public fun fromJwkSet(json: String, audience: String): LicenseTokenVerifier =
            LicenseTokenVerifier(parseJwkSet(json), audience)
    }
}
