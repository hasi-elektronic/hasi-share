package io.iptvplayer.core.util

import okio.BufferedSource
import okio.GzipSource
import okio.buffer

/** Gzip auto-detection by magic bytes (`1f 8b`), regardless of file extension / headers. */
public object Gzip {
    /** True when the next two bytes of [source] are the gzip magic (does not consume). */
    public fun isGzip(source: BufferedSource): Boolean =
        source.request(2) && source.buffer[0] == 0x1f.toByte() && source.buffer[1] == 0x8b.toByte()

    /** Returns a source that transparently gunzips [source] when it is gzip-compressed. */
    public fun maybeGunzip(source: BufferedSource): BufferedSource =
        if (isGzip(source)) GzipSource(source).buffer() else source
}
