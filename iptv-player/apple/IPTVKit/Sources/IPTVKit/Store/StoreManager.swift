import Foundation
import IPTVCore
import Observation
import StoreKit

/// What the store currently says about our two non-consumables (input of the license logic).
public struct StoreSnapshot: Sendable, Hashable, Codable {
    /// Local state of the lifetime product (CONTRACT §7.4 `store`).
    public var lifetime: StoreState
    /// `purchaseDate` of the verified trial transaction (ms) – `localTrialStartMs`.
    public var trialStartMs: Int64?
    /// Trial transaction id (sent to `/v1/license/sync`).
    public var trialTransactionId: String?
    /// Verified (also revoked) transaction ids of the lifetime product.
    public var transactionIds: [String]

    public init(lifetime: StoreState = .none, trialStartMs: Int64? = nil, trialTransactionId: String? = nil,
                transactionIds: [String] = []) {
        self.lifetime = lifetime
        self.trialStartMs = trialStartMs
        self.trialTransactionId = trialTransactionId
        self.transactionIds = transactionIds
    }
}

/// Result of a purchase attempt (docs/SCREENS.md §3.8).
public enum PurchaseOutcome: Sendable, Hashable {
    case success
    case pending
    case cancelled
    case alreadyOwned
    case nothingToRestore
    case failed(String)
    case unavailable
}

/// Product identifiers (from `Shared.xcconfig` via Info.plist).
public struct ProductIDs: Sendable, Hashable {
    public var lifetime: String
    public var trial: String
    public init(lifetime: String, trial: String) {
        self.lifetime = lifetime
        self.trial = trial
    }
}

/// StoreKit 2 integration: lifetime non-consumable + free (tier 0) trial non-consumable,
/// pending purchases (Ask to Buy / SCA), `Transaction.updates`, restore via `AppStore.sync()`
/// and refunds (`revocationDate`). Publishes a `StoreSnapshot` for the `LicenseManager`.
@MainActor
@Observable
public final class StoreManager {
    public let productIDs: ProductIDs
    public private(set) var lifetimeProduct: Product?
    public private(set) var trialProduct: Product?
    public private(set) var snapshot = StoreSnapshot()
    public private(set) var isLoadingProducts = false
    public private(set) var productsError: String?
    public private(set) var purchaseInProgress = false
    /// true once the first entitlement read finished (the snapshot is then authoritative for the license).
    public private(set) var entitlementsLoaded = false

    /// Called after every snapshot change.
    @ObservationIgnored public var onChange: (@MainActor (StoreSnapshot) -> Void)?

    @ObservationIgnored private var updatesTask: Task<Void, Never>?
    @ObservationIgnored private let kv: any KeyValueStore
    private static let pendingKey = "store.pendingLifetime"

    public init(productIDs: ProductIDs, kv: any KeyValueStore) {
        self.productIDs = productIDs
        self.kv = kv
        if kv.value(Bool.self, forKey: Self.pendingKey) == true { snapshot.lifetime = .pending }
    }

    /// Starts the `Transaction.updates` listener (approvals of pending purchases, refunds,
    /// purchases on other devices) and loads products + entitlements.
    public func start() {
        guard updatesTask == nil else { return }
        updatesTask = Task { [weak self] in
            for await update in Transaction.updates {
                if case .verified(let transaction) = update {
                    await transaction.finish()
                }
                await self?.refreshEntitlements()
            }
        }
        // Entitlements first (local, fast – QuickStart waits for them); products are only needed for the paywall.
        Task {
            await refreshEntitlements()
            await loadProducts()
        }
    }

    /// Waits until the first entitlement read finished (or `timeout`). Returns whether it did.
    public func waitForEntitlements(timeout: Duration) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while !entitlementsLoaded {
            if ContinuousClock.now >= deadline { return false }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return true
    }

    /// Marks the first entitlement read as done (also used by tests).
    func markEntitlementsLoaded() { entitlementsLoaded = true }

    /// Localized price of the lifetime unlock ("₺99,99"), nil until loaded.
    public var lifetimePrice: String? { lifetimeProduct?.displayPrice }

