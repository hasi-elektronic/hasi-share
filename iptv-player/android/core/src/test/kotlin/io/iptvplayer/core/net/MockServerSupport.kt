package io.iptvplayer.core.net

import io.iptvplayer.core.error.ConnectivityProbe
import io.iptvplayer.core.retry.SourceRetryPolicy
import okhttp3.Dns
import okhttp3.OkHttpClient
import okio.Buffer
import okio.GzipSink
import okio.buffer
import java.util.concurrent.TimeUnit

/** Test helpers for MockWebServer based network tests. */
object MockServerSupport {
    /** Resolver that fails every lookup (DNS failure without touching the network). */
    val NO_DNS: Dns = object : Dns {
        override fun lookup(hostname: String): List<java.net.InetAddress> = throw java.net.UnknownHostException(hostname)
    }

    /** Client with short timeouts so timeout paths run in milliseconds. */
    fun fastClient(readTimeoutMs: Long = 300, dns: Dns = Dns.SYSTEM): OkHttpClient =
        HttpDefaults.newClient(OkHttpClient.Builder().dns(dns))
            .newBuilder()
            .connectTimeout(1_000, TimeUnit.MILLISECONDS)
            .readTimeout(readTimeoutMs, TimeUnit.MILLISECONDS)
            .build()

    /** [SourceHttp] that records retry sleeps instead of sleeping. */
    class RecordingHttp(
        client: OkHttpClient = fastClient(),
        offline: Boolean = false,
        retry: SourceRetryPolicy = SourceRetryPolicy.DEFAULT,
    ) {
        val sleeps = mutableListOf<Long>()
        val http = SourceHttp(
            client = client,
            connectivity = ConnectivityProbe { offline },
            retryPolicy = retry,
            sleeper = { sleeps += it },
        )
    }

    fun gzip(text: String): Buffer {
        val out = Buffer()
        GzipSink(out).buffer().use { it.writeUtf8(text) }
        return out
    }
}
