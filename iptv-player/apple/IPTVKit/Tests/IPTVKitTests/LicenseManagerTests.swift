import Foundation
import IPTVCore
import XCTest
@testable import IPTVKit

/// Backend fake returning a scripted token or failing.
final class FakeLicenseBackend: LicenseBackend, @unchecked Sendable {
    private let lock = NSLock()
    var response: LicenseSyncResponse?
    var error: Error?
    var requests: [LicenseSyncRequest] = []

    func config() async throws -> BackendConfig {
        BackendConfig(trialDays: 7, minVersion: .init(android: 1, apple: 1), products: .init(),
                      features: .init(accounts: true, pairing: true, sync: true), serverTime: 0)
    }

    func syncLicense(_ body: LicenseSyncRequest, sessionToken: String?) async throws -> LicenseSyncResponse {
        let (error, response) = lock.withLock { () -> (Error?, LicenseSyncResponse?) in
            requests.append(body)
            return (self.error, self.response)
        }
        if let error { throw error }
        return response!
    }
}

@MainActor
final class LicenseManagerTests: XCTestCase {
    let day: Int64 = 86_400_000
    let t0: Int64 = 1_759_570_000_000

    private func make(_ backend: FakeLicenseBackend, _ signer: TestSigner, _ clock: TestClock, kv: InMemoryKeyValueStore = InMemoryKeyValueStore()) throws -> LicenseManager {
        let verifier = try LicenseTokenVerifier(jwkSetJSON: signer.jwkSetJSON, audience: "de.hasielektronik.novaplayer")
        return LicenseManager(backend: backend, verifier: verifier, kv: kv,
                              identity: LicenseIdentity(appId: "de.hasielektronik.novaplayer", appVersion: "1.0 (1)",
                                                        deviceKey: "dev", platform: .ios),
                              readClock: { clock.read() })
    }

    func testTesterFullAccessUnlocksAndCanBeTurnedOff() throws {
        let clock = TestClock(wallMs: t0)
        let manager = try make(FakeLicenseBackend(), TestSigner(), clock)
        XCTAssertFalse(manager.canPlay)

        manager.testerFullAccess = true
        XCTAssertEqual(manager.decision.state, .purchased)
        XCTAssertTrue(manager.canPlay)
        // Survives re-evaluation (timer / foreground) and store updates.
        clock.advance(ms: 30 * day)
        manager.evaluate()
        manager.update(store: StoreSnapshot())
        XCTAssertTrue(manager.canPlay)

        manager.testerFullAccess = false
        XCTAssertEqual(manager.decision.state, .trialNotStarted)
        XCTAssertFalse(manager.canPlay)
    }

    func testStoreTrialPurchaseAndRefundTransitions() throws {
        let clock = TestClock(wallMs: t0)
        let manager = try make(FakeLicenseBackend(), TestSigner(), clock)
        XCTAssertEqual(manager.decision.state, .trialNotStarted)
        XCTAssertFalse(manager.canPlay)

        // StoreKit trial "purchase" → TRIAL_ACTIVE for trialDays (local fallback without token).
        manager.update(store: StoreSnapshot(trialStartMs: t0, trialTransactionId: "200"))
        XCTAssertEqual(manager.decision.state, .trialActive)
        XCTAssertEqual(manager.remainingTrialMs, 7 * day)

        clock.advance(ms: 7 * day)
        manager.evaluate()
        XCTAssertEqual(manager.decision.state, .trialExpired)
        XCTAssertFalse(manager.canPlay)

        manager.update(store: StoreSnapshot(lifetime: .pending, trialStartMs: t0))
        XCTAssertEqual(manager.decision.state, .trialExpired)
        XCTAssertTrue(manager.decision.pendingPurchase)

        manager.update(store: StoreSnapshot(lifetime: .purchased, trialStartMs: t0, transactionIds: ["300"]))
        XCTAssertEqual(manager.decision.state, .purchased)
        XCTAssertTrue(manager.canPlay)

        manager.update(store: StoreSnapshot(lifetime: .revoked, trialStartMs: t0, transactionIds: ["300"]))
        XCTAssertEqual(manager.decision.state, .trialExpired, "refund falls back to the trial state")
    }

