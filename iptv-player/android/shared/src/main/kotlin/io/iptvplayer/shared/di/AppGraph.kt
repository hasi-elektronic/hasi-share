package io.iptvplayer.shared.di

import android.annotation.SuppressLint
import android.app.UiModeManager
import android.content.Context
import android.content.res.Configuration
import android.os.Build
import android.provider.Settings
import android.util.Xml
import androidx.lifecycle.DefaultLifecycleObserver
import androidx.lifecycle.LifecycleOwner
import androidx.lifecycle.ProcessLifecycleOwner
import io.iptvplayer.core.backend.BackendClient
import io.iptvplayer.core.backend.BackendPlatform
import io.iptvplayer.core.license.LicenseTokenVerifier
import io.iptvplayer.core.net.HttpDefaults
import io.iptvplayer.core.net.SourceHttp
import io.iptvplayer.core.util.DeviceKey
import io.iptvplayer.shared.account.AccountManager
import io.iptvplayer.shared.billing.BillingManager
import io.iptvplayer.shared.billing.StoreBilling
import io.iptvplayer.shared.config.AppConfig
import io.iptvplayer.shared.db.AppDatabase
import io.iptvplayer.shared.license.AndroidClocks
import io.iptvplayer.shared.license.LicenseManager
import io.iptvplayer.shared.log.SafeLog
import io.iptvplayer.shared.net.AndroidConnectivity
import io.iptvplayer.shared.pairing.PairingManager
import io.iptvplayer.shared.player.AspectMode
import io.iptvplayer.shared.player.FormatProber
import io.iptvplayer.shared.player.PlayableItem
import io.iptvplayer.shared.player.PlayerController
import io.iptvplayer.shared.repo.CatalogRepository
import io.iptvplayer.shared.repo.LibraryRepository
import io.iptvplayer.shared.repo.SourceRepository
import io.iptvplayer.shared.secure.KeystoreSecretStore
import io.iptvplayer.shared.secure.SecretStore
import io.iptvplayer.shared.settings.AppSettings
import io.iptvplayer.shared.settings.DataStoreSettings
import io.iptvplayer.shared.settings.SettingsRepository
import io.iptvplayer.shared.sync.SyncManager
import io.iptvplayer.shared.work.RefreshWorker
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch
import okhttp3.OkHttpClient

/** Implemented by the Application; gives Activities, ViewModels and workers the graph. */
interface AppGraphProvider {
    val graph: AppGraph
}

/** What the player screen should open next (stream URLs never travel through navigation args). */
data class PlaybackRequest(
    val item: PlayableItem,
    /** Channel ids of the list the user zaps through (live only). */
    val channelQueue: List<String> = emptyList(),
    val startPositionMs: Long? = null,
    val resumeFromProgress: Boolean = true,
)

/**
 * Manual dependency graph (ARCHITECTURE §2: no Hilt/kapt). One instance per process, created by
 * the Application.
 */
class AppGraph(context: Context, val config: AppConfig) {
    val context: Context = context.applicationContext
    val appScope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)

    val isTv: Boolean = run {
        val ui = context.getSystemService(Context.UI_MODE_SERVICE) as UiModeManager
        ui.currentModeType == Configuration.UI_MODE_TYPE_TELEVISION ||
            context.packageManager.hasSystemFeature("android.software.leanback")
    }
    val platform: String get() = if (isTv) BackendPlatform.ANDROID_TV else BackendPlatform.ANDROID

    val okHttp: OkHttpClient = HttpDefaults.newClient()
    val connectivity = AndroidConnectivity(this.context)
    val sourceHttp = SourceHttp(okHttp, connectivity, logger = SafeLog.core)

    val db: AppDatabase = AppDatabase.create(this.context)
    val secrets: SecretStore = KeystoreSecretStore(this.context)
    val settings: SettingsRepository = DataStoreSettings(this.context)
    val settingsState: StateFlow<AppSettings> = settings.settings.stateIn(appScope, SharingStarted.Eagerly, AppSettings())

    /** null when no backend URL is configured (placeholder) – licensing then works offline only. */
    val backend: BackendClient? = if (config.backendConfigured) {
        BackendClient(config.backendBaseUrl, okHttp, connectivity, SafeLog.core, userAgent = "IPTVPlayer/${config.versionName} (Android)")
    } else {
        null
    }

    val sources = SourceRepository(db, secrets, sourceHttp, { Xml.newPullParser() })
    val library = LibraryRepository(db)
    val catalog = CatalogRepository(db, sources)

    val billing: StoreBilling = BillingManager(this.context, config.productLifetime, appScope)
    val accounts = AccountManager(backend, secrets, appScope, deviceName(), { platform })

    @SuppressLint("HardwareIds")
    val deviceKey: String = DeviceKey.compute(
        config.appId,
        Settings.Secure.getString(this.context.contentResolver, Settings.Secure.ANDROID_ID) ?: "unknown",
    )

    val license = LicenseManager(
        backend = backend,
        billing = billing,
        settings = settings,
        verifier = LicenseTokenVerifier.fromJwkSet(config.licenseKeysJson, config.appId),
        clocks = AndroidClocks(this.context),
        deviceKey = { deviceKey },
        appId = config.appId,
        appVersion = config.appVersion,
        platform = { platform },
        sessionToken = { accounts.sessionToken() },
        scope = appScope,
    )

    val sync = SyncManager(backend, library, settings, { accounts.sessionToken() }, appScope, onUnauthorized = { accounts.onUnauthorized() })
    val pairing = PairingManager(backend, appScope)
    val formatProber by lazy { FormatProber(this.context, okHttp) }

    /** Pending player request (set by list screens, consumed by the player screen). */
    val playback = MutableStateFlow<PlaybackRequest?>(null)

    fun newPlayerController(scope: CoroutineScope): PlayerController = PlayerController(
        context = this.context,
        okHttp = okHttp,
        library = library,
        scope = scope,
        connectivity = connectivity,
        settingsProvider = { settingsState.value },
        onAspectChanged = { mode: AspectMode -> appScope.launch { settings.update { it.copy(aspect = mode) } } },
    )

    private var started = false

    /** Starts background machinery once (Application.onCreate). */
    fun start() {
        if (started) return
        started = true
        SafeLog.init(config.debug)
        appScope.launch { sources.registerSecretsForRedaction() }
        billing.start()
        license.start()
        sync.observe(library.localChanges)
        accounts.onSessionChanged = { signedIn ->
            if (signedIn) library.markAllDirty() else sync.reset()
            license.sync()
            if (signedIn) sync.syncNow()
        }
        RefreshWorker.schedulePeriodic(this.context)
        ProcessLifecycleOwner.get().lifecycle.addObserver(object : DefaultLifecycleObserver {
            private var first = true
            override fun onStart(owner: LifecycleOwner) {
                if (first) {
                    first = false
                    appScope.launch { sync.syncNow() }
                    return
                }
                // Foreground again: restore purchases, refresh license + sync (ARCHITECTURE §4.2, §6).
                appScope.launch {
                    billing.refreshPurchases()
                    license.sync()
                    sync.syncNow()
                }
            }
        })
    }

    private fun deviceName(): String = (Build.MANUFACTURER + " " + Build.MODEL).trim().take(60)
}
