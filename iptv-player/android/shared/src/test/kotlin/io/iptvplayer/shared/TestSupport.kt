package io.iptvplayer.shared

import io.iptvplayer.core.CoreJson
import io.iptvplayer.core.backend.GooglePurchase
import io.iptvplayer.core.crypto.EcKeys
import io.iptvplayer.core.crypto.EcPrivateJwk
import io.iptvplayer.core.crypto.Es256
import io.iptvplayer.core.license.LicenseClaims
import io.iptvplayer.core.license.LicenseInfo
import io.iptvplayer.core.license.StoreState
import io.iptvplayer.core.util.Base64Codec
import io.iptvplayer.shared.billing.BillingSnapshot
import io.iptvplayer.shared.billing.PurchaseEvent
import io.iptvplayer.shared.billing.StoreBilling
import io.iptvplayer.shared.license.DeviceClocks
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.serialization.json.jsonObject
import java.io.File
import java.security.interfaces.ECPrivateKey

/** Shared cross-platform vectors (spec/test-vectors). */
object Vectors {
    val dir: File = File(System.getProperty("vectors.dir") ?: "../../spec/test-vectors")
    fun text(name: String): String = dir.resolve(name).readText()

    private val licenseJson by lazy { CoreJson.parseToJsonElement(text("license-token.json")).jsonObject }

    /** Public JWK set of the test-only kid "test-1". */
    val jwkSet: String by lazy { """{"keys": ${licenseJson["keys"]}}""" }

    /** Private key of "test-1" (published in the vectors for backend tests – test only). */
    val privateKey: ECPrivateKey by lazy {
        val jwk = licenseJson["privateKeyForBackendTests"]!!.jsonObject["jwk"]!!
        EcKeys.privateKey(CoreJson.decodeFromJsonElement(EcPrivateJwk.serializer(), jwk))
    }

    /** Signs a license token like the backend does (CONTRACT §7.2). */
    fun token(claims: LicenseClaims, kid: String = "test-1"): String {
        val h = Base64Codec.encodeUrl("""{"alg":"ES256","kid":"$kid","typ":"JWT"}""".encodeToByteArray())
        val p = Base64Codec.encodeUrl(CoreJson.encodeToString(LicenseClaims.serializer(), claims).encodeToByteArray())
        val sig = Es256.sign(privateKey, "$h.$p".encodeToByteArray())
        return "$h.$p.${Base64Codec.encodeUrl(sig)}"
    }

    fun claims(sub: String, iatSec: Long, lic: LicenseInfo, aud: String = APP_ID) =
        LicenseClaims("iptvp-license", aud, sub, iatSec, iatSec + 14 * 86_400, lic)

    const val APP_ID = "de.hasielektronik.novaplayer"
}

class FakeBilling(initial: BillingSnapshot = BillingSnapshot(available = false)) : StoreBilling {
    override val state = MutableStateFlow(initial)
    override val events = MutableSharedFlow<PurchaseEvent>(extraBufferCapacity = 8)
    val acknowledged = mutableListOf<String>()
    override fun start() = Unit
    override suspend fun refreshPurchases(userInitiated: Boolean) = Unit
    override fun launchPurchase(activity: android.app.Activity) = Unit
    override suspend fun acknowledge(purchaseToken: String): Boolean {
        acknowledged += purchaseToken
        state.value = state.value.copy(unacknowledged = state.value.unacknowledged - purchaseToken)
        return true
    }

    fun purchased(token: String, acknowledged: Boolean = false) {
        state.value = state.value.copy(
            storeState = StoreState.PURCHASED,
            purchases = listOf(GooglePurchase("lifetime_access", token)),
            unacknowledged = if (acknowledged) emptyList() else listOf(token),
        )
    }
}

class FakeClocks(var wall: Long, var mono: Long = 1_000_000, var boot: String = "7") : DeviceClocks {
    override fun wallMs() = wall
    override fun monoMs() = mono
    override fun bootId() = boot
}
