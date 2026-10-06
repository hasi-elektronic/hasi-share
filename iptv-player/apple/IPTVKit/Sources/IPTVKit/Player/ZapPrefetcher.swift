import Foundation
import IPTVCore
#if canImport(Network)
import Network
#endif

public protocol PrefetchFetcher: Sendable {
    /// Fetches at most `maxBytes` of `url` (GET with Range); returns bytes read.
    func fetch(_ url: URL, headers: [String: String], maxBytes: Int) async throws -> Int
}
public protocol NetworkConditions: Sendable { var isExpensiveOrConstrained: Bool { get } }

/// Warms neighbour channels while a live channel plays (spec §1): resolves their stream URL
/// and pre-reads ≤ maxBytes (manifest / first bytes) so DNS, TCP/TLS and the playlist are hot.
@MainActor
public final class ZapPrefetcher {
    private let resolver: @MainActor (PlaybackRequest) async throws -> ResolvedStream
    private let fetcher: any PrefetchFetcher
    private let network: any NetworkConditions
    private let maxBytes: Int
    private let maxConcurrent: Int
    private var resolved: [String: ResolvedStream] = [:]
    private var tasks: [Task<Void, Never>] = []

    public init(resolver: @escaping @MainActor (PlaybackRequest) async throws -> ResolvedStream,
                fetcher: any PrefetchFetcher, network: any NetworkConditions,
                maxBytes: Int = 262_144, maxConcurrent: Int = 2) {
        self.resolver = resolver; self.fetcher = fetcher; self.network = network
        self.maxBytes = maxBytes; self.maxConcurrent = max(1, maxConcurrent)
    }

    /// Neighbours of `current` in `channels` (previous, next; wraps around).
    public static func neighbours(of current: Channel, in channels: [Channel]) -> [Channel] {
        guard channels.count > 1, let i = channels.firstIndex(where: { $0.id == current.id }) else { return [] }
        let prev = channels[(i - 1 + channels.count) % channels.count]
        let next = channels[(i + 1) % channels.count]
        return prev.id == next.id ? [prev] : [prev, next]
    }

    public func prefetch(around current: Channel, request: PlaybackRequest) {
        cancelAll()
        guard !network.isExpensiveOrConstrained else { return }
        let targets = Self.neighbours(of: current, in: request.channels).prefix(maxConcurrent)
        for channel in targets {
            var req = request
            req.item = .channel(channel)
            let maxBytes = self.maxBytes, fetcher = self.fetcher
            tasks.append(Task { [weak self] in
                guard let self, let stream = try? await self.resolver(req), !Task.isCancelled else { return }
                self.resolved[channel.id] = stream
                _ = try? await fetcher.fetch(stream.url, headers: stream.headers, maxBytes: maxBytes)
            })
        }
    }

    /// Cached resolution for a channel id (consumed once), nil if none.
    public func takeResolved(channelId: String) -> ResolvedStream? { resolved.removeValue(forKey: channelId) }

    public func cancelAll() {
        tasks.forEach { $0.cancel() }
        tasks.removeAll()
        resolved.removeAll()
    }
}

/// URLSession-backed fetcher: Range GET, stops after maxBytes.
public struct URLSessionPrefetchFetcher: PrefetchFetcher {
    public init() {}
    public func fetch(_ url: URL, headers: [String: String], maxBytes: Int) async throws -> Int {
        var request = URLRequest(url: url, timeoutInterval: 5)
        headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        request.setValue("bytes=0-\(maxBytes - 1)", forHTTPHeaderField: "Range")
        let (bytes, _) = try await URLSession.shared.bytes(for: request)
        var n = 0
        for try await _ in bytes { n += 1; if n >= maxBytes { break } }
        return n
    }
}

#if canImport(Network)
/// Reads NWPathMonitor; expensive (cellular/hotspot) or constrained (Low Data Mode) → no prefetch.
public final class PathNetworkConditions: NetworkConditions, @unchecked Sendable {
    private let monitor = NWPathMonitor()
    private let lock = NSLock()
    private var flag = false
    public init() {
        monitor.pathUpdateHandler = { [weak self] path in
            self?.lock.withLock { self?.flag = path.isExpensive || path.isConstrained }
        }
        monitor.start(queue: DispatchQueue(label: "prefetch.path"))
    }
    deinit { monitor.cancel() }
    public var isExpensiveOrConstrained: Bool { lock.withLock { flag } }
}
#endif
