package io.iptvplayer.shared.billing

import android.app.Activity
import android.content.Context
import com.android.billingclient.api.AcknowledgePurchaseParams
import com.android.billingclient.api.BillingClient
import com.android.billingclient.api.BillingClient.BillingResponseCode
import com.android.billingclient.api.BillingClientStateListener
import com.android.billingclient.api.BillingFlowParams
import com.android.billingclient.api.BillingResult
import com.android.billingclient.api.PendingPurchasesParams
import com.android.billingclient.api.ProductDetails
import com.android.billingclient.api.Purchase
import com.android.billingclient.api.PurchasesUpdatedListener
import com.android.billingclient.api.QueryProductDetailsParams
import com.android.billingclient.api.QueryPurchasesParams
import io.iptvplayer.core.backend.GooglePurchase
import io.iptvplayer.core.license.StoreState
import io.iptvplayer.shared.log.SafeLog
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlin.coroutines.resume

/** Store-side state of the lifetime product (CONTRACT §7.4 `store`). */
data class BillingSnapshot(
    /** null = still connecting; false = Play Store unavailable (no Play services / not signed in). */
    val available: Boolean? = null,
    val storeState: StoreState = StoreState.NONE,
    /** Verified purchases of the lifetime product (sent to `/v1/license/sync`). */
    val purchases: List<GooglePurchase> = emptyList(),
    /** Purchase tokens not yet acknowledged (acknowledge fallback, CONTRACT §7.6). */
    val unacknowledged: List<String> = emptyList(),
    /** Local formatted price, e.g. "₺149,99". */
    val formattedPrice: String? = null,
)

/** One-shot purchase results for the UI (SCREENS §3.8). */
sealed interface PurchaseEvent {
    data object Purchased : PurchaseEvent
    data object Pending : PurchaseEvent
    data object Cancelled : PurchaseEvent
    data object AlreadyOwned : PurchaseEvent
    data object Unavailable : PurchaseEvent
    data object Restored : PurchaseEvent
    data object NothingToRestore : PurchaseEvent
    data class Failed(val message: String) : PurchaseEvent
}

/** Store abstraction (Play Billing on Android; fakes in tests). */
interface StoreBilling {
    val state: StateFlow<BillingSnapshot>
    val events: SharedFlow<PurchaseEvent>
    fun start()
    suspend fun refreshPurchases(userInitiated: Boolean = false)
    fun launchPurchase(activity: Activity)
    suspend fun acknowledge(purchaseToken: String): Boolean
}

/**
 * Play Billing 8 (CONTRACT §7.6): INAPP [productId] (`lifetime_access`), never consumed.
 * * pending purchases enabled for one-time products → [StoreState.PENDING] banner;
 * * purchases are restored with `queryPurchasesAsync` on every start and on "Restore";
 * * acknowledgement is done by the backend; [acknowledge] is the client fallback when the
 *   backend is unreachable (avoids the 3-day automatic refund).
 * Auto service reconnection (Billing 8) keeps the connection alive.
 */
