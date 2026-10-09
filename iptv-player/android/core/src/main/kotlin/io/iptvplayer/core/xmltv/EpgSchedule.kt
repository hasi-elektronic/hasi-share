package io.iptvplayer.core.xmltv

import io.iptvplayer.core.model.CatchupInfo
import io.iptvplayer.core.model.EpgProgram

/** Programme on air and the one after it. Either may be null (gap in the guide, end of data). */
public data class NowNext(val now: EpgProgram?, val next: EpgProgram?)

/**
 * Now/next lookup and progress helpers over the programmes of **one** channel, sorted by
 * `startMs` (the DB query / XMLTV parser order). Times are epoch ms (trusted clock).
 */
public object EpgSchedule {
    private const val OVERLAP_LOOKBACK = 8

    /**
     * The programme on air at [nowMs] (`start ≤ now < end`) and the next one starting after
     * [nowMs]. Binary search, O(log n).
     */
    public fun nowAndNext(programs: List<EpgProgram>, nowMs: Long): NowNext {
        // First index whose start is after nowMs.
        var lo = 0
        var hi = programs.size
        while (lo < hi) {
            val mid = (lo + hi) ushr 1
            if (programs[mid].startMs <= nowMs) lo = mid + 1 else hi = mid
        }
        val next = programs.getOrNull(lo)
        // Overlapping guides: the latest-starting programme that still covers now wins
        // (bounded look-back so a gap in the guide stays O(log n)).
        var current: EpgProgram? = null
        for (i in lo - 1 downTo maxOf(0, lo - OVERLAP_LOOKBACK)) {
            if (programs[i].isLiveAt(nowMs)) {
                current = programs[i]
                break
            }
        }
        return NowNext(current, next)
    }

    /** Progress fraction 0…1 of `[startMs, endMs)` at [nowMs]. */
    public fun progress(startMs: Long, endMs: Long, nowMs: Long): Double {
        val total = endMs - startMs
        if (total <= 0) return 0.0
        return ((nowMs - startMs).toDouble() / total).coerceIn(0.0, 1.0)
    }

    /** Progress of [program] at [nowMs]. */
    public fun progress(program: EpgProgram, nowMs: Long): Double = progress(program.startMs, program.endMs, nowMs)

    /** Remaining minutes (rounded up) of [program] at [nowMs]; 0 when over. */
    public fun remainingMinutes(program: EpgProgram, nowMs: Long): Long {
        val ms = program.endMs - nowMs
        return if (ms <= 0) 0 else (ms + 59_999) / 60_000
    }

    /** Programmes overlapping `[fromMs, toMs)` (e.g. the visible part of the EPG grid), in order. */
    public fun overlapping(programs: List<EpgProgram>, fromMs: Long, toMs: Long): List<EpgProgram> =
        programs.filter { it.endMs > fromMs && it.startMs < toMs }

    /**
     * True if a finished programme can be replayed via catch-up at [nowMs]: the channel has an
     * archive and the programme started within the last `max(days, 1)` days.
     */
    public fun isCatchupAvailable(program: EpgProgram, catchup: CatchupInfo, nowMs: Long): Boolean {
        if (!catchup.available || program.endMs > nowMs) return false
        val days = maxOf(catchup.days, 1)
        return program.startMs >= nowMs - days * 86_400_000L
    }
}
