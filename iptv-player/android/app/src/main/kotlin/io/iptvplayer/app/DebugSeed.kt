package io.iptvplayer.app

import android.content.Intent
import androidx.activity.ComponentActivity
import androidx.lifecycle.lifecycleScope
import io.iptvplayer.core.model.SourceSecrets
import io.iptvplayer.shared.di.AppGraph
import io.iptvplayer.shared.log.SafeLog
import kotlinx.coroutines.launch

/**
 * DEBUG builds only – the Android counterpart of Apple's `-seedM3U` (provider-simulator test matrix):
 * `adb shell am start -n <app>/io.iptvplayer.app.TvActivity --es seedM3U http://10.0.2.2:8766/x.m3u --es seedName X`
 * adds that M3U source once (by name); `--ez debugFullAccess true` unlocks playback. Never active in release builds.
 */
object DebugSeed {
    fun apply(activity: ComponentActivity, graph: AppGraph, intent: Intent?) {
        if (!BuildConfig.DEBUG) return
        // `--ez debugFullAccess true`: play without a store purchase (emulators have no Play billing / backend).
        if (intent?.getBooleanExtra("debugFullAccess", false) == true) graph.license.debugFullAccess = true
        val url = intent?.getStringExtra("seedM3U") ?: return
        val name = intent.getStringExtra("seedName") ?: "Seed"
        activity.lifecycleScope.launch {
            if (graph.sources.all().any { it.name == name }) return@launch
            SafeLog.i("DebugSeed", "adding seed source $name")
            graph.sources.add(name, SourceSecrets.M3u(url = url))
        }
    }
}
