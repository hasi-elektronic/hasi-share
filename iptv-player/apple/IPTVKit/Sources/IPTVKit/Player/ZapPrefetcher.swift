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

/// Warms neighbour channels while a live channel plays (spec §1): resolves their stream URL and,
/// where safe, pre-reads ≤ maxBytes of the HLS manifest so DNS, TCP/TLS and the playlist are hot.
///
/// The byte read opens an extra connection to the provider, and many Xtream accounts allow only one
/// (`max_connections = 1`) – a second connection could kick the playing stream. So the read happens
/// only for HLS and only when the source is not Xtream or its stored account allows more than one
/// connection (unknown → no read); otherwise the neighbour is resolve-only.
///
/// A cached resolution expires after `ttl` (tokenized URLs go stale).
@MainActor
public final class ZapPrefetcher {
    private let resolver: @MainActor (PlaybackRequest) async throws -> ResolvedStream
    private let fetcher: any PrefetchFetcher
    private let network: any NetworkConditions
    private let maxBytes: Int
    private let maxConcurrent: Int
    private let ttl: TimeInterval
    private let now: @Sendable () -> Date
    private var resolved: [String: (stream: ResolvedStream, at: Date)] = [:]
    private var tasks: [Task<Void, Never>] = []

    public init(resolver: @escaping @MainActor (PlaybackRequest) async throws -> ResolvedStream,
                fetcher: any PrefetchFetcher, network: any NetworkConditions,
                maxBytes: Int = 262_144, maxConcurrent: Int = 2,
                ttl: TimeInterval = 90, now: @escaping @Sendable () -> Date = { Date() }) {
        self.resolver = resolver; self.fetcher = fetcher; self.network = network
        self.maxBytes = maxBytes; self.maxConcurrent = max(1, maxConcurrent)
        self.ttl = ttl; self.now = now
    }

    /// Neighbours of `current` in `channels` (previous, next; wraps around).
    public static func neighbours(of current: Channel, in channels: [Channel]) -> [Channel] {
        guard channels.count > 1, let i = channels.firstIndex(where: { $0.id == current.id }) else { return [] }
        let prev = channels[(i - 1 + channels.count) % channels.count]
        let next = channels[(i + 1) % channels.count]
        return prev.id == next.id ? [prev] : [prev, next]
    }

    /// Whether pre-reading bytes of `stream` is safe for `request` (whose item is the neighbour channel):
    /// HLS only, and not on an Xtream source unless its stored account allows `max_connections > 1`.
    public static func allowsByteRead(stream: ResolvedStream, request: PlaybackRequest) -> Bool {
        guard stream.container == .hls, case .channel(let channel) = request.item else { return false }
        // The request's source describes the neighbour only when both belong to the same source.
        if let source = request.source, source.id == channel.sourceId {
            guard source.type == .xtream else { return true }
            return (source.xtreamAccount?.maxConnections ?? 0) > 1
        }
        // No (matching) source info: a channel without its own URL is an Xtream one (URL built from secrets) → unknown.
        return channel.url != nil
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
                self.resolved[channel.id] = (stream, self.now())
                guard Self.allowsByteRead(stream: stream, request: req) else { return }
                _ = try? await fetcher.fetch(stream.url, headers: stream.headers, maxBytes: maxBytes)
            })
        }
    }

    /// Cached resolution for a channel id (consumed once), nil if none or older than the TTL.
    public func takeResolved(channelId: String) -> ResolvedStream? {
        guard let entry = resolved.removeValue(forKey: channelId),
              now().timeIntervalSince(entry.at) <= ttl else { return nil }
        return entry.stream
    }

    public func cancelAll() {
        tasks.forEach { $0.cancel() }
        tasks.removeAll()
        resolved.removeAll()
    }
}

/// URLSession-backed fetcher: Range GET (the caller only uses it for small HLS manifests); the
/// returned count is capped at `maxBytes`.
public struct URLSessionPrefetchFetcher: PrefetchFetcher {
    public init() {}
    public func fetch(_ url: URL, headers: [String: String], maxBytes: Int) async throws -> Int {
        var request = URLRequest(url: url, timeoutInterval: 5)
        headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        request.setValue("bytes=0-\(maxBytes - 1)", forHTTPHeaderField: "Range")
        let (data, _) = try await URLSession.shared.data(for: request)
        return min(data.count, maxBytes)
    }
}

#if canImport(Network)
/// Reads NWPathMonitor; expensive (cellular/hotspot) or constrained (Low Data Mode) → no prefetch.
public final class PathNetworkConditions: NetworkConditions, @unchecked Sendable {
    private let monitor = NWPathMonitor()
    private let lock = NSLock()
    /// Fails closed (no prefetch) until the path is known.
    private var flag = true
    public init() {
        monitor.pathUpdateHandler = { [weak self] path in
            self?.lock.withLock { self?.flag = path.isExpensive || path.isConstrained }
        }
        monitor.start(queue: DispatchQueue(label: "prefetch.path"))
        let path = monitor.currentPath
        if path.status == .satisfied { lock.withLock { flag = path.isExpensive || path.isConstrained } }
    }
    deinit { monitor.cancel() }
    public var isExpensiveOrConstrained: Bool { lock.withLock { flag } }
}
#endif
