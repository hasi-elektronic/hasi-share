import Foundation
import IPTVCore
import Observation

/// Account calls (`BackendClient` conforms).
public protocol AccountBackend: Sendable {
    func startEmailLogin(email: String, locale: String) async throws -> String?
    func verifyEmailLogin(email: String, code: String, deviceName: String) async throws -> BackendSession
    func logout(sessionToken: String) async throws
    func deleteAccount(sessionToken: String) async throws
    func startDeviceLogin(platform: BackendPlatform, deviceName: String) async throws -> DeviceCodeStart
    func pollDeviceLogin(deviceCode: String) async throws -> DevicePollResult
}

extension BackendClient: AccountBackend {}

/// Optional app account (CONTRACT §7.6, BACKEND_API Accounts): e-mail code login, TV device-code
/// login (code + QR), sign-out, account deletion. The session token lives in the Keychain.
@MainActor
@Observable
public final class AccountManager {
    public enum DeviceLoginState: Sendable, Hashable {
        case idle
        case waiting(DeviceCodeStart, expiresAt: Date)
        case expired
        case failed(String)
    }

    public private(set) var account: BackendAccount?
    public private(set) var pendingEmail: String?
    /// Only with backend `DEV_MODE=true` (shown in debug builds to simplify testing).
    public private(set) var devCode: String?
    public private(set) var busy = false
    public private(set) var errorMessage: String?
    public private(set) var deviceLogin: DeviceLoginState = .idle

    @ObservationIgnored private let backend: any AccountBackend
    @ObservationIgnored private let secureStore: any SecureStore
    @ObservationIgnored private let deviceName: String
    @ObservationIgnored private let platform: BackendPlatform
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    /// Called after sign-in / sign-out (license re-sync, sync start/reset).
    @ObservationIgnored public var onSessionChange: (@MainActor (Bool) -> Void)?

    /// Secure-store key of the session token (read off-main by the sync layer).
    public nonisolated static let sessionKey = "account.session"

    private enum Keys {
        static let session = AccountManager.sessionKey
        static let account = "account.info"
    }

    public init(backend: any AccountBackend, secureStore: any SecureStore, deviceName: String, platform: BackendPlatform) {
        self.backend = backend
        self.secureStore = secureStore
        self.deviceName = deviceName
        self.platform = platform
        self.account = secureStore.value(BackendAccount.self, forKey: Keys.account)
    }

    /// Current session token (nil when signed out).
    public var sessionToken: String? { secureStore.string(forKey: Keys.session) }
    public var isSignedIn: Bool { account != nil && sessionToken != nil }

    public func startEmailLogin(email: String) async {
        busy = true
        defer { busy = false }
        errorMessage = nil
        do {
            devCode = try await backend.startEmailLogin(email: email, locale: Locale.current.language.languageCode?.identifier == "tr" ? "tr" : "en")
            pendingEmail = email
        } catch {
            errorMessage = Self.message(error)
        }
    }

    public func verify(code: String) async {
        guard let email = pendingEmail else { return }
        busy = true
        defer { busy = false }
        errorMessage = nil
        do {
            let session = try await backend.verifyEmailLogin(email: email, code: code, deviceName: deviceName)
            store(session)
        } catch {
            errorMessage = Self.message(error)
        }
    }

    public func cancelEmailLogin() {
        pendingEmail = nil
        devCode = nil
        errorMessage = nil
    }

    private func store(_ session: BackendSession) {
        try? secureStore.setString(session.sessionToken, forKey: Keys.session)
        try? secureStore.setValue(session.account, forKey: Keys.account)
        account = session.account
        pendingEmail = nil
        devCode = nil
        onSessionChange?(true)
    }

    private func clearSession() {
        try? secureStore.set(nil, forKey: Keys.session)
        try? secureStore.set(nil, forKey: Keys.account)
        account = nil
        onSessionChange?(false)
    }

    public func signOut() async {
        if let token = sessionToken { try? await backend.logout(sessionToken: token) }
        clearSession()
    }

    public func deleteAccount() async -> Bool {
        guard let token = sessionToken else { return false }
        busy = true
        defer { busy = false }
        do {
            try await backend.deleteAccount(sessionToken: token)
            clearSession()
            return true
        } catch {
            errorMessage = Self.message(error)
            return false
        }
    }

    // MARK: TV device-code login

    public func startDeviceLogin() {
        pollTask?.cancel()
        errorMessage = nil
        pollTask = Task { [weak self] in
            guard let self else { return }
            do {
                let start = try await backend.startDeviceLogin(platform: platform, deviceName: deviceName)
                let expiresAt = Date().addingTimeInterval(TimeInterval(start.expiresIn))
                deviceLogin = .waiting(start, expiresAt: expiresAt)
                var interval = max(2, start.interval)
                while !Task.isCancelled {
                    try await Task.sleep(for: .seconds(interval))
                    if Date() >= expiresAt { deviceLogin = .expired; return }
                    switch try await backend.pollDeviceLogin(deviceCode: start.deviceCode) {
                    case .pending: continue
                    case .slowDown: interval += 5
                    case .expired: deviceLogin = .expired; return
                    case .approved(let session):
                        deviceLogin = .idle
                        store(session)
                        return
                    }
                }
            } catch is CancellationError {
                return
            } catch {
                deviceLogin = .failed(Self.message(error))
            }
        }
    }

    public func cancelDeviceLogin() {
        pollTask?.cancel()
        pollTask = nil
        deviceLogin = .idle
    }

    static func message(_ error: Error) -> String {
        if let e = error as? BackendError {
            switch e {
            case .api(_, let code, let message): return message ?? code
            case .network(let reason): return "network: \(reason.rawValue)"
            case .http(let status): return "HTTP \(status)"
            case .invalidResponse: return "invalid response"
            case .cancelled: return "cancelled"
            }
        }
        return error.localizedDescription
    }
}
