package io.iptvplayer.shared.work

import android.content.Context
import androidx.work.Constraints
import androidx.work.CoroutineWorker
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.ExistingWorkPolicy
import androidx.work.NetworkType
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import androidx.work.workDataOf
import io.iptvplayer.core.model.Source
import io.iptvplayer.shared.di.AppGraphProvider
import io.iptvplayer.shared.log.SafeLog
import java.util.concurrent.TimeUnit

/**
 * Background refresh (ARCHITECTURE §2): a periodic job (every 6 h, network required, battery not
 * low) refreshes every source whose `autoRefreshHours` elapsed, then its EPG. A one-time job
 * imports the EPG right after a source was added (so the UI is not blocked).
 */
class RefreshWorker(context: Context, params: WorkerParameters) : CoroutineWorker(context, params) {
    override suspend fun doWork(): Result {
        val graph = (applicationContext as? AppGraphProvider)?.graph ?: return Result.failure()
        val only = inputData.getString(KEY_SOURCE)
        val epgOnly = inputData.getBoolean(KEY_EPG_ONLY, false)
        val now = System.currentTimeMillis()
        for (s in graph.sources.all()) {
            if (only != null && s.id != only) continue
            if (!epgOnly && only == null && !isDue(s, now)) continue
            if (!epgOnly) graph.sources.refresh(s.id)
            graph.sources.importEpg(s.id)
        }
        SafeLog.i(TAG, "refresh done")
        return Result.success()
    }

    companion object {
        private const val TAG = "RefreshWorker"
        private const val KEY_SOURCE = "source"
        private const val KEY_EPG_ONLY = "epgOnly"
        private const val PERIODIC = "refresh-periodic"

        fun isDue(s: Source, nowMs: Long): Boolean {
            if (s.autoRefreshHours <= 0) return false
            val last = s.lastRefreshAtMs ?: return true
            return nowMs - last >= s.autoRefreshHours * 3_600_000L
        }

        private val constraints = Constraints.Builder()
            .setRequiredNetworkType(NetworkType.CONNECTED)
            .setRequiresBatteryNotLow(true)
            .build()

        fun schedulePeriodic(context: Context) {
            val req = PeriodicWorkRequestBuilder<RefreshWorker>(6, TimeUnit.HOURS)
                .setConstraints(constraints)
                .build()
            WorkManager.getInstance(context).enqueueUniquePeriodicWork(PERIODIC, ExistingPeriodicWorkPolicy.KEEP, req)
        }

        fun importEpgNow(context: Context, sourceId: String) {
            val req = OneTimeWorkRequestBuilder<RefreshWorker>()
                .setConstraints(Constraints.Builder().setRequiredNetworkType(NetworkType.CONNECTED).build())
                .setInputData(workDataOf(KEY_SOURCE to sourceId, KEY_EPG_ONLY to true))
                .build()
            WorkManager.getInstance(context).enqueueUniqueWork("epg-$sourceId", ExistingWorkPolicy.REPLACE, req)
        }
    }
}
