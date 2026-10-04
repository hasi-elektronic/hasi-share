import Foundation
import IPTVCore
import Observation

/// Backend calls needed by licensing (`BackendClient` conforms; tests use fakes).
public protocol LicenseBackend: Sendable {
    func config() async throws -> BackendConfig
    func syncLicense(_ body: LicenseSyncRequest, sessionToken: String?) async throws -> LicenseSyncResponse
}

extension BackendClient: LicenseBackend {}

/// Static identity of this app install used for licensing.
public struct LicenseIdentity: Sendable, Hashable {
    public var appId: String
    public var appVersion: String
    public var deviceKey: String
    public var platform: BackendPlatform

    public init(appId: String, appVersion: String, deviceKey: String, platform: BackendPlatform) {
        self.appId = appId
        self.appVersion = appVersion
        self.deviceKey = deviceKey
        self.platform = platform
    }
}

/// Trial/purchase state of the app (CONTRACT §7). Combines the StoreKit snapshot, the last
/// verified license token (persisted, last-known fallback when the backend is unreachable) and
/// the trusted clock (server time + `CLOCK_MONOTONIC`, `kern.bootsessionuuid`), and evaluates
/// the shared `AccessPolicy`.
@MainActor
@Observable
public final class LicenseManager {
    public private(set) var decision: AccessDecision
    /// Last sync failed – UI shows "license server unreachable – using last known status".
    public private(set) var serverUnreachable = false
    public private(set) var license: VerifiedLicense?
    public private(set) var trialDays: Int
    public private(set) var store = StoreSnapshot()
    public private(set) var lastSyncAt: Date?

    @ObservationIgnored private let backend: any LicenseBackend
    @ObservationIgnored private let verifier: LicenseTokenVerifier
    @ObservationIgnored private let kv: any KeyValueStore
    @ObservationIgnored private let identity: LicenseIdentity
    @ObservationIgnored private let readClock: @Sendable () -> ClockReading
    @ObservationIgnored private var clockState: TrustedClockState?
    @ObservationIgnored public var sessionToken: @MainActor () -> String? = { nil }

    private enum Keys {
        static let token = "license.token"
        static let clock = "license.clock"
        static let trialDays = "license.trialDays"
    }

    public init(backend: any LicenseBackend, verifier: LicenseTokenVerifier, kv: any KeyValueStore,
                identity: LicenseIdentity, readClock: @escaping @Sendable () -> ClockReading = { SystemClock.read() }) {
        self.backend = backend
        self.verifier = verifier
        self.kv = kv
        self.identity = identity
        self.readClock = readClock
        self.clockState = kv.value(TrustedClockState.self, forKey: Keys.clock)
        self.trialDays = kv.value(Int.self, forKey: Keys.trialDays) ?? 7
        self.decision = AccessDecision(state: .trialNotStarted, trialEndMs: nil, canPlay: false, pendingPurchase: false)
        if let token = kv.value(String.self, forKey: Keys.token) {
            let reading = readClock()
            let now = TrustedClock.now(state: clockState, reading: reading)
            if case .success(let verified) = verifier.verify(token, now: Date(timeIntervalSince1970: Double(now) / 1000)) {
                license = verified
            } else {
                kv.set(nil, forKey: Keys.token)
            }
        }
        evaluate()
    }

    /// Trusted "now" in ms (CONTRACT §7.3).
    public func nowMs() -> Int64 {
        TrustedClock.now(state: clockState, reading: readClock())
    }

    /// Remaining trial time in ms (nil unless the trial is active).
    public var remainingTrialMs: Int64? { decision.remainingTrialMs(nowMs: nowMs()) }

    public var canPlay: Bool { decision.canPlay }

    /// New StoreKit state (purchase, approval, refund, restore).
    public func update(store snapshot: StoreSnapshot) {
        store = snapshot
        evaluate()
    }

    /// Re-evaluates the policy at the current trusted time (call when a timer fires or the
    /// app becomes active – a trial can expire while the app is open).
    public func evaluate() {
        decision = AccessPolicy.evaluate(store: store.lifetime, token: license?.claims.lic,
                                         localTrialStartMs: store.trialStartMs, trialDays: trialDays,
                                         nowMs: nowMs(), platformStore: .apple)
    }

    /// Observes a trusted server time (token `iat`, config `serverTime`).
    private func observeServerTime(ms: Int64) {
        let updated = TrustedClock.update(state: clockState, serverMs: ms, reading: readClock())
        if updated != clockState {
            clockState = updated
            kv.setValue(updated, forKey: Keys.clock)
        }
    }

    /// Fetches config (trial days) – best effort.
    public func refreshConfig() async {
        do {
            let config = try await backend.config()
            trialDays = config.trialDays
            kv.setValue(config.trialDays, forKey: Keys.trialDays)
            observeServerTime(ms: config.serverTime)
            evaluate()
        } catch {
            SafeLog.info("config unavailable")
        }
    }

    /// `POST /v1/license/sync` with the StoreKit transaction ids. On network/server failure
    /// the last known token keeps being used (`serverUnreachable = true`).
    public func sync() async {
        let apple = LicenseSyncRequest.Apple(trialTransactionId: store.trialTransactionId,
                                             transactionIds: store.transactionIds)
        let request = LicenseSyncRequest(platform: identity.platform, appId: identity.appId, appVersion: identity.appVersion,
                                         deviceKey: identity.deviceKey, startTrial: false,
                                         apple: (apple.trialTransactionId == nil && apple.transactionIds.isEmpty) ? nil : apple)
        do {
            let response = try await backend.syncLicense(request, sessionToken: sessionToken())
            observeServerTime(ms: response.serverTime)
            let now = Date(timeIntervalSince1970: Double(nowMs()) / 1000)
            switch verifier.verify(response.token, now: now) {
            case .success(let verified):
                license = verified
                kv.setValue(response.token, forKey: Keys.token)
                observeServerTime(ms: verified.claims.iat * 1000)
                serverUnreachable = response.issue?.isTransient ?? false
            case .failure(let reason):
                SafeLog.warning("license token rejected: \(reason.rawValue)")
                serverUnreachable = true
            }
            lastSyncAt = Date()
        } catch {
            SafeLog.warning("license sync failed: \(error)")
            serverUnreachable = true
        }
        evaluate()
    }

    /// Drops the stored token (account sign-out / delete changes `acct`-based access).
    public func clearToken() {
        license = nil
        kv.set(nil, forKey: Keys.token)
        evaluate()
    }
}
