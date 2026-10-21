package io.iptvplayer.shared.settings

import android.content.Context
import androidx.datastore.core.DataStore
import androidx.datastore.preferences.core.Preferences
import androidx.datastore.preferences.core.booleanPreferencesKey
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.intPreferencesKey
import androidx.datastore.preferences.core.longPreferencesKey
import androidx.datastore.preferences.core.stringPreferencesKey
import androidx.datastore.preferences.preferencesDataStore
import io.iptvplayer.core.CoreJson
import io.iptvplayer.core.license.TrustedClockState
import io.iptvplayer.core.xtream.LiveFormatPreference
import io.iptvplayer.shared.player.AspectMode
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.map

/** Buffer preset (SCREENS §3.9). */
enum class BufferMode { NORMAL, LARGE }

/** User-visible settings (SCREENS §3.9). Empty language = system / automatic. */
data class AppSettings(
    val selectedSourceId: String? = null,
    val audioLanguage: String = "",
    val subtitleLanguage: String = "",
    val aspect: AspectMode = AspectMode.FIT,
    val liveFormat: LiveFormatPreference = LiveFormatPreference.AUTO,
    val buffer: BufferMode = BufferMode.NORMAL,
    val tvPreview: Boolean = false,
    val appLanguage: String = "",
    val epgTimezone: String = "",
    val use24h: Boolean = true,
)

/** Persisted licensing state (signed token = tamper-evident; DataStore excluded from backup). */
data class LicenseCache(
    val token: String?,
    val clock: TrustedClockState?,
    val trialDays: Int?,
    val lastSyncWallMs: Long?,
)

/** Persisted account-sync bookkeeping. */
data class SyncCache(val cursor: Long, val lastPushMs: Long, val lastSyncMs: Long?)

/**
 * DataStore Preferences wrapper (ARCHITECTURE §2). Abstracted behind [SettingsRepository] so
 * managers are testable without Android.
 */
interface SettingsRepository {
    val settings: Flow<AppSettings>
    suspend fun current(): AppSettings = settings.first()
    suspend fun update(transform: (AppSettings) -> AppSettings)

    suspend fun licenseCache(): LicenseCache
    suspend fun saveLicense(token: String?, clock: TrustedClockState?, trialDays: Int?, lastSyncWallMs: Long?)

    suspend fun syncCache(): SyncCache
    suspend fun saveSync(cache: SyncCache)
}

private val Context.dataStore: DataStore<Preferences> by preferencesDataStore(name = DataStoreSettings.FILE)

class DataStoreSettings(context: Context) : SettingsRepository {
    private val store = context.applicationContext.dataStore

    override val settings: Flow<AppSettings> = store.data.map { p ->
        AppSettings(
            selectedSourceId = p[SELECTED_SOURCE],
            audioLanguage = p[AUDIO_LANG] ?: "",
            subtitleLanguage = p[SUB_LANG] ?: "",
            aspect = p[ASPECT]?.let { runCatching { AspectMode.valueOf(it) }.getOrNull() } ?: AspectMode.FIT,
            liveFormat = p[LIVE_FORMAT]?.let { runCatching { LiveFormatPreference.valueOf(it) }.getOrNull() } ?: LiveFormatPreference.AUTO,
            buffer = p[BUFFER]?.let { runCatching { BufferMode.valueOf(it) }.getOrNull() } ?: BufferMode.NORMAL,
            tvPreview = p[TV_PREVIEW] ?: false,
            appLanguage = p[APP_LANG] ?: "",
            epgTimezone = p[EPG_TZ] ?: "",
            use24h = p[USE_24H] ?: true,
        )
    }

    override suspend fun update(transform: (AppSettings) -> AppSettings) {
        store.edit { p ->
            val cur = AppSettings(
                selectedSourceId = p[SELECTED_SOURCE],
                audioLanguage = p[AUDIO_LANG] ?: "",
                subtitleLanguage = p[SUB_LANG] ?: "",
                aspect = p[ASPECT]?.let { runCatching { AspectMode.valueOf(it) }.getOrNull() } ?: AspectMode.FIT,
                liveFormat = p[LIVE_FORMAT]?.let { runCatching { LiveFormatPreference.valueOf(it) }.getOrNull() } ?: LiveFormatPreference.AUTO,
                buffer = p[BUFFER]?.let { runCatching { BufferMode.valueOf(it) }.getOrNull() } ?: BufferMode.NORMAL,
                tvPreview = p[TV_PREVIEW] ?: false,
                appLanguage = p[APP_LANG] ?: "",
                epgTimezone = p[EPG_TZ] ?: "",
                use24h = p[USE_24H] ?: true,
            )
            val n = transform(cur)
            if (n.selectedSourceId != null) p[SELECTED_SOURCE] = n.selectedSourceId else p.remove(SELECTED_SOURCE)
            p[AUDIO_LANG] = n.audioLanguage
            p[SUB_LANG] = n.subtitleLanguage
            p[ASPECT] = n.aspect.name
            p[LIVE_FORMAT] = n.liveFormat.name
            p[BUFFER] = n.buffer.name
            p[TV_PREVIEW] = n.tvPreview
            p[APP_LANG] = n.appLanguage
            p[EPG_TZ] = n.epgTimezone
            p[USE_24H] = n.use24h
        }
    }