    func testTokenFromBackendAndLastKnownFallback() async throws {
        let clock = TestClock(wallMs: t0)
        let signer = TestSigner()
        let backend = FakeLicenseBackend()
        let iat = t0 / 1000
        backend.response = LicenseSyncResponse(
            token: signer.token(iat: iat, exp: iat + 14 * 86_400,
                                lic: LicenseInfo(purchased: false, trialStart: iat, trialEnd: iat + 7 * 86_400)),
            license: LicenseInfo(purchased: false), serverTime: t0)
        let kv = InMemoryKeyValueStore()
        let manager = try make(backend, signer, clock, kv: kv)
        manager.update(store: StoreSnapshot(trialStartMs: t0, trialTransactionId: "200"))
        await manager.sync()
        XCTAssertEqual(backend.requests.first?.apple?.trialTransactionId, "200")
        XCTAssertEqual(backend.requests.first?.platform, .ios)
        XCTAssertFalse(manager.serverUnreachable)
        XCTAssertEqual(manager.decision.state, .trialActive)
        XCTAssertEqual(manager.decision.trialEndMs, (iat + 7 * 86_400) * 1000)

        // Backend down: the persisted token is used by a fresh manager (app restart).
        backend.error = BackendError.network(.offline)
        let restarted = try make(backend, signer, clock, kv: kv)
        await restarted.sync()
        XCTAssertTrue(restarted.serverUnreachable)
        XCTAssertNotNil(restarted.license)
        XCTAssertEqual(restarted.decision.state, .trialActive)
    }

    func testRollingBackDeviceClockDoesNotExtendTrial() async throws {
        let clock = TestClock(wallMs: t0, monoMs: 5_000, bootId: "boot-A")
        let signer = TestSigner()
        let backend = FakeLicenseBackend()
        let iat = t0 / 1000
        backend.response = LicenseSyncResponse(
            token: signer.token(iat: iat, exp: iat + 30 * 86_400, lic: LicenseInfo(purchased: false, trialStart: iat, trialEnd: iat + 86_400)),
            license: LicenseInfo(purchased: false), serverTime: t0)
        let manager = try make(backend, signer, clock)
        await manager.sync()
        XCTAssertEqual(manager.decision.state, .trialActive)
        // Two days pass on the monotonic clock while the user sets the wall clock back.
        clock.set(ClockReading(wallMs: t0 - 10 * day, monoMs: 5_000 + 2 * day, bootId: "boot-A"))
        manager.evaluate()
        XCTAssertEqual(manager.decision.state, .trialExpired)
        // After a reboot the wall clock cannot go behind the last server time.
        clock.set(ClockReading(wallMs: t0 - 10 * day, monoMs: 10, bootId: "boot-B"))
        XCTAssertEqual(manager.nowMs(), t0)
    }

    func testPurchasedByAccountTokenIgnoresLocalRevokeOfOtherStore() async throws {
        let clock = TestClock(wallMs: t0)
        let signer = TestSigner()
        let backend = FakeLicenseBackend()
        let iat = t0 / 1000
        backend.response = LicenseSyncResponse(
            token: signer.token(iat: iat, exp: iat + 86_400, lic: LicenseInfo(purchased: true, src: .account)),
            license: LicenseInfo(purchased: true, src: .account), serverTime: t0)
        let manager = try make(backend, signer, clock)
        manager.update(store: StoreSnapshot(lifetime: .revoked))
        await manager.sync()
        XCTAssertEqual(manager.decision.state, .purchased)
    }

    func testRejectsTokenSignedByUnknownKey() async throws {
        let clock = TestClock(wallMs: t0)
        let backend = FakeLicenseBackend()
        let iat = t0 / 1000
        backend.response = LicenseSyncResponse(
            token: TestSigner().token(iat: iat, exp: iat + 86_400, lic: LicenseInfo(purchased: true, src: .admin)),
            license: LicenseInfo(purchased: true), serverTime: t0)
        let manager = try make(backend, TestSigner(), clock)
        await manager.sync()
        XCTAssertNil(manager.license)
        XCTAssertEqual(manager.decision.state, .trialNotStarted)
    }
}
