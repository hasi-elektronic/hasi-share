package io.iptvplayer.core.media

import io.iptvplayer.core.error.PlaybackError
import io.iptvplayer.core.util.UrlParts
import io.iptvplayer.core.util.UrlNormalizer
import java.util.Locale

/** Stream container (CONTRACT §6). [wire] is the cross-platform name (`mpegts`, `hls`, …). */
public enum class Container(public val wire: String) {
    HLS("hls"),
    DASH("dash"),
    MPEGTS("mpegts"),
    MP4("mp4"),
    MKV("mkv"),
    WEBM("webm"),
    FLV("flv"),
    AVI("avi"),
    RTMP("rtmp"),
    RTSP("rtsp"),
    UDP("udp"),
    UNKNOWN("unknown"),
    ;

    public companion object {
        /** Parses a wire name; unknown → [UNKNOWN]. */
        public fun fromWire(value: String?): Container =
            entries.firstOrNull { it.wire.equals(value?.trim(), ignoreCase = true) } ?: UNKNOWN
    }
}

/** Playback engine whose support matrix applies. */
public enum class PlayerEngine {
    /** Android / Android TV (androidx.media3 ExoPlayer). */
    MEDIA3,

    /** iOS / tvOS (AVPlayer). */
    AVPLAYER,
}

/**
 * Container detection of CONTRACT §6:
 * `detectContainer(url, contentType?, firstBytes?)`, order: scheme → byte sniff (≥ 4 bytes) →
 * content-type → URL path extension → unknown.
 *
 * The player layer typically calls it with the URL only (fast path) and, for `unknown`, again
 * after a ranged GET of the first 1024 bytes.
 */
public object StreamFormatDetector {
    /** Recommended number of bytes to sniff. */
    public const val SNIFF_BYTES: Int = 1024

    /** Detects the container; see the object documentation. */
    public fun detect(url: String, contentType: String? = null, firstBytes: ByteArray? = null): Container {
        fromScheme(url)?.let { return it }
        if (firstBytes != null && firstBytes.size >= 4) sniff(firstBytes)?.let { return it }
        fromContentType(contentType)?.let { return it }
        fromExtension(url)?.let { return it }
        return Container.UNKNOWN
    }

    /** Step 1: `rtmp*` → rtmp, `rtsp*` → rtsp, `udp`/`rtp` → udp. */
    public fun fromScheme(url: String): Container? {
        val scheme = UrlParts.parse(url.trim())?.scheme ?: return null
        return when {
            scheme.startsWith("rtmp") -> Container.RTMP
            scheme == "rtsp" || scheme == "rtsps" -> Container.RTSP
            scheme == "udp" || scheme == "rtp" -> Container.UDP
            else -> null
        }
    }

    /** Step 2: magic-byte sniffing. Returns null when nothing matches. */
    public fun sniff(bytes: ByteArray): Container? {
        if (bytes.size < 4) return null
        // MPEG-TS: sync byte 0x47 every 188 bytes.
        if (u(bytes, 0) == 0x47 && bytes.size > 188 && u(bytes, 188) == 0x47 &&
            (bytes.size <= 376 || u(bytes, 376) == 0x47)
        ) {
            return Container.MPEGTS
        }
        // ISO BMFF: "ftyp" at offset 4.
        if (bytes.size >= 8 && ascii(bytes, 4, 4) == "ftyp") return Container.MP4
        // EBML (Matroska / WebM).
        if (u(bytes, 0) == 0x1A && u(bytes, 1) == 0x45 && u(bytes, 2) == 0xDF && u(bytes, 3) == 0xA3) {
            return if (ebmlDocType(bytes) == "webm") Container.WEBM else Container.MKV
        }
        if (ascii(bytes, 0, 3) == "FLV") return Container.FLV
        if (bytes.size >= 12 && ascii(bytes, 0, 4) == "RIFF" && ascii(bytes, 8, 4) == "AVI ") return Container.AVI
        // Text formats (skip BOM + leading whitespace).
        val text = leadingText(bytes)
        if (text.startsWith("#EXTM3U")) return Container.HLS
        if (text.startsWith("<MPD") || (text.startsWith("<?xml") && text.contains("<MPD"))) return Container.DASH
        return null
    }

