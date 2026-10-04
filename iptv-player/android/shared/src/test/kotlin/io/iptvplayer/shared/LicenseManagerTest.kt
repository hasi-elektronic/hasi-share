package io.iptvplayer.shared

import io.iptvplayer.core.backend.BackendClient
import io.iptvplayer.core.license.AccessState
import io.iptvplayer.core.license.LicenseInfo
import io.iptvplayer.core.license.LicenseTokenVerifier
import io.iptvplayer.core.util.DeviceKey
import io.iptvplayer.shared.license.LicenseManager
import io.iptvplayer.shared.license.TrialStartResult
import io.iptvplayer.shared.settings.InMemorySettings
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import okhttp3.OkHttpClient
import okhttp3.mockwebserver.Dispatcher
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okhttp3.mockwebserver.RecordedRequest
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/** LicenseManager state transitions (CONTRACT §7, ARCHITECTURE §4, V9). */
@OptIn(ExperimentalCoroutinesApi::class)
class LicenseManagerTest {
    private val server = MockWebServer()
    private val deviceKey = DeviceKey.compute(Vectors.APP_ID, "android-id-1")
    private val now = 1_759_570_000_000L
    private var trialStarted = false
    private var tokenOverride: String? = null
    private var down = false
    private val syncBodies = mutableListOf<String>()

    @Before
    fun setUp() {
        server.dispatcher = object : Dispatcher() {
            override fun dispatch(request: RecordedRequest): MockResponse {
                if (down) return MockResponse().setResponseCode(503).setBody("""{"error":"unavailable"}""")
                return when (request.path) {
                    "/v1/config" -> MockResponse().setBody("""{"trialDays":7,"serverTime":$now}""")
                    "/v1/license/sync" -> {
                        val body = request.body.readUtf8()
                        syncBodies += body
                        if (body.contains("\"startTrial\":true")) trialStarted = true
                        val lic = if (trialStarted) LicenseInfo(trialStart = now / 1000, trialEnd = now / 1000 + 7 * 86_400) else LicenseInfo()
                        val token = tokenOverride ?: Vectors.token(Vectors.claims(deviceKey, now / 1000, lic))
                        MockResponse().setBody("""{"token":"$token","license":{"purchased":false},"serverTime":$now}""")
                    }
                    else -> MockResponse().setResponseCode(404)
                }
            }
        }
        server.start()
    }

    @After
    fun tearDown() = server.shutdown()

    private fun manager(scope: TestScope, settings: InMemorySettings, billing: FakeBilling, clocks: FakeClocks, backendUp: Boolean = true) = LicenseManager(
        backend = if (backendUp) BackendClient(server.url("/").toString(), OkHttpClient(), dispatcher = Dispatchers.Unconfined) else null,
        billing = billing,
        settings = settings,
        verifier = LicenseTokenVerifier.fromJwkSet(Vectors.jwkSet, Vectors.APP_ID),
        clocks = clocks,
        deviceKey = { deviceKey },
        appId = Vectors.APP_ID,
        appVersion = "1.0.0 (1)",
        platform = { "android" },
        sessionToken = { null },
        scope = scope.backgroundScope,
    )

    @Test
    fun noBackendAndNoToken_trialCannotStart() = runTest(StandardTestDispatcher()) {
        val m = manager(this, InMemorySettings(), FakeBilling(), FakeClocks(now), backendUp = false)
        m.start()
        runCurrent()
        assertEquals(AccessState.TRIAL_NOT_STARTED, m.state.value.decision.state)
        assertFalse(m.state.value.canPlay)
        val r = m.startTrial()
        assertTrue(r is TrialStartResult.BackendUnavailable)
    }

    @Test
    fun startTrial_activeThenLastKnownTokenWhenBackendDown_thenExpiresByTrustedClock() = runTest(StandardTestDispatcher()) {
        val settings = InMemorySettings()
        val clocks = FakeClocks(now)
        val m = manager(this, settings, FakeBilling(), clocks)
        m.start()
        runCurrent()
        assertEquals(AccessState.TRIAL_NOT_STARTED, m.state.value.decision.state)
        assertEquals(TrialStartResult.Started, m.startTrial())
        assertEquals(AccessState.TRIAL_ACTIVE, m.state.value.decision.state)
        assertTrue(syncBodies.last().contains("\"startTrial\":true"))
        assertTrue(settings.licenseCache().token != null)

        // App restart, backend unreachable → last known token is used.
        down = true
        val m2 = manager(this, settings, FakeBilling(), clocks)
        m2.start()
        runCurrent()
        assertEquals(AccessState.TRIAL_ACTIVE, m2.state.value.decision.state)
        assertTrue(m2.state.value.backendError != null)

        // Rolling the wall clock back does not extend the trial: 8 days of monotonic time pass.
        clocks.mono += 8 * 86_400_000L
        clocks.wall = now - 86_400_000L
        val m3 = manager(this, settings, FakeBilling(), clocks)
        m3.start()
        runCurrent()
        assertEquals(AccessState.TRIAL_EXPIRED, m3.state.value.decision.state)
        assertEquals(TrialStartResult.AlreadyUsed, m3.startTrial())
    }

    @Test
    fun storePurchase_grantsAccess_andAcknowledgesWhenBackendDown() = runTest(StandardTestDispatcher()) {
        down = true
        val billing = FakeBilling().apply { purchased("tok-1") }
        val m = manager(this, InMemorySettings(), billing, FakeClocks(now))
        m.start()
        runCurrent()
        assertEquals(AccessState.PURCHASED, m.state.value.decision.state)
        assertEquals(listOf("tok-1"), billing.acknowledged)
    }

    @Test
    fun foreignOrTamperedToken_isRejected() = runTest(StandardTestDispatcher()) {
        val other = DeviceKey.compute(Vectors.APP_ID, "other-device")
        tokenOverride = Vectors.token(Vectors.claims(other, now / 1000, LicenseInfo(purchased = true, src = "admin")))
        val m = manager(this, InMemorySettings(), FakeBilling(), FakeClocks(now))
        m.start()
        runCurrent()
        assertFalse(m.state.value.hasToken)
        assertEquals(AccessState.TRIAL_NOT_STARTED, m.state.value.decision.state)

        tokenOverride = Vectors.token(Vectors.claims(deviceKey, now / 1000, LicenseInfo(purchased = true, src = "admin")), kid = "unknown")
        m.sync()
        assertFalse(m.state.value.hasToken)

        tokenOverride = Vectors.token(Vectors.claims(deviceKey, now / 1000, LicenseInfo(purchased = true, src = "account")))
        m.sync()
        assertEquals(AccessState.PURCHASED, m.state.value.decision.state)
        assertEquals("account", m.state.value.purchaseSource)
    }

    @Test
    fun pendingPurchase_isBannerOnly() = runTest(StandardTestDispatcher()) {
        down = true
        val billing = FakeBilling()
        billing.state.value = billing.state.value.copy(storeState = io.iptvplayer.core.license.StoreState.PENDING)
        val m = manager(this, InMemorySettings(), billing, FakeClocks(now))
        m.start()
        runCurrent()
        assertTrue(m.state.value.decision.pendingPurchase)
        assertFalse(m.state.value.canPlay)
    }
}
