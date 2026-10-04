package io.iptvplayer.core.xmltv

import io.iptvplayer.core.model.CatchupInfo
import io.iptvplayer.core.model.CatchupType
import io.iptvplayer.core.model.EpgProgram
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

class EpgScheduleTest {
    private val m = 60_000L

    private fun p(start: Long, end: Long, t: String) = EpgProgram("s", "c", start * m, end * m, t)

    private val guide = listOf(p(0, 30, "A"), p(30, 60, "B"), p(90, 120, "C")) // gap 60..90

    @Test
    fun nowAndNext() {
        assertEquals(NowNext(guide[0], guide[1]), EpgSchedule.nowAndNext(guide, 0))
        assertEquals(NowNext(guide[0], guide[1]), EpgSchedule.nowAndNext(guide, 29 * m))
        assertEquals(NowNext(guide[1], guide[2]), EpgSchedule.nowAndNext(guide, 30 * m), "start is inclusive")
        assertEquals(NowNext(null, guide[2]), EpgSchedule.nowAndNext(guide, 70 * m), "gap: nothing on air")
        assertEquals(NowNext(guide[2], null), EpgSchedule.nowAndNext(guide, 100 * m))
        assertEquals(NowNext(null, null), EpgSchedule.nowAndNext(guide, 120 * m), "end is exclusive")
        assertEquals(NowNext(null, guide[0]), EpgSchedule.nowAndNext(guide, -5 * m))
        assertEquals(NowNext(null, null), EpgSchedule.nowAndNext(emptyList(), 0))
        // Overlap: a long programme still covers now although a later one started and ended.
        val overlapping = listOf(p(0, 100, "Long"), p(10, 20, "Short"))
        assertEquals("Long", EpgSchedule.nowAndNext(overlapping, 50 * m).now?.title)
        assertNull(EpgSchedule.nowAndNext(overlapping, 50 * m).next)
    }

    @Test
    fun nowAndNextOnLargeGuideIsFast() {
        val big = (0 until 200_000).map { p(it * 30L, it * 30L + 30, "P$it") }
        val started = System.nanoTime()
        repeat(100_000) { i -> EpgSchedule.nowAndNext(big, (i * 61L) * m) }
        assertTrue(System.nanoTime() - started < 2_000_000_000L, "binary search")
        assertEquals("P1000", EpgSchedule.nowAndNext(big, 30_000 * m).now?.title)
    }

    @Test
    fun progressAndRemaining() {
        assertEquals(0.5, EpgSchedule.progress(guide[0], 15 * m))
        assertEquals(0.0, EpgSchedule.progress(guide[0], -1))
        assertEquals(1.0, EpgSchedule.progress(guide[0], 99 * m))
        assertEquals(0.0, EpgSchedule.progress(10, 10, 10))
        assertEquals(15, EpgSchedule.remainingMinutes(guide[0], 15 * m))
        assertEquals(1, EpgSchedule.remainingMinutes(guide[0], 29 * m + 1))
        assertEquals(0, EpgSchedule.remainingMinutes(guide[0], 31 * m))
        assertEquals(listOf("B", "C"), EpgSchedule.overlapping(guide, 59 * m, 91 * m).map { it.title })
    }

    @Test
    fun catchupAvailability() {
        val day = 24 * 60L
        val now = 10 * day * m
        val archive = CatchupInfo(CatchupType.XTREAM, 3)
        assertTrue(EpgSchedule.isCatchupAvailable(p(9 * day, 9 * day + 30, "x"), archive, now))
        assertFalse(EpgSchedule.isCatchupAvailable(p(6 * day, 6 * day + 30, "x"), archive, now), "older than 3 days")
        assertFalse(EpgSchedule.isCatchupAvailable(p(10 * day - 10, 10 * day + 10, "x"), archive, now), "still running")
        assertFalse(EpgSchedule.isCatchupAvailable(p(9 * day, 9 * day + 30, "x"), CatchupInfo.NONE, now))
    }
}
