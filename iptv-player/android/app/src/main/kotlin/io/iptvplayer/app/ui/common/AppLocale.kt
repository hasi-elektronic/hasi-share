package io.iptvplayer.app.ui.common

import android.app.Activity
import android.app.LocaleManager
import android.content.Context
import android.content.res.Configuration
import android.os.Build
import android.os.LocaleList
import androidx.core.content.edit
import java.util.Locale

/**
 * In-app language (SCREENS §3.9: System / Türkçe / English). API 33+: per-app locale via
 * [LocaleManager]; older devices: the activity's base context is wrapped ([wrap]).
 */
object AppLocale {
    private const val PREFS = "ui_prefs"
    private const val KEY = "app_lang"

    fun apply(context: Context, tag: String) {
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit { putString(KEY, tag) }
        if (Build.VERSION.SDK_INT >= 33) {
            context.getSystemService(LocaleManager::class.java).applicationLocales =
                if (tag.isEmpty()) LocaleList.getEmptyLocaleList() else LocaleList.forLanguageTags(tag)
        } else {
            (context as? Activity)?.recreate() ?: findActivity(context)?.recreate()
        }
    }

    fun wrap(base: Context): Context {
        if (Build.VERSION.SDK_INT >= 33) return base
        val tag = base.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getString(KEY, "").orEmpty()
        if (tag.isEmpty()) return base
        val locale = Locale.forLanguageTag(tag)
        Locale.setDefault(locale)
        val config = Configuration(base.resources.configuration)
        config.setLocale(locale)
        return base.createConfigurationContext(config)
    }

    private fun findActivity(c: Context): Activity? {
        var x: Context? = c
        while (x is android.content.ContextWrapper) {
            if (x is Activity) return x
            x = x.baseContext
        }
        return null
    }
}
