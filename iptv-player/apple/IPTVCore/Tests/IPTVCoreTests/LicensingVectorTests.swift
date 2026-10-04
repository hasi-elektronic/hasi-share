import Foundation
import XCTest
@testable import IPTVCore

/// CONTRACT §7 – `license-token.json`, `trusted-clock.json`, `access-policy.json`.
final class LicensingVectorTests: XCTestCase {
    // MARK: §7.2 License token (ES256 via CryptoKit)

    func testLicenseTokenVectors() throws {
        let root = try Vectors.object("license-token.json")
        let keysJSON = try JSONSerialization.data(withJSONObject: try XCTUnwrap(root["keys"]))
        let verifier = try LicenseTokenVerifier(jwkSetJSON: keysJSON, audience: try XCTUnwrap(root.str("audience")),
                                                issuer: try XCTUnwrap(root.str("issuer")))
        XCTAssertEqual(root.str("issuer"), ProtocolConstants.licenseIssuer)
        let cases = try XCTUnwrap(root.arr("cases"))
        XCTAssertEqual(cases.count, 10)
        for c in cases {
            let name = try XCTUnwrap(c.str("name"))
            let token = try XCTUnwrap(c.str("token"))
            let now = Date(timeIntervalSince1970: TimeInterval(try XCTUnwrap(c.int64("nowEpochSeconds"))))
            let expected = try XCTUnwrap(c.obj("expected"))
            switch verifier.verify(token, now: now) {
            case .success(let license):
                XCTAssertEqual(expected["valid"] as? Bool, true, "\(name) should be rejected")
                XCTAssertEqual(license.isStale, expected["stale"] as? Bool, name)
                XCTAssertEqual(license.token, token)
                assertJSONEqual(try XCTUnwrap(expected["claims"]), Self.json(license.claims), name)
            case .failure(let reason):
                XCTAssertEqual(expected["valid"] as? Bool, false, "\(name) rejected with \(reason)")
                XCTAssertEqual(reason.rawValue, expected.str("reason"), name)
            }
        }
    }

    static func json(_ c: LicenseClaims) -> [String: Any] {
        ["iss": c.iss, "aud": c.aud, "sub": c.sub, "iat": c.iat, "exp": c.exp,
         "lic": ["purchased": c.lic.purchased, "src": j(c.lic.src?.rawValue), "trialStart": j(c.lic.trialStart),
                 "trialEnd": j(c.lic.trialEnd), "acct": j(c.lic.acct)] as [String: Any]]
    }

    func testVerifierWithoutKeysRejectsByKid() throws {
        let root = try Vectors.object("license-token.json")
        let token = try XCTUnwrap(root.arr("cases")?.first?.str("token"))
        let verifier = LicenseTokenVerifier(keys: [:], audience: "de.hasielektronik.novaplayer")
        XCTAssertEqual(try? verifier.verify(token, now: Date()).get(), nil)
        if case .failure(let reason) = verifier.verify(token, now: Date()) { XCTAssertEqual(reason, .kid) }
        // The sub of the vectors is the device key of content-keys.json (Android id case).
        XCTAssertEqual(DeviceKey.make(appId: "de.hasielektronik.novaplayer", rawDeviceId: "9774d56d682e549c"),
                       "aef3771bd1b6413dfcc2182d9b4ccf681ca51e3e15cb99282d22271c1b16ae9c")
    }

    // MARK: §7.3 Trusted clock

    func testTrustedClockVectors() throws {
        let root = try Vectors.object("trusted-clock.json")
        let cases = try XCTUnwrap(root.arr("cases"))
        XCTAssertEqual(cases.count, 7)
        for c in cases {
            let state = c.obj("state").flatMap(Self.state)
            let got = TrustedClock.now(state: state, wallMs: try XCTUnwrap(c.int64("wallMs")),
                                       monoMs: try XCTUnwrap(c.int64("monoMs")), bootId: try XCTUnwrap(c.str("bootId")))
            XCTAssertEqual(got, c.int64("expected"), c.str("name") ?? "")
        }
        let updates = try XCTUnwrap(root.arr("updates"))
        XCTAssertEqual(updates.count, 2)
        for u in updates {
            let state = u.obj("state").flatMap(Self.state)
            let candidate = try XCTUnwrap(u.obj("update").flatMap(Self.state))
            XCTAssertEqual(TrustedClock.update(state: state, with: candidate), u.obj("expectedState").flatMap(Self.state),
                           u.str("name") ?? "")
        }
        XCTAssertEqual(TrustedClock.update(state: nil, with: TrustedClockState(serverMs: 1, monoMs: 2, bootId: "x")),
                       TrustedClockState(serverMs: 1, monoMs: 2, bootId: "x"))
    }

    static func state(_ o: [String: Any]) -> TrustedClockState? {
        guard let s = o.int64("serverMs"), let m = o.int64("monoMs"), let b = o.str("bootId") else { return nil }
        return TrustedClockState(serverMs: s, monoMs: m, bootId: b)
    }

    func testSystemClockReading() {
        let a = SystemClock.read()
        let b = SystemClock.read()
        XCTAssertGreaterThanOrEqual(b.monoMs, a.monoMs)
        #if canImport(Darwin)
        XCTAssertFalse(a.bootId.isEmpty, "kern.bootsessionuuid")
        #endif
        XCTAssertEqual(a.bootId, b.bootId)
    }

    // MARK: §7.4 Access policy

    func testAccessPolicyVectors() throws {
        let cases = try XCTUnwrap(Vectors.object("access-policy.json").arr("cases"))
        XCTAssertGreaterThan(cases.count, 0)
        for c in cases {
            let name = try XCTUnwrap(c.str("name"))
            let input = try XCTUnwrap(c.obj("input"))
            let token: LicenseInfo? = try input.obj("token").map {
                try JSONDecoder().decode(LicenseInfo.self, from: JSONSerialization.data(withJSONObject: $0))
            }
            let decision = AccessPolicy.evaluate(
                store: try XCTUnwrap(StoreState(rawValue: try XCTUnwrap(input.str("store"))), name),
                token: token,
                localTrialStartMs: input.int64("localTrialStartMs"),
                trialDays: try XCTUnwrap(input.num("trialDays")).intValue,
                nowMs: try XCTUnwrap(input.int64("nowMs")),
                platformStore: try XCTUnwrap(PlatformStore(rawValue: try XCTUnwrap(input.str("platformStore"))), name))
            let actual: [String: Any] = ["state": decision.state.rawValue, "trialEndMs": j(decision.trialEndMs),
                                         "canPlay": decision.canPlay, "pendingPurchase": decision.pendingPurchase]
            assertJSONEqual(try XCTUnwrap(c["expected"]), actual, name)
        }
    }
}
