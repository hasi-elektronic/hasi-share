import IPTVCore
import IPTVKit
import StoreKit
import StoreKitTest
import XCTest

/// StoreKit 2 flows against `Config/Products.storekit` (local StoreKit testing, no sandbox
/// account needed): trial "purchase", lifetime purchase, Ask to Buy (pending → approved),
/// refund (revocation) – and how the access policy reacts.
@MainActor
final class StoreKitFlowTests: XCTestCase {
    private var session: SKTestSession!
    private let ids = ProductIDs(lifetime: "com.hasielektronic.novaplayer.lifetime", trial: "com.hasielektronic.novaplayer.trial")

    override func setUp() async throws {
        // The configuration lives in this test bundle (the main bundle is the host app).
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "Products", withExtension: "storekit"))
        session = try SKTestSession(contentsOf: url)
        session.resetToDefaultState()
        session.disableDialogs = true
        session.clearTransactions()
        session.askToBuyEnabled = false
        // Local StoreKit testing needs Xcode's StoreKit test service. When it is not reachable
        // (e.g. `xcodebuild test` from the command line: storekitd logs "not entitled for
        // OctaneSaveConfigurationRequest"), products never load – skip instead of failing.
        let probe = try await Product.products(for: [ids.lifetime])
        try XCTSkipIf(probe.isEmpty, "StoreKit configuration not active – run these tests from Xcode (Product › Test)")
    }

    override func tearDown() async throws {
        session.clearTransactions()
    }

    private struct OfflineBackend: LicenseBackend {
        func config() async throws -> BackendConfig { throw BackendError.network(.offline) }
        func syncLicense(_ body: LicenseSyncRequest, sessionToken: String?) async throws -> LicenseSyncResponse {
            throw BackendError.network(.offline)
        }
    }

    private func license() throws -> LicenseManager {
        let verifier = try LicenseTokenVerifier(jwkSetJSON: Data("{}".utf8), audience: "com.hasielektronic.novaplayer")
        return LicenseManager(backend: OfflineBackend(), verifier: verifier, kv: InMemoryKeyValueStore(),
                              identity: LicenseIdentity(appId: "com.hasielektronic.novaplayer", appVersion: "1", deviceKey: "k", platform: .ios))
    }

    func testProductsLoadWithLocalizedPrice() async throws {
        let store = StoreManager(productIDs: ids, kv: InMemoryKeyValueStore())
        await store.loadProducts()
        XCTAssertNotNil(store.lifetimeProduct)
        XCTAssertNotNil(store.trialProduct)
        XCTAssertNotNil(store.lifetimePrice)
        XCTAssertEqual(store.trialProduct?.price, 0)
    }

    func testTrialThenPurchaseThenRefund() async throws {
        let store = StoreManager(productIDs: ids, kv: InMemoryKeyValueStore())
        let license = try license()
        store.onChange = { license.update(store: $0) }
        await store.loadProducts()

        XCTAssertEqual(license.decision.state, .trialNotStarted)
        let trial = await store.startTrial()
        XCTAssertEqual(trial, .success)
        XCTAssertNotNil(store.snapshot.trialStartMs)
        XCTAssertNotNil(store.snapshot.trialTransactionId)
        XCTAssertEqual(license.decision.state, .trialActive, "Apple trial = verified purchaseDate + trialDays")
        XCTAssertTrue(license.canPlay)

        let buy = await store.purchaseLifetime()
        XCTAssertEqual(buy, .success)
        XCTAssertEqual(store.snapshot.lifetime, .purchased)
        XCTAssertEqual(license.decision.state, .purchased)
        let again = await store.purchaseLifetime()
        XCTAssertEqual(again, .alreadyOwned)

        // Refund → revocationDate → lifetime revoked, back to the trial state.
        let transaction = try XCTUnwrap(session.allTransactions().first { $0.productIdentifier == ids.lifetime })
        try session.refundTransaction(identifier: transaction.identifier)
        await store.refreshEntitlements()
        XCTAssertEqual(store.snapshot.lifetime, .revoked)
        XCTAssertEqual(license.decision.state, .trialActive)
    }

    func testAskToBuyIsPendingUntilApproved() async throws {
        session.askToBuyEnabled = true
        let store = StoreManager(productIDs: ids, kv: InMemoryKeyValueStore())
        let license = try license()
        store.onChange = { license.update(store: $0) }
        await store.loadProducts()
        let outcome = await store.purchaseLifetime()
        XCTAssertEqual(outcome, .pending)
        XCTAssertEqual(store.snapshot.lifetime, .pending)
        XCTAssertTrue(license.decision.pendingPurchase)
        XCTAssertFalse(license.canPlay, "pending grants nothing")

        let pending = try XCTUnwrap(session.allTransactions().first { $0.productIdentifier == ids.lifetime })
        try session.approveAskToBuyTransaction(identifier: pending.identifier)
        // The approval arrives via Transaction.updates in the app; here we re-read entitlements.
        for _ in 0..<20 where store.snapshot.lifetime != .purchased {
            await store.refreshEntitlements()
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertEqual(store.snapshot.lifetime, .purchased)
        XCTAssertEqual(license.decision.state, .purchased)
    }

    func testFailedTransactionReportsError() async throws {
        try await session.setSimulatedError(.generic(.unknown), forAPI: .purchase)
        let store = StoreManager(productIDs: ids, kv: InMemoryKeyValueStore())
        await store.loadProducts()
        let outcome = await store.purchaseLifetime()
        if case .failed = outcome {} else { XCTFail("expected failure, got \(outcome)") }
        XCTAssertEqual(store.snapshot.lifetime, StoreState.none)
    }
}
