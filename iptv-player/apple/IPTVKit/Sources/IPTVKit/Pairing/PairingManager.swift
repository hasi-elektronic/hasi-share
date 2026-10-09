import Foundation
import IPTVCore
import Observation
#if canImport(CryptoKit)
import CryptoKit
#endif

/// Pairing calls (`BackendClient` conforms).
public protocol PairingBackend: Sendable {
    func createPairSession(publicKey: ECPublicJWK) async throws -> PairSession
    func pollPairSession(code: String, secret: String) async throws -> PairPollResult
}

extension BackendClient: PairingBackend {}

/// TV side of "add a source with your phone" (CONTRACT §9): ephemeral P-256 key, session with
/// QR + short code (10 min), polling every 2 s, end-to-end decryption of the payload.
@MainActor
@Observable
public final class PairingManager {
    public enum State: Sendable, Hashable {
        case idle
        case creating
        case waiting(code: String, pairUrl: String, expiresAt: Date)
        case received(PairPayload)
        case expired
        case failed(String)
    }

    public private(set) var state: State = .idle

    @ObservationIgnored private let backend: any PairingBackend
    @ObservationIgnored private let pollInterval: Duration
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private let now: @Sendable () -> Date

    public init(backend: any PairingBackend, pollInterval: Duration = .seconds(2), now: @escaping @Sendable () -> Date = { Date() }) {
        self.backend = backend
        self.pollInterval = pollInterval
        self.now = now
    }

    /// Code formatted for display (`ABC-123`).
    public var displayCode: String? {
        if case .waiting(let code, _, _) = state { return PairCode.display(code) }
        return nil
    }

    public func start() {
        task?.cancel()
        state = .creating
        let privateKey = PairCrypto.generateKeyPair()
        let publicJWK = PairCrypto.jwk(of: privateKey.publicKey)
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let session = try await backend.createPairSession(publicKey: publicJWK)
                let expiresAt = Date(timeIntervalSince1970: Double(session.expiresAt) / 1000)
                state = .waiting(code: session.code, pairUrl: session.pairUrl, expiresAt: expiresAt)
                while !Task.isCancelled {
                    try await Task.sleep(for: pollInterval)
                    if now() >= expiresAt { state = .expired; return }
                    switch try await backend.pollPairSession(code: session.code, secret: session.secret) {
                    case .pending: continue
                    case .expired, .notFound: state = .expired; return
                    case .ready(let envelope):
                        do {
                            state = .received(try PairCrypto.open(envelope, privateKey: privateKey))
                        } catch {
                            state = .failed("decrypt")
                        }
                        return
                    }
                }
            } catch is CancellationError {
                return
            } catch {
                state = .failed(String(describing: error))
            }
        }
    }

    public func cancel() {
        task?.cancel()
        task = nil
        state = .idle
    }
}
