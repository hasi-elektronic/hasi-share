package io.iptvplayer.shared.net

import android.content.Context
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import io.iptvplayer.core.error.ConnectivityProbe

/** Connectivity probe so that failures while offline map to `Network(offline)` (CONTRACT §2). */
class AndroidConnectivity(context: Context) : ConnectivityProbe {
    private val cm = context.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager

    override fun isOffline(): Boolean {
        val n = cm.activeNetwork ?: return true
        val caps = cm.getNetworkCapabilities(n) ?: return true
        return !caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
    }
}