    override suspend fun licenseCache(): LicenseCache {
        val p = store.data.first()
        return LicenseCache(
            token = p[LICENSE_TOKEN],
            clock = p[CLOCK_STATE]?.let { runCatching { CoreJson.decodeFromString(TrustedClockState.serializer(), it) }.getOrNull() },
            trialDays = p[TRIAL_DAYS],
            lastSyncWallMs = p[LICENSE_SYNC_AT],
        )
    }

    override suspend fun saveLicense(token: String?, clock: TrustedClockState?, trialDays: Int?, lastSyncWallMs: Long?) {
        store.edit { p ->
            if (token != null) p[LICENSE_TOKEN] = token else p.remove(LICENSE_TOKEN)
            if (clock != null) p[CLOCK_STATE] = CoreJson.encodeToString(TrustedClockState.serializer(), clock) else p.remove(CLOCK_STATE)
            if (trialDays != null) p[TRIAL_DAYS] = trialDays
            if (lastSyncWallMs != null) p[LICENSE_SYNC_AT] = lastSyncWallMs
        }
    }

    override suspend fun syncCache(): SyncCache {
        val p = store.data.first()
        return SyncCache(p[SYNC_CURSOR] ?: 0L, p[SYNC_LAST_PUSH] ?: 0L, p[SYNC_LAST])
    }

    override suspend fun saveSync(cache: SyncCache) {
        store.edit { p ->
            p[SYNC_CURSOR] = cache.cursor
            p[SYNC_LAST_PUSH] = cache.lastPushMs
            cache.lastSyncMs?.let { p[SYNC_LAST] = it }
        }
    }

    companion object {
        /** DataStore file name (`files/datastore/settings.preferences_pb`, excluded from backup). */
        const val FILE = "settings"
        private val SELECTED_SOURCE = stringPreferencesKey("selected_source")
        private val AUDIO_LANG = stringPreferencesKey("audio_lang")
        private val SUB_LANG = stringPreferencesKey("sub_lang")
        private val ASPECT = stringPreferencesKey("aspect")
        private val LIVE_FORMAT = stringPreferencesKey("live_format")
        private val BUFFER = stringPreferencesKey("buffer")
        private val TV_PREVIEW = booleanPreferencesKey("tv_preview")
        private val APP_LANG = stringPreferencesKey("app_lang")
        private val EPG_TZ = stringPreferencesKey("epg_tz")
        private val USE_24H = booleanPreferencesKey("use_24h")
        private val LICENSE_TOKEN = stringPreferencesKey("license_token")
        private val CLOCK_STATE = stringPreferencesKey("trusted_clock")
        private val TRIAL_DAYS = intPreferencesKey("trial_days")
        private val LICENSE_SYNC_AT = longPreferencesKey("license_sync_at")
        private val SYNC_CURSOR = longPreferencesKey("sync_cursor")
        private val SYNC_LAST_PUSH = longPreferencesKey("sync_last_push")
        private val SYNC_LAST = longPreferencesKey("sync_last")
    }
}

/** In-memory implementation for unit tests. */
class InMemorySettings(initial: AppSettings = AppSettings()) : SettingsRepository {
    private val state = kotlinx.coroutines.flow.MutableStateFlow(initial)
    private var license = LicenseCache(null, null, null, null)
    private var sync = SyncCache(0, 0, null)
    override val settings: Flow<AppSettings> = state
    override suspend fun update(transform: (AppSettings) -> AppSettings) { state.value = transform(state.value) }
    override suspend fun licenseCache(): LicenseCache = license
    override suspend fun saveLicense(token: String?, clock: TrustedClockState?, trialDays: Int?, lastSyncWallMs: Long?) {
        license = LicenseCache(token, clock, trialDays ?: license.trialDays, lastSyncWallMs ?: license.lastSyncWallMs)
    }
    override suspend fun syncCache(): SyncCache = sync
    override suspend fun saveSync(cache: SyncCache) { sync = cache }
}
