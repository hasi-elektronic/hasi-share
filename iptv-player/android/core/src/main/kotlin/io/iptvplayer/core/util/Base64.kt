package io.iptvplayer.core.util

import okio.ByteString.Companion.decodeBase64
import okio.ByteString.Companion.toByteString
import java.nio.ByteBuffer
import java.nio.charset.CharacterCodingException
import java.nio.charset.CodingErrorAction

/**
 * Base64 helpers backed by Okio (works on every Android API level, unlike java.util.Base64).
 */
public object Base64Codec {
    /** base64url without padding (JWS / JWK / pairing wire format). */
    public fun encodeUrl(bytes: ByteArray): String = bytes.toByteString().base64Url().trimEnd('=')

    /** Standard base64 with padding. */
    public fun encodeStd(bytes: ByteArray): String = bytes.toByteString().base64()

    /**
     * Decodes standard **or** url-safe base64, with or without padding.
     * Returns null when [text] is not valid base64.
     */
    public fun decode(text: String): ByteArray? = text.trim().decodeBase64()?.toByteArray()

    /**
     * Decodes base64 and interprets the bytes as strict UTF-8.
     * Returns null when the input is not base64 or the bytes are not valid UTF-8
     * (used for Xtream short-EPG fields, CONTRACT §4.3).
     */
    public fun decodeUtf8OrNull(text: String): String? {
        val bytes = decode(text) ?: return null
        return try {
            Charsets.UTF_8.newDecoder()
                .onMalformedInput(CodingErrorAction.REPORT)
                .onUnmappableCharacter(CodingErrorAction.REPORT)
                .decode(ByteBuffer.wrap(bytes))
                .toString()
        } catch (_: CharacterCodingException) {
            null
        }
    }
}
