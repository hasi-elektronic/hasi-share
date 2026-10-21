package io.iptvplayer.shared.pairing

import io.iptvplayer.core.backend.BackendClient
import io.iptvplayer.core.backend.BackendError
import io.iptvplayer.core.backend.BackendException
import io.iptvplayer.core.backend.PairPollResult
import io.iptvplayer.core.pairing.PairCode
import io.iptvplayer.core.pairing.PairCrypto
import io.iptvplayer.core.pairing.PairCryptoException
import io.iptvplayer.core.pairing.PairPayload
import io.iptvplayer.shared.log.SafeLog
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlin.coroutines.cancellation.CancellationException

sealed interface PairingState {
    data object Idle : PairingState
    data object Creating : PairingState

    /** Waiting for the phone: QR of [pairUrl], code [displayCode], [remainingSec] countdown (10 min). */
    data class Waiting(val displayCode: String, val pairUrl: String, val baseUrl: String, val expiresAtMs: Long, val remainingSec: Long) : PairingState

    /** Decrypted payload received – the caller adds the source. */
    data class Received(val payload: PairPayload) : PairingState
    data object Expired : PairingState
    data class Failed(val error: BackendError?) : PairingState
}

/**
 * TV pairing (CONTRACT §9): ephemeral P-256 key pair kept only in memory, session created at the
 * backend, polling every 2 s, end-to-end decryption of the payload. The backend never sees the
 * plaintext. [send] is the in-app sender for a phone that already runs the app.
 */
class PairingManager(
    private val backend: BackendClient?,
    private val scope: CoroutineScope,
    private val nowMs: () -> Long = System::currentTimeMillis,
    private val pollIntervalMs: Long = 2_000,
) {
    private val _state = MutableStateFlow<PairingState>(PairingState.Idle)
    val state: StateFlow<PairingState> = _state
    private var job: Job? = null

    fun start() {
        job?.cancel()
        val client = backend ?: run {
            _state.value = PairingState.Failed(null)
            return
        }
        job = scope.launch {
            _state.value = PairingState.Creating
            val keys = PairCrypto.generateKeyPair()
            val session = try {
                client.pairCreate(PairCrypto.publicJwk(keys))
            } catch (e: BackendException) {
                SafeLog.w(TAG, "pair create failed: ${e.error.code}")
                _state.value = PairingState.Failed(e.error)
                return@launch
            }
            // Server and device clocks may differ: derive the expiry from the TTL when given.
            val expiresAt = session.expiresIn?.let { nowMs() + it * 1000L } ?: session.expiresAt
            val base = client.baseUrl
            var lastPoll = 0L
            while (isActive) {
                val remaining = (expiresAt - nowMs()).coerceAtLeast(0) / 1000
                if (remaining <= 0) {
                    _state.value = PairingState.Expired
                    return@launch
                }
                _state.value = PairingState.Waiting(PairCode.display(session.code), session.pairUrl, "$base/pair", expiresAt, remaining)
                if (nowMs() - lastPoll >= pollIntervalMs) {
                    lastPoll = nowMs()
                    try {
                        when (val r = client.pairPoll(session.code, session.secret)) {
                            PairPollResult.Pending -> Unit
                            is PairPollResult.Ready -> {
                                val payload = try {
                                    PairCrypto.open(r.envelope, keys.private)
                                } catch (e: PairCryptoException) {
                                    SafeLog.w(TAG, "pair payload rejected: ${e.failure}")
                                    _state.value = PairingState.Failed(BackendError.InvalidResponse)
                                    return@launch
                                }
                                _state.value = PairingState.Received(payload)
                                return@launch
                            }
                            PairPollResult.Expired, PairPollResult.NotFound -> {
                                _state.value = PairingState.Expired
                                return@launch
                            }
                        }
                    } catch (e: CancellationException) {
                        throw e
                    } catch (e: BackendException) {
                        SafeLog.w(TAG, "pair poll: ${e.error.code}")
                        if (!e.error.isRetryable) {
                            _state.value = PairingState.Failed(e.error)
                            return@launch
                        }
                    }
                }
                delay(1_000)
            }
        }
    }

    fun cancel() {
        job?.cancel()
        _state.value = PairingState.Idle
    }

    /** Phone side (in-app): encrypts [payload] for the TV showing [code] and uploads it. */
    suspend fun send(code: String, payload: PairPayload): BackendError? {
        val client = backend ?: return BackendError.Network(io.iptvplayer.core.error.NetworkReason.OTHER)
        return try {
            val key = client.pairKey(code).publicKey
            client.pairSend(code, PairCrypto.encrypt(payload.toJson().encodeToByteArray(), key))
            null
        } catch (e: BackendException) {
            e.error
        }
    }

    companion object {
        private const val TAG = "Pairing"
    }
}
