package io.iptvplayer.shared.account

import io.iptvplayer.core.CoreJson
import io.iptvplayer.core.backend.AccountRef
import io.iptvplayer.core.backend.BackendClient
import io.iptvplayer.core.backend.BackendError
import io.iptvplayer.core.backend.BackendException
import io.iptvplayer.core.backend.DevicePollResult
import io.iptvplayer.core.backend.DeviceStartResponse
import io.iptvplayer.core.backend.SessionResponse
import io.iptvplayer.core.util.Redactor
import io.iptvplayer.shared.log.SafeLog
import io.iptvplayer.shared.secure.SecretKeys
import io.iptvplayer.shared.secure.SecretStore
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlin.coroutines.cancellation.CancellationException

/** TV device-code login in progress (BACKEND_API "TV / device login"). */
data class DeviceLogin(val userCode: String, val verificationUrl: String, val verificationUrlComplete: String, val expiresAtMs: Long)

data class AccountState(
    val account: AccountRef? = null,
    val busy: Boolean = false,
    val error: BackendError? = null,
    /** E-mail the 6-digit code was sent to (code entry step). */
    val codeSentTo: String? = null,
    /** DEV_MODE backends return the code (debug builds show it to ease testing). */
    val devCode: String? = null,
    val deviceLogin: DeviceLogin? = null,
    val deviceLoginExpired: Boolean = false,
) {
    val signedIn: Boolean get() = account != null
}

/**
 * Optional app account (ARCHITECTURE §4.5): e-mail code login, TV device-code login, sign out,
 * account deletion (Apple 5.1.1(v)). The session token is stored only in the Keystore-encrypted
 * [SecretStore] and registered with the log redactor.
 */
class AccountManager(
    private val backend: BackendClient?,
    private val secrets: SecretStore,
    private val scope: CoroutineScope,
    private val deviceName: String,
    private val platform: () -> String,
    private val redactor: Redactor = Redactor.default,
    private val nowMs: () -> Long = System::currentTimeMillis,
) {
    private val _state = MutableStateFlow(AccountState())
    val state: StateFlow<AccountState> = _state
    private var pollJob: Job? = null

    /** Called after sign-in / sign-out (license re-sync, library sync). */
    var onSessionChanged: suspend (signedIn: Boolean) -> Unit = {}

    init {
        val ref = secrets.get(ACCOUNT_REF)?.let { runCatching { CoreJson.decodeFromString(AccountRef.serializer(), it) }.getOrNull() }
        if (ref != null && sessionToken() != null) _state.value = AccountState(account = ref)
        sessionToken()?.let { redactor.register(it) }
    }

    fun sessionToken(): String? = secrets.get(SecretKeys.SESSION_TOKEN)

    suspend fun startEmail(email: String, locale: String): Boolean = call {
        val r = it.emailStart(email.trim(), locale)
        _state.update { s -> s.copy(codeSentTo = email.trim(), devCode = r.devCode) }
    }

    suspend fun verifyCode(code: String): Boolean {
        val email = _state.value.codeSentTo ?: return false
        return call { signedIn(it.emailVerify(email, code.trim(), deviceName)) }
    }

    fun resetEmailFlow() = _state.update { it.copy(codeSentTo = null, devCode = null, error = null) }

    /** TV: starts the device-code flow and polls until approved / expired. */
    fun startDeviceLogin() {
        val client = backend ?: run {
            _state.update { it.copy(error = BackendError.Network(io.iptvplayer.core.error.NetworkReason.OTHER)) }
            return
        }
        pollJob?.cancel()
        pollJob = scope.launch {
            _state.update { it.copy(busy = true, error = null, deviceLogin = null, deviceLoginExpired = false) }
            val start: DeviceStartResponse = try {
                client.deviceStart(platform(), deviceName)
            } catch (e: BackendException) {
                _state.update { it.copy(busy = false, error = e.error) }
                return@launch
            }
            _state.update {
                it.copy(
                    busy = false,
                    deviceLogin = DeviceLogin(start.userCode, start.verificationUrl, start.verificationUrlComplete, nowMs() + start.expiresIn * 1000L),
                )
            }
            var interval = start.interval.coerceAtLeast(2) * 1000L
            while (true) {
                delay(interval)
                try {
                    when (val r = client.devicePoll(start.deviceCode)) {
                        DevicePollResult.Pending -> Unit
                        is DevicePollResult.SlowDown -> interval = r.intervalSec * 1000L
                        DevicePollResult.Expired -> {
                            _state.update { it.copy(deviceLogin = null, deviceLoginExpired = true) }
                            return@launch
                        }
                        is DevicePollResult.Approved -> {
                            signedIn(r.session)
                            _state.update { it.copy(deviceLogin = null) }
                            return@launch
                        }
                    }
                } catch (e: CancellationException) {
                    throw e
                } catch (e: BackendException) {
                    SafeLog.w(TAG, "device poll: ${e.error.code}")
                    if (!e.error.isRetryable) {
                        _state.update { it.copy(error = e.error, deviceLogin = null) }
                        return@launch
                    }
                }
            }
        }
    }

    fun cancelDeviceLogin() {
        pollJob?.cancel()
        _state.update { it.copy(deviceLogin = null, busy = false) }
    }

    suspend fun signOut() {
        val token = sessionToken()
        val b = backend
        if (token != null && b != null) runCatching { b.logout(token) }
        clearLocal()
    }

    suspend fun deleteAccount(): Boolean {
        val token = sessionToken() ?: return false
        val ok = call { it.deleteAccount(token) }
        if (ok) clearLocal()
        return ok
    }

    /** 401 from any account endpoint → signed out locally. */
    suspend fun onUnauthorized() = clearLocal()

    private suspend fun clearLocal() {
        sessionToken()?.let { redactor.unregister(it) }
        secrets.remove(SecretKeys.SESSION_TOKEN)
        secrets.remove(ACCOUNT_REF)
        _state.value = AccountState()
        onSessionChanged(false)
    }

    private suspend fun signedIn(s: SessionResponse) {
        secrets.put(SecretKeys.SESSION_TOKEN, s.sessionToken)
        secrets.put(ACCOUNT_REF, CoreJson.encodeToString(AccountRef.serializer(), s.account))
        redactor.register(s.sessionToken)
        _state.update { it.copy(account = s.account, codeSentTo = null, devCode = null, error = null) }
        onSessionChanged(true)
    }

    private suspend fun call(block: suspend (BackendClient) -> Unit): Boolean {
        val client = backend ?: run {
            _state.update { it.copy(error = BackendError.Network(io.iptvplayer.core.error.NetworkReason.OTHER)) }
            return false
        }
        _state.update { it.copy(busy = true, error = null) }
        return try {
            block(client)
            true
        } catch (e: BackendException) {
            SafeLog.w(TAG, "account call failed: ${e.error.code}")
            if (e.error is BackendError.Unauthorized && sessionToken() != null) clearLocal()
            _state.update { it.copy(error = e.error) }
            false
        } finally {
            _state.update { it.copy(busy = false) }
        }
    }

    companion object {
        private const val TAG = "Account"
        private const val ACCOUNT_REF = "account:ref"
    }
}
