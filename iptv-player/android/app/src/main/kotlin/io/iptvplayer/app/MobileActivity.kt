package io.iptvplayer.app

import android.content.Intent
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.SystemBarStyle
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import io.iptvplayer.app.ui.mobile.MobileApp
import io.iptvplayer.app.ui.theme.MobileTheme
import io.iptvplayer.app.ui.theme.Tokens
import androidx.compose.ui.graphics.toArgb
import io.iptvplayer.shared.di.AppGraphProvider

/** Phone / tablet UI (LAUNCHER): Compose Material 3, bottom navigation (SCREENS §2). */
class MobileActivity : ComponentActivity() {
    override fun attachBaseContext(newBase: android.content.Context) {
        super.attachBaseContext(io.iptvplayer.app.ui.common.AppLocale.wrap(newBase))
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val graph = (application as AppGraphProvider).graph
        // A TV that somehow launched the phone UI goes to the TV activity.
        if (graph.isTv) {
            startActivity(Intent(this, TvActivity::class.java))
            finish()
            return
        }
        enableEdgeToEdge(SystemBarStyle.dark(Tokens.Bg.toArgb()), SystemBarStyle.dark(Tokens.Bg.toArgb()))
        setContent { MobileTheme { MobileApp(graph) } }
    }
}