    public func loadProducts() async {
        isLoadingProducts = true
        defer { isLoadingProducts = false }
        do {
            let products = try await Product.products(for: [productIDs.lifetime, productIDs.trial])
            lifetimeProduct = products.first { $0.id == productIDs.lifetime }
            trialProduct = products.first { $0.id == productIDs.trial }
            productsError = products.isEmpty ? "no products" : nil
        } catch {
            productsError = String(describing: error)
            SafeLog.warning("products failed: \(error)")
        }
    }

    /// Re-reads entitlements: current entitlements + latest transactions (for revocations).
    public func refreshEntitlements() async {
        var next = StoreSnapshot()
        var lifetimeOwned = false
        for await result in Transaction.currentEntitlements {
            guard case .verified(let t) = result else { continue }
            if t.productID == productIDs.lifetime, t.revocationDate == nil {
                lifetimeOwned = true
                next.transactionIds.append(String(t.originalID))
            } else if t.productID == productIDs.trial, t.revocationDate == nil {
                next.trialStartMs = Int64((t.purchaseDate.timeIntervalSince1970 * 1000).rounded())
                next.trialTransactionId = String(t.originalID)
            }
        }
        if lifetimeOwned {
            next.lifetime = .purchased
            kv.setValue(Bool?.none, forKey: Self.pendingKey)
        } else if let latest = await Transaction.latest(for: productIDs.lifetime),
                  case .verified(let t) = latest, t.revocationDate != nil {
            next.lifetime = .revoked
            next.transactionIds.append(String(t.originalID))
            kv.setValue(Bool?.none, forKey: Self.pendingKey)
        } else if kv.value(Bool.self, forKey: Self.pendingKey) == true {
            next.lifetime = .pending
        }
        if next.trialStartMs == nil, let latestTrial = await Transaction.latest(for: productIDs.trial),
           case .verified(let t) = latestTrial, t.revocationDate == nil {
            next.trialStartMs = Int64((t.purchaseDate.timeIntervalSince1970 * 1000).rounded())
            next.trialTransactionId = String(t.originalID)
        }
        setSnapshot(next)
        entitlementsLoaded = true
    }

    private func setSnapshot(_ value: StoreSnapshot) {
        guard value != snapshot else { return }
        snapshot = value
        onChange?(value)
    }

    /// Buys the lifetime unlock.
    public func purchaseLifetime() async -> PurchaseOutcome {
        if snapshot.lifetime == .purchased { return .alreadyOwned }
        if lifetimeProduct == nil { await loadProducts() }
        guard let product = lifetimeProduct else { return .unavailable }
        return await purchase(product, isLifetime: true)
    }

    /// "Buys" the free trial product (Apple guideline 3.1.1, CONTRACT §7.5).
    public func startTrial() async -> PurchaseOutcome {
        if snapshot.trialStartMs != nil { return .alreadyOwned }
        if trialProduct == nil { await loadProducts() }
        guard let product = trialProduct else { return .unavailable }
        return await purchase(product, isLifetime: false)
    }

    private func purchase(_ product: Product, isLifetime: Bool) async -> PurchaseOutcome {
        purchaseInProgress = true
        defer { purchaseInProgress = false }
        do {
            let result = try await product.purchase()
            switch result {
            case .success(.verified(let transaction)):
                await transaction.finish()
                await refreshEntitlements()
                return .success
            case .success(.unverified(_, let error)):
                return .failed(String(describing: error))
            case .pending:
                if isLifetime {
                    kv.setValue(true, forKey: Self.pendingKey)
                    var s = snapshot
                    s.lifetime = .pending
                    setSnapshot(s)
                }
                return .pending
            case .userCancelled:
                return .cancelled
            @unknown default:
                return .failed("unknown")
            }
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// Restore: `AppStore.sync()` then re-read entitlements.
    public func restore() async -> PurchaseOutcome {
        do {
            try await AppStore.sync()
        } catch {
            if (error as? StoreKitError).map({ if case .userCancelled = $0 { return true } else { return false } }) == true {
                return .cancelled
            }
            SafeLog.warning("AppStore.sync failed: \(error)")
        }
        await refreshEntitlements()
        return snapshot.lifetime == .purchased ? .success : .nothingToRestore
    }
}
