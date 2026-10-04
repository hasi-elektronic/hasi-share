import Foundation
import IPTVCore
import Observation

/// "Add source" form (docs/SCREENS.md §3.1): M3U or Xtream, validation, stepwise progress,
/// result summary or a precise error.
@MainActor
@Observable
public final class AddSourceViewModel {
    public enum Kind: String, CaseIterable, Sendable { case m3u, xtream }

    public enum Phase: Equatable {
        case editing
        case connecting(RefreshProgress)
        case success(Source)
        case failed(SourceError)
    }

    public var kind: Kind
    public var name = ""
    public var m3uURL = ""
    public var epgURL = ""
    public var userAgent = ""
    public var server = ""
    public var username = ""
    public var password = ""
    public var showPassword = false
    public private(set) var phase: Phase = .editing

    @ObservationIgnored private let env: AppEnvironment
    @ObservationIgnored private var task: Task<Void, Never>?

    public init(env: AppEnvironment, kind: Kind = .m3u) {
        self.env = env
        self.kind = kind
    }

    /// Prefills from a pairing payload (TV QR flow).
    public func apply(_ payload: PairPayload) {
        switch payload {
        case let .m3u(name, url, epgUrl):
            kind = .m3u
            self.name = name
            m3uURL = url
            epgURL = epgUrl ?? ""
        case let .xtream(name, server, username, password):
            kind = .xtream
            self.name = name
            self.server = server
            self.username = username
            self.password = password
        }
    }

    // MARK: Validation

    public static func isValidHTTPURL(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: t), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty else { return false }
        return true
    }

    public var m3uURLError: Bool { !m3uURL.isEmpty && !Self.isValidHTTPURL(m3uURL) }
    public var epgURLError: Bool { !epgURL.isEmpty && !Self.isValidHTTPURL(epgURL) }
    public var serverError: Bool { !server.isEmpty && URLNormalizer.xtreamBase(server) == nil }

    public var isValid: Bool {
        switch kind {
        case .m3u: return Self.isValidHTTPURL(m3uURL) && (epgURL.isEmpty || Self.isValidHTTPURL(epgURL))
        case .xtream:
            return URLNormalizer.xtreamBase(server) != nil && !username.trimmingCharacters(in: .whitespaces).isEmpty
                && !password.isEmpty
        }
    }

    public var secrets: SourceSecrets {
        func opt(_ s: String) -> String? {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        }
        switch kind {
        case .m3u:
            return .m3u(M3USecrets(url: m3uURL.trimmingCharacters(in: .whitespacesAndNewlines), epgUrl: opt(epgURL), userAgent: opt(userAgent)))
        case .xtream:
            return .xtream(XtreamSecrets(serverUrl: server.trimmingCharacters(in: .whitespacesAndNewlines),
                                         username: username.trimmingCharacters(in: .whitespaces), password: password,
                                         epgUrl: opt(epgURL)))
        }
    }

    // MARK: Connect

    public func connect() {
        guard isValid else { return }
        task?.cancel()
        phase = .connecting(.connecting)
        let secrets = self.secrets
        let name = self.name
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let source = try await env.addSource(name: name, secrets: secrets) { progress in
                    Task { @MainActor [weak self] in
                        if case .connecting = self?.phase { self?.phase = .connecting(progress) }
                    }
                }
                phase = .success(source)
            } catch {
                let mapped = ErrorClassifier.sourceError(from: error)
                phase = mapped == .cancelled ? .editing : .failed(mapped)
            }
        }
    }

    public func cancel() {
        task?.cancel()
        phase = .editing
    }

    public func backToForm() {
        phase = .editing
    }
}
