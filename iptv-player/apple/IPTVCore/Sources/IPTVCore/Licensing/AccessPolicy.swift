import Foundation

/// Local store state of the lifetime product (StoreKit 2 / Play Billing).
public enum StoreState: String, Codable, Sendable, Hashable, CaseIterable {
    case none, pending, purchased, revoked
}

/// The platform's store.
public enum PlatformStore: String, Codable, Sendable, Hashable {
    case google, apple
}

/// Access state (CONTRACT §7.4).
public enum AccessState: String, Codable, Sendable, Hashable {
    case purchased = "PURCHASED"
    case trialActive = "TRIAL_ACTIVE"
    case trialExpired = "TRIAL_EXPIRED"
    case trialNotStarted = "TRIAL_NOT_STARTED"
}

/// Result of the access policy.
public struct AccessDecision: Codable, Sendable, Hashable {
    public var state: AccessState
    /// Trial end (ms) whenever known – also reported for PURCHASED/TRIAL_EXPIRED.
    public var trialEndMs: Int64?
    /// Player unlocked (PURCHASED or TRIAL_ACTIVE).
    public var canPlay: Bool
    /// Store purchase pending (banner only, grants nothing).
    public var pendingPurchase: Bool

    public init(state: AccessState, trialEndMs: Int64?, canPlay: Bool, pendingPurchase: Bool) {
        self.state = state
        self.trialEndMs = trialEndMs
        self.canPlay = canPlay
        self.pendingPurchase = pendingPurchase
    }

    /// Remaining trial time in ms at `nowMs` (nil unless TRIAL_ACTIVE).
    public func remainingTrialMs(nowMs: Int64) -> Int64? {
        guard state == .trialActive, let end = trialEndMs else { return nil }
        return max(0, end - nowMs)
    }
}

/// Access policy of CONTRACT §7.4 – a pure function, identical on every platform.
public enum AccessPolicy {
    public static let dayMs: Int64 = 86_400_000

    /// Evaluates access.
    /// - Parameters:
    ///   - store: local store state of the lifetime product.
    ///   - token: validated `lic` claims, or nil.
    ///   - localTrialStartMs: Apple only – `purchaseDate` of the verified trial transaction.
    ///   - trialDays: last known server config (default 7).
    ///   - nowMs: trusted clock.
    ///   - platformStore: `.apple` for the Apple family.
    public static func evaluate(store: StoreState, token: LicenseInfo?, localTrialStartMs: Int64?,
                                trialDays: Int = 7, nowMs: Int64, platformStore: PlatformStore) -> AccessDecision {
        let purchasedByStore = store == .purchased
        var purchasedByLicense = false
        if let token, token.purchased {
            purchasedByLicense = !(store == .revoked && token.src?.rawValue == platformStore.rawValue)
        }
        let trialEndMs: Int64? = token?.trialEnd.map { $0 * 1000 }
            ?? localTrialStartMs.map { $0 + Int64(trialDays) * dayMs }
        let state: AccessState
        if purchasedByStore || purchasedByLicense {
            state = .purchased
        } else if let end = trialEndMs {
            state = nowMs < end ? .trialActive : .trialExpired
        } else {
            state = .trialNotStarted
        }
        return AccessDecision(state: state, trialEndMs: trialEndMs,
                              canPlay: state == .purchased || state == .trialActive,
                              pendingPurchase: store == .pending)
    }
}