    /** Step 3: content-type (case-insensitive, parameters ignored). */
    public fun fromContentType(contentType: String?): Container? {
        val ct = contentType?.substringBefore(';')?.trim()?.lowercase(Locale.ROOT)
        if (ct.isNullOrEmpty()) return null
        return when (ct) {
            "application/vnd.apple.mpegurl", "application/x-mpegurl", "audio/mpegurl", "audio/x-mpegurl" -> Container.HLS
            "application/dash+xml" -> Container.DASH
            "video/mp2t" -> Container.MPEGTS
            "video/mp4" -> Container.MP4
            "video/x-matroska" -> Container.MKV
            "video/webm" -> Container.WEBM
            "video/x-flv" -> Container.FLV
            else -> null
        }
    }

    /** Step 4: URL path extension (query/fragment ignored, case-insensitive). */
    public fun fromExtension(url: String): Container? = when (UrlNormalizer.pathExtension(url)) {
        "m3u8" -> Container.HLS
        "mpd" -> Container.DASH
        "ts" -> Container.MPEGTS
        "mp4", "m4v", "mov" -> Container.MP4
        "mkv" -> Container.MKV
        "webm" -> Container.WEBM
        "flv" -> Container.FLV
        "avi" -> Container.AVI
        else -> null
    }

    private fun u(b: ByteArray, i: Int): Int = if (i < b.size) b[i].toInt() and 0xFF else -1

    private fun ascii(b: ByteArray, off: Int, len: Int): String {
        if (off + len > b.size) return ""
        return String(b, off, len, Charsets.ISO_8859_1)
    }

    private fun leadingText(bytes: ByteArray): String {
        var start = 0
        if (bytes.size >= 3 && u(bytes, 0) == 0xEF && u(bytes, 1) == 0xBB && u(bytes, 2) == 0xBF) start = 3
        while (start < bytes.size && (bytes[start] == ' '.code.toByte() || bytes[start] == '\t'.code.toByte() ||
                bytes[start] == '\r'.code.toByte() || bytes[start] == '\n'.code.toByte())
        ) {
            start++
        }
        return String(bytes, start, minOf(bytes.size - start, SNIFF_BYTES), Charsets.ISO_8859_1)
    }

    /** Reads the EBML DocType (element 0x4282) from the EBML header, e.g. `webm` or `matroska`. */
    private fun ebmlDocType(b: ByteArray): String? {
        val limit = minOf(b.size - 3, 64)
        var i = 4
        while (i < limit) {
            if (u(b, i) == 0x42 && u(b, i + 1) == 0x82) {
                val sizeByte = u(b, i + 2)
                // Variable-length size: number of leading zero bits + 1 = length in bytes.
                var len = 1
                var mask = 0x80
                while (len <= 8 && (sizeByte and mask) == 0) {
                    len++
                    mask = mask ushr 1
                }
                if (len > 8) return null
                var size = (sizeByte and (mask - 1)).toLong()
                for (k in 1 until len) size = (size shl 8) or u(b, i + 2 + k).toLong()
                val start = i + 2 + len
                if (size <= 0 || size > 32 || start + size > b.size) return null
                return String(b, start, size.toInt(), Charsets.ISO_8859_1).trimEnd('\u0000')
            }
            i++
        }
        // Fallback: plain search.
        return if (ascii(b, 0, minOf(b.size, 64)).contains("webm")) "webm" else null
    }
}

/**
 * Support matrix of CONTRACT §6 (`media/expected.json` → `support`). `unknown` is "try and map
 * the player error" and therefore reported as supported.
 */
public object PlatformSupport {
    private val MEDIA3_UNSUPPORTED = setOf(Container.RTMP, Container.UDP)
    private val AVPLAYER_SUPPORTED = setOf(Container.HLS, Container.MP4, Container.UNKNOWN)

    /** True when [engine] can play [container]. */
    public fun isSupported(container: Container, engine: PlayerEngine): Boolean = when (engine) {
        PlayerEngine.MEDIA3 -> container !in MEDIA3_UNSUPPORTED
        PlayerEngine.AVPLAYER -> container in AVPLAYER_SUPPORTED
    }

    /**
     * Pre-playback check: null when playable, else [PlaybackError.UnsupportedFormat] with the
     * container wire name (UI maps `mpegts` on Apple to the "ask your provider for HLS" hint).
     */
    public fun check(container: Container, engine: PlayerEngine): PlaybackError? =
        if (isSupported(container, engine)) null else PlaybackError.UnsupportedFormat(container.wire)
}
