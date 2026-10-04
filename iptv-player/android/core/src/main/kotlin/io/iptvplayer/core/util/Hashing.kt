package io.iptvplayer.core.util

import java.security.MessageDigest

/** Lower-case hexadecimal encoding. */
public object Hex {
    private val DIGITS = "0123456789abcdef".toCharArray()

    /** Encodes [bytes] as lower-case hex. */
    public fun encode(bytes: ByteArray): String {
        val out = CharArray(bytes.size * 2)
        for (i in bytes.indices) {
            val v = bytes[i].toInt() and 0xFF
            out[i * 2] = DIGITS[v ushr 4]
            out[i * 2 + 1] = DIGITS[v and 0x0F]
        }
        return String(out)
    }

    /** Decodes a hex string (either case). Throws [IllegalArgumentException] on invalid input. */
    public fun decode(hex: String): ByteArray {
        require(hex.length % 2 == 0) { "odd hex length" }
        return ByteArray(hex.length / 2) { i ->
            val hi = Character.digit(hex[i * 2], 16)
            val lo = Character.digit(hex[i * 2 + 1], 16)
            require(hi >= 0 && lo >= 0) { "invalid hex" }
            ((hi shl 4) or lo).toByte()
        }
    }
}

/** SHA-256 helpers. All string inputs are hashed as UTF-8. */
public object Sha256 {
    /** Raw 32-byte digest of [bytes]. */
    public fun digest(bytes: ByteArray): ByteArray = MessageDigest.getInstance("SHA-256").digest(bytes)

    /** Raw digest of the UTF-8 bytes of [text]. */
    public fun digest(text: String): ByteArray = digest(text.encodeToByteArray())

    /** Lower-case hex digest (64 chars) of the UTF-8 bytes of [text]. */
    public fun hex(text: String): String = Hex.encode(digest(text))
}
