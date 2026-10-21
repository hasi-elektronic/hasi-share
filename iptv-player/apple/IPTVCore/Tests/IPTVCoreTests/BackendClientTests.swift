import Foundation
import XCTest
@testable import IPTVCore

/// spec/BACKEND_API.md client: request shapes, response decoding and error mapping.
final class BackendClientTests: XCTestCase {
    private let base = URL(string: "https://api.example.com/")!

    private static func json(_ s: String, status: Int = 200) -> HTTPResponse {
        HTTPResponse(statusCode: status, headers: ["Content-Type": "application/json"], body: Data(s.utf8))
    }

    private func body(_ r: HTTPRequest?) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(r?.body)) as? [String: Any])
    }

    private func expect<T>(_ expected: BackendError, _ op: () async throws -> T, file: StaticString = #filePath, line: UInt = #line) async {
        do {
            _ = try await op()
            XCTFail("expected \(expected)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? BackendError, expected, file: file, line: line)
        }
    }

    func testConfig() async throws {
        let t = FakeTransport { _ in
            Self.json(#"""
            {"trialDays":7,"minVersion":{"android":1,"apple":2},
             "products":{"google":"lifetime_access","appleLifetime":"de.hasielektronik.novaplayer.lifetime","appleTrial":"de.hasielektronik.novaplayer.trial"},
             "features":{"accounts":true,"pairing":true,"sync":false},"serverTime":1759570000123}
            """#)
        }
        let config = try await BackendClient(baseURL: base, transport: t, userAgent: "NovaPlayer/1").config()
        XCTAssertEqual(config.trialDays, 7)
        XCTAssertEqual(config.minVersion.apple, 2)
        XCTAssertEqual(config.products.appleTrial, "de.hasielektronik.novaplayer.trial")
        XCTAssertFalse(config.features.sync)
        XCTAssertEqual(config.serverTime, 1_759_570_000_123)
        let r = try XCTUnwrap(t.requests.first)
        XCTAssertEqual(r.method, .get)
        XCTAssertEqual(r.url.absoluteString, "https://api.example.com/v1/config")
        XCTAssertEqual(r.headers["User-Agent"], "NovaPlayer/1")
        XCTAssertNil(r.headers["Authorization"])
        XCTAssertEqual(r.timeouts, .backend)
    }

    func testLicenseSyncSuccessAndPartialFailures() async throws {
        let token = try XCTUnwrap(Vectors.object("license-token.json").arr("cases")?.first?.str("token"))
        let license = #"{"purchased":false,"src":null,"trialStart":1759570000,"trialEnd":1760174800,"acct":null}"#
        let t = FakeTransport { _ in
            Self.json("{\"token\":\"\(token)\",\"license\":\(license),\"serverTime\":1759570000123}")
        }
        let client = BackendClient(baseURL: base, transport: t)
        let request = LicenseSyncRequest(platform: .ios, appId: "de.hasielektronik.novaplayer", appVersion: "1.0 (1)",
                                         deviceKey: String(repeating: "a", count: 64),
                                         apple: .init(trialTransactionId: "2000001", transactionIds: ["2000002"]))
        let ok = try await client.syncLicense(request, sessionToken: "sess")
        XCTAssertEqual(ok.token, token)
        XCTAssertEqual(ok.license.trialEnd, 1_760_174_800)
        XCTAssertNil(ok.issue)
        let r = try XCTUnwrap(t.requests.first)
        XCTAssertEqual(r.method, .post)
        XCTAssertEqual(r.url.absoluteString, "https://api.example.com/v1/license/sync")
        XCTAssertEqual(r.headers["Authorization"], "Bearer sess")
        XCTAssertEqual(r.headers["Content-Type"], "application/json; charset=utf-8")
        let sent = try body(r)
        XCTAssertEqual(sent.str("platform"), "ios")
        XCTAssertEqual(sent["startTrial"] as? Bool, false)
        XCTAssertEqual(sent.obj("apple")?.str("trialTransactionId"), "2000001")
        XCTAssertNil(sent["google"], "absent optionals are omitted")

        // 422 / 503 still carry a token.
        let t422 = FakeTransport { _ in
            Self.json("{\"error\":\"store_verification_failed\",\"message\":\"m\",\"details\":[{}],\"token\":\"\(token)\",\"license\":\(license),\"serverTime\":1}", status: 422)
        }
        let partial = try await BackendClient(baseURL: base, transport: t422).syncLicense(request)
        XCTAssertEqual(partial.token, token)
        XCTAssertEqual(partial.issue, .api(status: 422, code: "store_verification_failed", message: "m"))

        // 400 without a token is thrown.
        let t400 = FakeTransport { _ in Self.json(#"{"error":"invalid_request","message":"bad deviceKey"}"#, status: 400) }
        await expect(.api(status: 400, code: "invalid_request", message: "bad deviceKey")) {
            try await BackendClient(baseURL: self.base, transport: t400).syncLicense(request)
        }
    }

    func testErrorMapping() async throws {
        let html = FakeTransport { _ in HTTPResponse(statusCode: 502, body: Data("<html>Bad gateway</html>".utf8)) }
        await expect(.http(status: 502)) { try await BackendClient(baseURL: self.base, transport: html).config() }

        let htmlOK = FakeTransport { _ in HTTPResponse(statusCode: 200, body: Data("<html>captive portal</html>".utf8)) }
        await expect(.invalidResponse) { try await BackendClient(baseURL: self.base, transport: htmlOK).config() }

        let unauthorized = FakeTransport { _ in Self.json(#"{"error":"unauthorized","message":"Authentication required."}"#, status: 401) }
        do {
            _ = try await BackendClient(baseURL: base, transport: unauthorized).account(sessionToken: "old")
            XCTFail("expected 401")
        } catch let e as BackendError {
            XCTAssertTrue(e.isUnauthorized)
            XCTAssertFalse(e.isTransient)
            XCTAssertEqual(e.code, "unauthorized")
        }

        let offline = FakeTransport { _ in throw URLError(.notConnectedToInternet) }
        await expect(.network(.offline)) { try await BackendClient(baseURL: self.base, transport: offline).config() }
        XCTAssertTrue(BackendError.network(.timeout).isTransient)
        XCTAssertTrue(BackendError.api(status: 429, code: "rate_limited", message: nil).isTransient)

        let slow = FakeTransport { _ in throw URLError(.cancelled) }
        await expect(.cancelled) { try await BackendClient(baseURL: self.base, transport: slow).config() }
    }

    func testEmailLoginAccountAndLogout() async throws {
        let t = FakeTransport { r in
            switch r.url.path {
            case "/v1/auth/email/start": return Self.json(#"{"ok":true,"devCode":"123456"}"#)
            case "/v1/auth/email/verify": return Self.json(#"{"sessionToken":"tok","account":{"id":"acc_1","email":"a@b.c"}}"#)
            case "/v1/account" where r.method == .get:
                return Self.json(#"{"id":"acc_1","email":"a@b.c","createdAt":1759570000123,"licenses":[{"store":"apple","status":"active","purchasedAt":null,"productId":"x"}],"trial":{"start":1759570000,"end":1760174800}}"#)
            default: return Self.json(#"{"ok":true}"#)
            }
        }
        let client = BackendClient(baseURL: base, transport: t)
        let devCode = try await client.startEmailLogin(email: "a@b.c", locale: "tr")
        XCTAssertEqual(devCode, "123456")
        let session = try await client.verifyEmailLogin(email: "a@b.c", code: "123456", deviceName: "iPhone")
        XCTAssertEqual(session, BackendSession(sessionToken: "tok", account: BackendAccount(id: "acc_1", email: "a@b.c")))
        let account = try await client.account(sessionToken: "tok")
        XCTAssertEqual(account.licenses.first?.store, "apple")
        XCTAssertEqual(account.trial?.end, 1_760_174_800)
        try await client.logout(sessionToken: "tok")
        try await client.deleteAccount(sessionToken: "tok")
        let requests = t.requests
        XCTAssertEqual(try body(requests[0]).str("locale"), "tr")
        XCTAssertEqual(try body(requests[1]).str("deviceName"), "iPhone")
        XCTAssertEqual(requests[3].method, .post)
        XCTAssertEqual(requests[3].headers["Authorization"], "Bearer tok")
        XCTAssertEqual(requests[4].method, .delete)
        XCTAssertEqual(requests[4].url.absoluteString, "https://api.example.com/v1/account")
    }

    func testDeviceCodeFlow() async throws {
        let answers = LockedArray<HTTPResponse>()
        let replies = [
            Self.json(#"{"error":"authorization_pending","message":"m"}"#, status: 428),
            Self.json(#"{"error":"slow_down","message":"m"}"#, status: 429),
            Self.json(#"{"error":"expired_token","message":"m"}"#, status: 410),
            Self.json(#"{"sessionToken":"tok","account":{"id":"a","email":"e@x.y"}}"#),
            Self.json(#"{"error":"internal_error","message":"boom"}"#, status: 500),
        ]
        let t = FakeTransport { r in
            if r.url.path == "/v1/auth/device/start" {
                return Self.json(#"{"deviceCode":"dc","userCode":"ABCD-EFGH","verificationUrl":"https://x/link","verificationUrlComplete":"https://x/link?c=ABCDEFGH","interval":5,"expiresIn":600}"#)
            }
            let reply = replies[answers.values.count]
            answers.append(reply)
            return reply
        }
        let client = BackendClient(baseURL: base, transport: t)
        let start = try await client.startDeviceLogin(platform: .tvos, deviceName: "Apple TV")
        XCTAssertEqual(start.userCode, "ABCD-EFGH")
        XCTAssertEqual(start.interval, 5)
        let pending = try await client.pollDeviceLogin(deviceCode: "dc")
        let slowDown = try await client.pollDeviceLogin(deviceCode: "dc")
        let expired = try await client.pollDeviceLogin(deviceCode: "dc")
        let approved = try await client.pollDeviceLogin(deviceCode: "dc")
        XCTAssertEqual(pending, .pending)
        XCTAssertEqual(slowDown, .slowDown)
        XCTAssertEqual(expired, .expired)
        XCTAssertEqual(approved, .approved(BackendSession(sessionToken: "tok", account: BackendAccount(id: "a", email: "e@x.y"))))
        await expect(.api(status: 500, code: "internal_error", message: "boom")) { try await client.pollDeviceLogin(deviceCode: "dc") }
        XCTAssertEqual(try body(t.requests.first).str("platform"), "tvos")
        XCTAssertEqual(try body(t.requests[1]).str("deviceCode"), "dc")

        let approve = FakeTransport { _ in Self.json(#"{"ok":true}"#) }
        try await BackendClient(baseURL: base, transport: approve).approveDeviceLogin(userCode: "ABCD-EFGH", sessionToken: "s")
        XCTAssertEqual(try body(approve.requests.first).str("userCode"), "ABCD-EFGH")
    }

    func testSyncPullAndPush() async throws {
        let t = FakeTransport { r in
            if r.method == .get {
                return Self.json(#"""
                {"items":[
                  {"key":"fav:fp:live:1","kind":"favorite","data":{"title":"TRT 1","contentKind":"live"},"updatedAt":10,"deleted":false,"seq":5},
                  {"key":"broken","kind":"favorite","data":{},"updatedAt":11,"deleted":false,"seq":6},
                  {"key":"prog:fp:movie:2","kind":"progress","data":{"title":"M","contentKind":"movie","positionMs":1000,"durationMs":5000},"updatedAt":12,"deleted":false,"seq":7}
                ],"cursor":7,"hasMore":true}
                """#)
            }
            return Self.json(#"{"applied":1,"cursor":8}"#)
        }
        let client = BackendClient(baseURL: base, transport: t)
        let page = try await client.syncPull(since: 4, sessionToken: "s")
        XCTAssertEqual(page.items.map(\.key), ["fav:fp:live:1", "prog:fp:movie:2"], "malformed items are skipped")
        XCTAssertEqual(page.items.last?.seq, 7)
        XCTAssertEqual(page.cursor, 7)
        XCTAssertTrue(page.hasMore)
        XCTAssertEqual(t.requests.first?.url.absoluteString, "https://api.example.com/v1/sync?since=4&limit=500")

        let item = SyncItem.favorite(contentKey: "fp:live:1", title: "TRT 1", contentKind: .live, posterUrl: nil, updatedAt: 20)
        let pushed = try await client.syncPush([item], sessionToken: "s")
        XCTAssertEqual(pushed, SyncPushResult(applied: 1, cursor: 8))
        let sent = try XCTUnwrap(try body(t.requests.last).arr("items")?.first)
        XCTAssertEqual(sent.str("key"), "fav:fp:live:1")
        XCTAssertEqual(sent.int64("updatedAt"), 20)
        XCTAssertEqual(sent["deleted"] as? Bool, false)
    }

    func testPairingEndToEnd() async throws {
        // TV creates a session, phone encrypts for the TV key, TV polls and decrypts.
        let tvKey = PairCrypto.generateKeyPair()
        let stored = LockedArray<Data>()
        let polls = LockedArray<Int>()
        let t = FakeTransport { r in
            switch (r.method, r.url.path) {
            case (.post, "/v1/pair/sessions"):
                return Self.json(#"{"code":"ABC234","secret":"sec","expiresAt":1759570600000,"expiresIn":600,"pairUrl":"https://x/pair?c=ABC234"}"#)
            case (.get, "/v1/pair/sessions/ABC234/key"):
                let key = try JSONEncoder().encode(PairCrypto.jwk(of: tvKey.publicKey))
                return HTTPResponse(statusCode: 200, body: Data("{\"publicKey\":".utf8) + key + Data(",\"expiresAt\":1}".utf8))
            case (.post, "/v1/pair/sessions/ABC234/payload"):
                stored.append(r.body ?? Data())
                return Self.json(#"{"ok":true}"#)
            case (.get, "/v1/pair/sessions/ABC234"):
                polls.append(1)
                if polls.values.count == 1 { return Self.json(#"{"status":"pending"}"#, status: 202) }
                if polls.values.count == 2 { return HTTPResponse(statusCode: 200, body: stored.values[0]) }
                return Self.json(#"{"error":"expired","message":"m"}"#, status: 410)
            case (.get, "/v1/pair/sessions/ZZZ999"):
                return Self.json(#"{"error":"not_found","message":"m"}"#, status: 404)
            default:
                return HTTPResponse(statusCode: 500)
            }
        }
        let client = BackendClient(baseURL: base, transport: t)
        let session = try await client.createPairSession(publicKey: PairCrypto.jwk(of: tvKey.publicKey))
        XCTAssertEqual(PairCode.display(session.code), "ABC-234")
        XCTAssertEqual(try body(t.requests.first).obj("publicKey")?.str("crv"), "P-256")

        let tvPublic = try await client.pairPublicKey(code: "abc-234")
        let payload = PairPayload.xtream(name: "Ev", server: "http://iptv.example.com", username: "u", password: "p@ss")
        try await client.postPairPayload(code: "ABC-234", envelope: try PairCrypto.encrypt(try JSONEncoder().encode(payload), to: tvPublic))
        XCTAssertFalse(String(decoding: stored.values[0], as: UTF8.self).contains("p@ss"), "backend only sees ciphertext")

        let pending = try await client.pollPairSession(code: session.code, secret: session.secret)
        XCTAssertEqual(pending, .pending)
        guard case .ready(let envelope) = try await client.pollPairSession(code: session.code, secret: session.secret) else {
            return XCTFail("expected ready")
        }
        XCTAssertEqual(try PairCrypto.open(envelope, privateKey: tvKey), payload)
        let expired = try await client.pollPairSession(code: session.code, secret: session.secret)
        XCTAssertEqual(expired, .expired)
        let unknown = try await client.pollPairSession(code: "ZZZ999", secret: "x")
        XCTAssertEqual(unknown, .notFound)
        XCTAssertTrue(t.requests.contains { $0.url.absoluteString == "https://api.example.com/v1/pair/sessions/ABC234?secret=sec" })
    }

    /// The client works over the real URLSession transport (HTML error page → `.http`).
    func testOverURLSessionTransport() async throws {
        let host = "backend.\(UUID().uuidString.prefix(8).lowercased()).test"
        let config = MockURLProtocol.register(host: host) { request, _ in
            request.url?.path == "/v1/config"
                ? .text("<html>502</html>", status: 502)
                : .body(Data(#"{"ok":true}"#.utf8), headers: ["Content-Type": "application/json"])
        }
        let client = BackendClient(baseURL: URL(string: "http://\(host)")!, transport: URLSessionTransport(configuration: config))
        await expect(.http(status: 502)) { try await client.config() }
        try await client.logout(sessionToken: "t")
        XCTAssertEqual(MockURLProtocol.requests(host: host).last?.value(forHTTPHeaderField: "Authorization"), "Bearer t")
    }
}