class BillingManager(
    context: Context,
    private val productId: String,
    private val scope: CoroutineScope,
) : StoreBilling {
    private val _state = MutableStateFlow(BillingSnapshot())
    override val state: StateFlow<BillingSnapshot> = _state
    private val _events = MutableSharedFlow<PurchaseEvent>(extraBufferCapacity = 8)
    override val events: SharedFlow<PurchaseEvent> = _events
    private var productDetails: ProductDetails? = null

    private val purchasesListener = PurchasesUpdatedListener { result, purchases ->
        when (result.responseCode) {
            BillingResponseCode.OK -> {
                val mine = purchases.orEmpty().filter { productId in it.products }
                apply(mine)
                _events.tryEmit(
                    when {
                        mine.any { it.purchaseState == Purchase.PurchaseState.PURCHASED } -> PurchaseEvent.Purchased
                        mine.any { it.purchaseState == Purchase.PurchaseState.PENDING } -> PurchaseEvent.Pending
                        else -> PurchaseEvent.Failed("no purchase")
                    },
                )
            }
            BillingResponseCode.USER_CANCELED -> _events.tryEmit(PurchaseEvent.Cancelled)
            BillingResponseCode.ITEM_ALREADY_OWNED -> {
                _events.tryEmit(PurchaseEvent.AlreadyOwned)
                scope.launch { refreshPurchases() }
            }
            BillingResponseCode.BILLING_UNAVAILABLE, BillingResponseCode.SERVICE_UNAVAILABLE -> _events.tryEmit(PurchaseEvent.Unavailable)
            else -> _events.tryEmit(PurchaseEvent.Failed(result.debugMessage.ifBlank { "code ${result.responseCode}" }))
        }
    }

    private val client: BillingClient = BillingClient.newBuilder(context.applicationContext)
        .setListener(purchasesListener)
        .enablePendingPurchases(PendingPurchasesParams.newBuilder().enableOneTimeProducts().build())
        .enableAutoServiceReconnection()
        .build()

    override fun start() {
        if (client.isReady) {
            scope.launch { refreshPurchases() }
            return
        }
        client.startConnection(object : BillingClientStateListener {
            override fun onBillingSetupFinished(result: BillingResult) {
                if (result.responseCode == BillingResponseCode.OK) {
                    _state.update { it.copy(available = true) }
                    scope.launch {
                        queryProduct()
                        refreshPurchases()
                    }
                } else {
                    SafeLog.w(TAG, "billing unavailable: ${result.responseCode}")
                    _state.update { it.copy(available = false) }
                }
            }

            override fun onBillingServiceDisconnected() {
                SafeLog.i(TAG, "billing service disconnected")
            }
        })
    }

    private suspend fun queryProduct() {
        val params = QueryProductDetailsParams.newBuilder().setProductList(
            listOf(QueryProductDetailsParams.Product.newBuilder().setProductId(productId).setProductType(BillingClient.ProductType.INAPP).build()),
        ).build()
        val details = suspendCancellableCoroutine<ProductDetails?> { cont ->
            client.queryProductDetailsAsync(params) { result, r ->
                cont.resume(if (result.responseCode == BillingResponseCode.OK) r.productDetailsList.firstOrNull() else null)
            }
        }
        productDetails = details
        @Suppress("DEPRECATION")
        val price = details?.oneTimePurchaseOfferDetails?.formattedPrice
        _state.update { it.copy(formattedPrice = price) }
    }

    override suspend fun refreshPurchases(userInitiated: Boolean) {
        if (!client.isReady) {
            if (userInitiated) _events.tryEmit(PurchaseEvent.Unavailable)
            return
        }
        val list = suspendCancellableCoroutine<List<Purchase>?> { cont ->
            client.queryPurchasesAsync(QueryPurchasesParams.newBuilder().setProductType(BillingClient.ProductType.INAPP).build()) { r, p ->
                cont.resume(if (r.responseCode == BillingResponseCode.OK) p else null)
            }
        } ?: return
        val mine = list.filter { productId in it.products }
        apply(mine)
        if (userInitiated) {
            _events.tryEmit(if (mine.any { it.purchaseState == Purchase.PurchaseState.PURCHASED }) PurchaseEvent.Restored else PurchaseEvent.NothingToRestore)
        }
    }

    private fun apply(purchases: List<Purchase>) {
        val purchased = purchases.filter { it.purchaseState == Purchase.PurchaseState.PURCHASED }
        val pending = purchases.any { it.purchaseState == Purchase.PurchaseState.PENDING }
        _state.update {
            it.copy(
                storeState = when {
                    purchased.isNotEmpty() -> StoreState.PURCHASED
                    pending -> StoreState.PENDING
                    else -> StoreState.NONE
                },
                purchases = purchased.map { p -> GooglePurchase(productId, p.purchaseToken) },
                unacknowledged = purchased.filterNot { p -> p.isAcknowledged }.map { p -> p.purchaseToken },
            )
        }
    }

    override fun launchPurchase(activity: Activity) {
        val pd = productDetails
        if (!client.isReady || pd == null) {
            _events.tryEmit(PurchaseEvent.Unavailable)
            return
        }
        val params = BillingFlowParams.newBuilder()
            .setProductDetailsParamsList(listOf(BillingFlowParams.ProductDetailsParams.newBuilder().setProductDetails(pd).build()))
            .build()
        val r = client.launchBillingFlow(activity, params)
        if (r.responseCode != BillingResponseCode.OK) purchasesListener.onPurchasesUpdated(r, null)
    }

    override suspend fun acknowledge(purchaseToken: String): Boolean {
        if (!client.isReady) return false
        val ok = suspendCancellableCoroutine { cont ->
            client.acknowledgePurchase(AcknowledgePurchaseParams.newBuilder().setPurchaseToken(purchaseToken).build()) { r ->
                cont.resume(r.responseCode == BillingResponseCode.OK)
            }
        }
        if (ok) _state.update { it.copy(unacknowledged = it.unacknowledged - purchaseToken) }
        return ok
    }

    companion object {
        private const val TAG = "Billing"
    }
}
