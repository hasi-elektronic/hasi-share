package io.iptvplayer.shared.secure

import android.content.Context
import android.content.SharedPreferences
import android.os.Build
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import androidx.core.content.edit
import io.iptvplayer.core.util.Base64Codec
import io.iptvplayer.shared.log.SafeLog
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec
import java.util.concurrent.ConcurrentHashMap

/**
 * Small key/value store for secrets (source credentials, playlist URLs, session token) –
 * docs/SECURITY.md §1. Implementations must never log values.
 */
interface SecretStore {
    fun get(key: String): String?
    fun put(key: String, value: String)
    fun remove(key: String)
    fun keys(): Set<String>
}

/** In-memory store for tests / previews. */
class InMemorySecretStore : SecretStore {
    private val map = ConcurrentHashMap<String, String>()
    override fun get(key: String): String? = map[key]
    override fun put(key: String, value: String) { map[key] = value }
    override fun remove(key: String) { map.remove(key) }
    override fun keys(): Set<String> = map.keys.toSet()
}

/**
 * Android Keystore backed store: every value is encrypted with an AES-256-GCM key that never
 * leaves the Keystore (non-exportable, API 23+). Ciphertexts (`base64(iv ‖ ct+tag)`) live in a
 * private SharedPreferences file that is excluded from cloud backup and device transfer
 * (res/xml/data_extraction_rules.xml, backup_rules.xml).
 *
 * If the key is lost (e.g. restored onto another device despite the exclusion rules) values
 * cannot be decrypted: [get] returns null and the entry is dropped – the user re-enters it.
 */
class KeystoreSecretStore(context: Context) : SecretStore {
    private val prefs: SharedPreferences = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
    private val lock = Any()

    override fun get(key: String): String? = synchronized(lock) {
        val stored = prefs.getString(key, null) ?: return null
        return try {
            val bytes = Base64Codec.decode(stored) ?: error("bad base64")
            val iv = bytes.copyOfRange(0, IV_LEN)
            val cipher = Cipher.getInstance(TRANSFORMATION)
            cipher.init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(TAG_BITS, iv))
            cipher.updateAAD(key.encodeToByteArray())
            cipher.doFinal(bytes, IV_LEN, bytes.size - IV_LEN).decodeToString()
        } catch (e: Exception) {
            SafeLog.w(TAG, "cannot decrypt entry – dropping it (${e.javaClass.simpleName})")
            prefs.edit { remove(key) }
            null
        }
    }

    override fun put(key: String, value: String) = synchronized(lock) {
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.ENCRYPT_MODE, key())
        cipher.updateAAD(key.encodeToByteArray())
        val ct = cipher.doFinal(value.encodeToByteArray())
        val iv = cipher.iv
        check(iv.size == IV_LEN) { "unexpected IV length" }
        prefs.edit { putString(key, Base64Codec.encodeStd(iv + ct)) }
    }

    override fun remove(key: String) = synchronized(lock) { prefs.edit { remove(key) } }

    override fun keys(): Set<String> = prefs.all.keys.toSet()

    private fun key(): SecretKey {
        val ks = KeyStore.getInstance(KEYSTORE).apply { load(null) }
        (ks.getKey(ALIAS, null) as? SecretKey)?.let { return it }
        val gen = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, KEYSTORE)
        val spec = KeyGenParameterSpec.Builder(ALIAS, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
            .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
            .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
            .setKeySize(256)
            .setRandomizedEncryptionRequired(true)
            .apply { if (Build.VERSION.SDK_INT >= 28) setUnlockedDeviceRequired(false) }
            .build()
        gen.init(spec)
        return gen.generateKey()
    }

    companion object {
        /** SharedPreferences file name (referenced by the backup exclusion rules). */
        const val PREFS = "secure_store"
        private const val TAG = "SecureStore"
        private const val KEYSTORE = "AndroidKeyStore"
        private const val ALIAS = "iptvp_secure_v1"
        private const val TRANSFORMATION = "AES/GCM/NoPadding"
        private const val IV_LEN = 12
        private const val TAG_BITS = 128
    }
}

/** Typed keys used in the [SecretStore]. */
object SecretKeys {
    fun source(sourceId: String) = "source:$sourceId"
    const val SESSION_TOKEN = "account:session"
}
