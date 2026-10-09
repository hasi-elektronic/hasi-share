package io.iptvplayer.core.m3u

import io.iptvplayer.core.model.ContentKind
import kotlinx.coroutines.runBlocking
import okio.Buffer
import okio.Source
import okio.Timeout
import okio.buffer
import org.junit.jupiter.api.Tag
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/**
 * 200 000-entry playlist (CONTRACT §3.12: streaming, batches ≤ 1000, never the whole file in
 * memory). The playlist is generated on the fly by an okio [Source] (~45 MB of text), so neither
 * the input nor the output is ever materialized. Runs by default (≈1–3 s); the test JVM heap is
 * capped at 512 MB in build.gradle.kts.
 */
@Tag("performance")
class M3uPerformanceTest {
    private class GeneratedPlaylist(private val entries: Int) : Source {
        private var i = -1
        private val pending = Buffer()
        var bytes = 0L
            private set

        override fun read(sink: Buffer, byteCount: Long): Long {
            while (pending.size < byteCount && i < entries) {
                if (i < 0) {
                    pending.writeUtf8("#EXTM3U url-tvg=\"http://epg.example.com/guide.xml.gz\"\n")
                } else if (i < entries) {
                    val kind = i % 10
                    when {
                        kind < 7 -> pending.writeUtf8(
                            "#EXTINF:-1 tvg-id=\"ch$i.tr\" tvg-name=\"Channel $i\" tvg-logo=\"http://logo.example.com/$i.png\" " +
                                "group-title=\"Group ${i % 50}\" catchup=\"default\" catchup-days=\"3\",Channel $i HD\n" +
                                "#EXTVLCOPT:http-user-agent=Mozilla/5.0\n" +
                                "http://iptv.example.com:8080/live/user/pass/$i.ts\n",
                        )
                        kind < 9 -> pending.writeUtf8(
                            "#EXTINF:-1 tvg-logo=\"http://img.example.com/$i.jpg\" group-title=\"Movies\",Movie $i (2020)\n" +
                                "http://iptv.example.com:8080/movie/user/pass/$i.mkv\n",
                        )
                        else -> pending.writeUtf8(
                            "#EXTINF:-1 group-title=\"Series\",Show ${i % 300} S0${i % 9 + 1}E${i % 40 + 1}\n" +
                                "http://iptv.example.com:8080/series/user/pass/$i.mp4\n",
                        )
                    }
                }
                i++
            }
            if (pending.size == 0L) return -1
            val n = pending.read(sink, byteCount)
            bytes += n
            return n
        }

        override fun timeout(): Timeout = Timeout.NONE

        override fun close() = Unit
    }

    @Test
    fun parses200kEntriesStreamingWithinBudget(): Unit = runBlocking {
        val total = 200_000
        val rt = Runtime.getRuntime()
        System.gc()
        val heapBefore = rt.totalMemory() - rt.freeMemory()
        var peakHeap = heapBefore
        var count = 0
        var batches = 0
        var maxBatch = 0
        val kinds = IntArray(ContentKind.entries.size)
        val source = GeneratedPlaylist(total)

        val started = System.nanoTime()
        val result = M3uParser.parse(source.buffer()) { batch ->
            batches++
            maxBatch = maxOf(maxBatch, batch.size)
            count += batch.size
            for (e in batch) kinds[e.kind.ordinal]++
            if (batches % 20 == 0) peakHeap = maxOf(peakHeap, rt.totalMemory() - rt.freeMemory())
        }
        val elapsedMs = (System.nanoTime() - started) / 1_000_000

        assertEquals(total, count)
        assertEquals(total, result.count)
        assertEquals(0, result.skipped)
        assertEquals(listOf("http://epg.example.com/guide.xml.gz"), result.epgUrls)
        assertEquals(200, batches)
        assertEquals(M3uParser.DEFAULT_BATCH_SIZE, maxBatch)
        assertEquals(140_000, kinds[ContentKind.LIVE.ordinal])
        assertEquals(40_000, kinds[ContentKind.MOVIE.ordinal])
        assertEquals(20_000, kinds[ContentKind.EPISODE.ordinal])
        assertTrue(source.bytes > 30_000_000, "input is large (${source.bytes} bytes)")

        // Generous bounds so slow CI machines pass; a regression to O(n²) or full buffering fails.
        println("M3U perf: $total entries, ${source.bytes / 1_000_000} MB in $elapsedMs ms, heap growth ~${(peakHeap - heapBefore) / 1_000_000} MB")
        assertTrue(elapsedMs < 15_000, "200k entries took $elapsedMs ms")
        // Batches are released after the callback: retained heap must stay far below the input size.
        assertTrue(peakHeap - heapBefore < 200_000_000, "heap grew by ${(peakHeap - heapBefore) / 1_000_000} MB")
    }
}
