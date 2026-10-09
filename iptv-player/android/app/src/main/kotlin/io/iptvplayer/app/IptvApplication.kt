package io.iptvplayer.app

import android.app.Application
import coil3.ImageLoader
import coil3.PlatformContext
import coil3.SingletonImageLoader
import coil3.disk.DiskCache
import coil3.memory.MemoryCache
import coil3.network.okhttp.OkHttpNetworkFetcherFactory
import coil3.request.crossfade
import io.iptvplayer.shared.config.AppConfig
import io.iptvplayer.shared.di.AppGraph
import io.iptvplayer.shared.di.AppGraphProvider
import okio.Path.Companion.toOkioPath

/** Creates the manual DI graph from BuildConfig (placeholders from gradle.properties). */
class IptvApplication : Application(), AppGraphProvider, SingletonImageLoader.Factory {
    override val graph: AppGraph by lazy {
        AppGraph(
            this,
            AppConfig(
                appId = BuildConfig.APP_ID,
                appName = BuildConfig.APP_NAME,
                versionName = BuildConfig.VERSION_NAME,
                versionCode = BuildConfig.VERSION_CODE,
                backendBaseUrl = BuildConfig.BACKEND_BASE_URL,
                productLifetime = BuildConfig.PRODUCT_LIFETIME,
                debug = BuildConfig.DEBUG,
                licenseKeysJson = assets.open("license-keys.json").bufferedReader().use { it.readText() },
            ),
        )
    }

    override fun onCreate() {
        super.onCreate()
        graph.start()
    }

    /** Coil 3: memory + disk cache (ARCHITECTURE §2), shared OkHttp client. */
    override fun newImageLoader(context: PlatformContext): ImageLoader = ImageLoader.Builder(context)
        .components { add(OkHttpNetworkFetcherFactory(callFactory = { graph.okHttp })) }
        .memoryCache { MemoryCache.Builder().maxSizePercent(context, 0.20).build() }
        .diskCache { DiskCache.Builder().directory(cacheDir.resolve("images").toOkioPath()).maxSizeBytes(200L * 1024 * 1024).build() }
        .crossfade(true)
        .build()
}
