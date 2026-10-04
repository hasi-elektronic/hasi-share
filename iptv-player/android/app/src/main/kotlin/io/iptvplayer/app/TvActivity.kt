package io.iptvplayer.app

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import io.iptvplayer.app.ui.theme.TvTheme
import io.iptvplayer.app.ui.tv.TvApp
import io.iptvplayer.shared.di.AppGraphProvider

/** Android TV UI (LEANBACK_LAUNCHER): androidx.tv tv-material, left navigation (SCREENS §2). */
class TvActivity : ComponentActivity() {
    override fun attachBaseContext(newBase: android.content.Context) {
        super.attachBaseContext(io.iptvplayer.app.ui.common.AppLocale.wrap(newBase))
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val graph = (application as AppGraphProvider).graph
        setContent { TvTheme { TvApp(graph) } }
    }
}
