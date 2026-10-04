import Foundation
import IPTVCore

/// What the user wants to play (built by the view models from catalog rows).
public struct PlaybackRequest: Sendable, Hashable, Identifiable {
    public enum Item: Sendable, Hashable {
        case channel(Channel)
        case movie(Movie)
        case episode(Episode, seriesTitle: String)
        /// A raw URL (format test screen).
        case url(String, title: String)
    }

    public var item: Item
    public var source: Source?
    /// Channel list for zapping (live only).
    public var channels: [Channel]
    public var startPositionMs: Int64?

    public init(item: Item, source: Source?, channels: [Channel] = [], startPositionMs: Int64? = nil) {
        self.item = item
        self.source = source
        self.channels = channels
        self.startPositionMs = startPositionMs
    }

    public var id: String { contentKey ?? title }

    public var title: String {
        switch item {
        case .channel(let c): return c.name
        case .movie(let m): return m.name
        case .episode(let e, let s): return "\(s) · S\(e.season)E\(e.number) \(e.title)"
        case .url(_, let title): return title
        }
    }

    public var isLive: Bool {
        if case .channel = item { return true }
        return false
    }

    public var contentKind: ContentKind {
        switch item {
        case .channel: return .live
        case .movie, .url: return .movie
        case .episode: return .episode
        }
    }

    public var posterUrl: String? {
        switch item {
        case .channel(let c): return c.logoUrl
        case .movie(let m): return m.posterUrl
        case .episode(let e, _): return e.posterUrl
        case .url: return nil
        }
    }

    /// Content key for favorites/progress (needs the source fingerprint).
    public var contentKey: String? {
        guard let fingerprint = sourceFingerprint else { return nil }
        switch item {
        case .channel(let c): return ContentKey.make(fingerprint: fingerprint, kind: .live, itemId: c.id)
        case .movie(let m): return ContentKey.make(fingerprint: fingerprint, kind: .movie, itemId: m.id)
        case .episode(let e, _): return ContentKey.make(fingerprint: fingerprint, kind: .episode, itemId: e.id)
        case .url: return nil
        }
    }

    /// Set by the resolver/view model (from secrets – never persisted here).
    public var sourceFingerprint: String?
}

/// A resolved, pre-checked stream.
public struct ResolvedStream: Sendable, Hashable {
    public var url: URL
    public var container: StreamContainer
    public var headers: [String: String]
}

/// Builds the stream URL at play time (Xtream URLs contain credentials and are never stored)
/// and runs the format pre-check against the AVPlayer support matrix (CONTRACT §6).
public struct StreamResolver: Sendable {
    public typealias Sniffer = @Sendable (URL, [String: String]) async -> (contentType: String?, bytes: Data?, status: Int?)

    private let secrets: @Sendable (String) -> SourceSecrets?
    private let sniffer: Sniffer?

    /// - Parameters:
    ///   - secrets: lookup of source secrets by source id.
    ///   - sniffer: optional network probe for URLs whose container is not evident (fetches the
    ///     first bytes); nil disables probing (tests).
    public init(secrets: @escaping @Sendable (String) -> SourceSecrets?, sniffer: Sniffer? = StreamResolver.networkSniffer) {
        self.secrets = secrets
        self.sniffer = sniffer
    }

    /// Resolves the URL or throws a `PlaybackError` (e.g. Apple + MPEG-TS → "ask for HLS").
    public func resolve(_ request: PlaybackRequest) async throws -> ResolvedStream {
        let (urlString, headers) = try buildURL(request)
        guard let url = URL(string: urlString.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw PlaybackError.unknown(message: "invalid url")
        }
        var container = StreamFormatDetector.detect(url: url.absoluteString)
        if let error = container.playbackError(for: .avPlayer) { throw error }
        if container == .unknown, let sniffer, let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" {
            let probe = await sniffer(url, headers)
            if let status = probe.status, let error = ErrorClassifier.playbackError(httpStatus: status) { throw error }
            container = StreamFormatDetector.detect(url: url.absoluteString, contentType: probe.contentType, firstBytes: probe.bytes)
            if let error = container.playbackError(for: .avPlayer) { throw error }
        }
        return ResolvedStream(url: url, container: container, headers: headers)
    }

    func buildURL(_ request: PlaybackRequest) throws -> (String, [String: String]) {
        switch request.item {
        case .url(let url, _):
            return (url, [:])
        case .channel(let channel):
            if channel.drm { throw PlaybackError.drm }
            if let url = channel.url {
                var headers: [String: String] = [:]
                if let ua = channel.userAgent { headers["User-Agent"] = ua }
                if let ref = channel.referrer { headers["Referer"] = ref }
                return (url, headers)
            }
            guard case .xtream(let x)? = secrets(channel.sourceId), let builder = XtreamURLBuilder(secrets: x) else {
                throw PlaybackError.unknown(message: "missing source")
            }
            let ext = try XtreamURLBuilder.liveExtension(platform: .apple,
                                                         allowedOutputFormats: request.source?.xtreamAccount?.allowedOutputFormats ?? [])
            return (builder.liveURL(streamId: channel.id, ext: ext).absoluteString, [:])
        case .movie(let movie):
            if let url = movie.url { return (url, [:]) }
            guard case .xtream(let x)? = secrets(movie.sourceId), let builder = XtreamURLBuilder(secrets: x) else {
                throw PlaybackError.unknown(message: "missing source")
            }
            return (builder.movieURL(streamId: movie.id, containerExt: movie.containerExt ?? "mp4").absoluteString, [:])
        case .episode(let episode, _):
            if let url = episode.url { return (url, [:]) }
            guard case .xtream(let x)? = secrets(episode.sourceId), let builder = XtreamURLBuilder(secrets: x) else {
                throw PlaybackError.unknown(message: "missing source")
            }
            return (builder.episodeURL(episodeId: episode.id, containerExt: episode.containerExt ?? "mp4").absoluteString, [:])
        }
    }

    /// Fetches up to 1 KiB of the stream (Range request) with a 6 s budget.
    public static let networkSniffer: Sniffer = { url, headers in
        var request = HTTPRequest(url: url, headers: headers.merging(["Range": "bytes=0-1023"]) { a, _ in a },
                                  timeouts: HTTPTimeouts(connect: 6, read: 6, total: 6))
        request.method = .get
        do {
            let response = try await URLSessionTransport.shared.stream(request)
            let bytes = (200..<300).contains(response.statusCode) ? try await response.collect(limit: 1024) : nil
            return (response.header("content-type"), bytes, response.statusCode)
        } catch {
            return (nil, nil, nil)
        }
    }
}
