import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Errors of backend calls (spec/BACKEND_API.md: every error body is
/// `{"error": "<code>", "message": "…"}`).
public enum BackendError: Error, Sendable, Hashable {
    /// Transport failure (same reasons as CONTRACT §2).
    case network(NetworkReason)
    /// The calling task was cancelled.
    case cancelled
    /// Non-2xx response with the API error body.
    case api(status: Int, code: String, message: String?)
    /// Non-2xx response without a parsable API error body (proxy/HTML error page).
    case http(status: Int)
    /// 2xx response whose body is not the expected JSON.
    case invalidResponse

    /// HTTP status, if the server answered.
    public var httpStatus: Int? {
        switch self {
        case .api(let status, _, _), .http(let status): return status
        default: return nil
        }
    }

    /// API error code (`invalid_code`, `too_many_attempts`…), if any.
    public var code: String? {
        if case .api(_, let code, _) = self { return code }
        return nil
    }

    /// The session token is missing/invalid/expired → sign the user out locally.
    public var isUnauthorized: Bool { httpStatus == 401 }

    /// Worth retrying later (offline, timeouts, 5xx, rate limits).
    public var isTransient: Bool {
        switch self {
        case .network: return true
        case .api(let status, _, _), .http(let status): return status >= 500 || status == 429
        default: return false
        }
    }

    /// Maps a transport error.
    static func from(_ error: Error) -> BackendError {
        if let e = error as? BackendError { return e }
        switch ErrorClassifier.sourceError(from: error) {
        case .network(let reason): return .network(reason)
        default: return .cancelled
        }
    }
}

/// Typed client for the app-facing endpoints of spec/BACKEND_API.md (admin endpoints are
/// not part of the apps). Runs over any `HTTPTransport`; every method throws `BackendError`.
///
/// The backend never receives IPTV credentials or stream URLs; pairing payloads are
/// end-to-end encrypted with `PairCrypto` before `postPairPayload`.
public struct BackendClient: Sendable {
    public let baseURL: URL
    private let transport: any HTTPTransport
    private let userAgent: String?

    /// - Parameters:
    ///   - baseURL: `BACKEND_BASE_URL` (no trailing path needed).
    ///   - userAgent: e.g. "NovaPlayer/1.0 (ios)".
    public init(baseURL: URL, transport: any HTTPTransport = URLSessionTransport.shared, userAgent: String? = nil) {
        self.baseURL = baseURL
        self.transport = transport
        self.userAgent = userAgent
    }

    // MARK: Public

    /// `GET /v1/config`.
    public func config() async throws -> BackendConfig {
        try decode(BackendConfig.self, from: try await expectOK(request(.get, "/v1/config")))
    }

    /// `POST /v1/license/sync` (session optional). `422 store_verification_failed` and
    /// `503 store_unavailable` still return a token; they are reported in `issue`.
    public func syncLicense(_ body: LicenseSyncRequest, sessionToken: String? = nil) async throws -> LicenseSyncResponse {
        let response = try await perform(request(.post, "/v1/license/sync", body: body, session: sessionToken))
        let wire = try? JSONDecoder().decode(LicenseSyncWire.self, from: response.body)
        if (200..<300).contains(response.statusCode) {
            guard let wire else { throw BackendError.invalidResponse }
            return LicenseSyncResponse(token: wire.token, license: wire.license, serverTime: wire.serverTime)
        }
        let error = Self.error(for: response)
        if response.statusCode == 422 || response.statusCode == 503, let wire {
            return LicenseSyncResponse(token: wire.token, license: wire.license, serverTime: wire.serverTime, issue: error)
        }
        throw error
    }

    // MARK: Accounts

    /// `POST /v1/auth/email/start`. Returns the `devCode` in `DEV_MODE` backends, else nil.
    @discardableResult
    public func startEmailLogin(email: String, locale: String) async throws -> String? {
        struct Body: Encodable { let email: String; let locale: String }
        struct Reply: Decodable { let devCode: String? }
        let data = try await expectOK(request(.post, "/v1/auth/email/start", body: Body(email: email, locale: locale)))
        return try decode(Reply.self, from: data).devCode
    }

    /// `POST /v1/auth/email/verify` → session.
    public func verifyEmailLogin(email: String, code: String, deviceName: String) async throws -> BackendSession {
        struct Body: Encodable { let email: String; let code: String; let deviceName: String }
        let data = try await expectOK(request(.post, "/v1/auth/email/verify",
                                              body: Body(email: email, code: code, deviceName: deviceName)))
        return try decode(BackendSession.self, from: data)
    }

    /// `POST /v1/auth/logout`.
    public func logout(sessionToken: String) async throws {
        _ = try await expectOK(request(.post, "/v1/auth/logout", body: EmptyBody(), session: sessionToken))
    }

    /// `GET /v1/account`.
    public func account(sessionToken: String) async throws -> AccountDetails {
        try decode(AccountDetails.self, from: try await expectOK(request(.get, "/v1/account", session: sessionToken)))
    }

    /// `DELETE /v1/account`.
    public func deleteAccount(sessionToken: String) async throws {
        _ = try await expectOK(request(.delete, "/v1/account", session: sessionToken))
    }

    // MARK: Device-code login (TV)

    /// `POST /v1/auth/device/start`.
    public func startDeviceLogin(platform: BackendPlatform, deviceName: String) async throws -> DeviceCodeStart {
        struct Body: Encodable { let platform: BackendPlatform; let deviceName: String }
        let data = try await expectOK(request(.post, "/v1/auth/device/start",
                                              body: Body(platform: platform, deviceName: deviceName)))
        return try decode(DeviceCodeStart.self, from: data)
    }

    /// `POST /v1/auth/device/poll`.
    public func pollDeviceLogin(deviceCode: String) async throws -> DevicePollResult {
        struct Body: Encodable { let deviceCode: String }
        let response = try await perform(request(.post, "/v1/auth/device/poll", body: Body(deviceCode: deviceCode)))
        switch response.statusCode {
        case 200..<300: return .approved(try decode(BackendSession.self, from: response.body))
        case 428: return .pending
        case 429: return .slowDown
        case 410: return .expired
        default: throw Self.error(for: response)
        }
    }

    /// `POST /v1/auth/device/approve` (phone side, signed in).
    public func approveDeviceLogin(userCode: String, sessionToken: String) async throws {
        struct Body: Encodable { let userCode: String }
        _ = try await expectOK(request(.post, "/v1/auth/device/approve", body: Body(userCode: userCode), session: sessionToken))
    }

    // MARK: Sync

    /// `GET /v1/sync?since=<cursor>&limit=<n>`.
    public func syncPull(since cursor: Int64, limit: Int = 500, sessionToken: String) async throws -> SyncPage {
        let query = PercentEncoding.query([("since", String(cursor)), ("limit", String(limit))])
        let data = try await expectOK(request(.get, "/v1/sync", query: query, session: sessionToken))
        let wire = try decode(SyncPageWire.self, from: data)
        return SyncPage(items: wire.items.compactMap(\.value), cursor: wire.cursor, hasMore: wire.hasMore)
    }

    /// `POST /v1/sync` (≤ 500 items per call).
    public func syncPush(_ items: [SyncItem], sessionToken: String) async throws -> SyncPushResult {
        struct Body: Encodable { let items: [SyncItem] }
        let data = try await expectOK(request(.post, "/v1/sync", body: Body(items: items), session: sessionToken))
        return try decode(SyncPushResult.self, from: data)
    }

    // MARK: Pairing

    /// `POST /v1/pair/sessions` (TV).
    public func createPairSession(publicKey: ECPublicJWK) async throws -> PairSession {
        struct Body: Encodable { let publicKey: ECPublicJWK }
        return try decode(PairSession.self, from: try await expectOK(request(.post, "/v1/pair/sessions",
                                                                            body: Body(publicKey: publicKey))))
    }

    /// `GET /v1/pair/sessions/{code}/key` (sender side).
    public func pairPublicKey(code: String) async throws -> ECPublicJWK {
        struct Reply: Decodable { let publicKey: ECPublicJWK }
        let path = "/v1/pair/sessions/\(PercentEncoding.encode(PairCode.normalize(code)))/key"
        return try decode(Reply.self, from: try await expectOK(request(.get, path))).publicKey
    }

    /// `POST /v1/pair/sessions/{code}/payload` (sender side; `409` if already set).
    public func postPairPayload(code: String, envelope: PairEnvelope) async throws {
        let path = "/v1/pair/sessions/\(PercentEncoding.encode(PairCode.normalize(code)))/payload"
        _ = try await expectOK(request(.post, path, body: envelope))
    }

    /// `GET /v1/pair/sessions/{code}?secret=…` (TV, every 2 s).
    public func pollPairSession(code: String, secret: String) async throws -> PairPollResult {
        let path = "/v1/pair/sessions/\(PercentEncoding.encode(PairCode.normalize(code)))"
        let response = try await perform(request(.get, path, query: PercentEncoding.query([("secret", secret)])))
        switch response.statusCode {
        case 202: return .pending
        case 200..<300: return .ready(try decode(PairEnvelope.self, from: response.body))
        case 410: return .expired
        case 404: return .notFound
        default: throw Self.error(for: response)
        }
    }

    // MARK: Plumbing

    private struct EmptyBody: Encodable {}

    private struct LicenseSyncWire: Decodable {
        let token: String
        let license: LicenseInfo
        let serverTime: Int64
    }

    private struct SyncPageWire: Decodable {
        let items: [Failable<SyncItem>]
        let cursor: Int64
        let hasMore: Bool
    }

    /// Decodes an element or yields nil (one malformed item never fails a page).
    private struct Failable<T: Decodable>: Decodable {
        let value: T?
        init(from decoder: Decoder) throws { value = try? T(from: decoder) }
    }

    private struct ErrorBody: Decodable {
        let error: String
        let message: String?
    }

    func request(_ method: HTTPMethod, _ path: String, query: String? = nil, session: String? = nil) -> HTTPRequest {
        var string = baseURL.absoluteString
        while string.hasSuffix("/") { string.removeLast() }
        string += path
        if let query, !query.isEmpty { string += "?" + query }
        var headers = ["Accept": "application/json"]
        if let userAgent { headers["User-Agent"] = userAgent }
        if let session { headers["Authorization"] = "Bearer \(session)" }
        // Path components are percent-encoded by the callers; the URL is always valid.
        return HTTPRequest(method: method, url: URL(string: string) ?? baseURL, headers: headers, timeouts: .backend)
    }

    func request<B: Encodable>(_ method: HTTPMethod, _ path: String, body: B, session: String? = nil) throws -> HTTPRequest {
        var r = request(method, path, session: session)
        do { r.body = try JSONEncoder().encode(body) } catch { throw BackendError.invalidResponse }
        r.headers["Content-Type"] = "application/json; charset=utf-8"
        return r
    }

    private func perform(_ request: @autoclosure () throws -> HTTPRequest) async throws -> HTTPResponse {
        let r = try request()
        do {
            try Task.checkCancellation()
            return try await transport.send(r)
        } catch {
            throw BackendError.from(error)
        }
    }

    private func expectOK(_ request: @autoclosure () throws -> HTTPRequest) async throws -> Data {
        let response = try await perform(try request())
        guard (200..<300).contains(response.statusCode) else { throw Self.error(for: response) }
        return response.body
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do { return try JSONDecoder().decode(type, from: data) } catch { throw BackendError.invalidResponse }
    }

    /// Maps a non-2xx response to `BackendError`.
    static func error(for response: HTTPResponse) -> BackendError {
        if let body = try? JSONDecoder().decode(ErrorBody.self, from: response.body) {
            return .api(status: response.statusCode, code: body.error, message: body.message)
        }
        return .http(status: response.statusCode)
    }
}
