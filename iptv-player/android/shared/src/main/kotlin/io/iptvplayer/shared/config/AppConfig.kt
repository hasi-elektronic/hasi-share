package io.iptvplayer.shared.config

/**
 * Build-time configuration handed from `:app` (BuildConfig) to the shared layer. Product names and
 * ids are placeholders defined only in `android/gradle.properties` (CONTRACT §0).
 *
 * @property licenseKeysJson embedded JWK set (`assets/license-keys.json`).
 */
data class AppConfig(
    val appId: String,
    val appName: String,
    val versionName: String,
    val versionCode: Int,
    val backendBaseUrl: String,
    val productLifetime: String,
    val debug: Boolean,
    val licenseKeysJson: String,
) {
    /** `appVersion` field of `/v1/license/sync`. */
    val appVersion: String get() = "$versionName ($versionCode)"

    /** True when the backend URL is still the placeholder (no backend configured). */
    val backendConfigured: Boolean get() = !backendBaseUrl.contains("example.") && backendBaseUrl.startsWith("http")
}
