import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Timeouts of one request (CONTRACT §2).
public struct HTTPTimeouts: Sendable, Hashable {
    /// Connection establishment. URLSession has no separate connect timeout, so
    /// `URLSessionTransport` bounds connection setup by `read` (idle timeout) and `total`;
    /// transports with a real connect timeout (e.g. OkHttp, Network.framework) use this value.
    public var connect: TimeInterval
    /// Idle time between received bytes.
    public var read: TimeInterval
    /// Whole call, including body download.
    public var total: TimeInterval

    public init(connect: TimeInterval, read: TimeInterval, total: TimeInterval) {
        self.connect = connect
        self.read = read
        self.total = total
    }

    /// Xtream JSON calls: 10 s / 30 s / 20 s.
    public static let xtreamJSON = HTTPTimeouts(connect: 10, read: 30, total: 20)
    /// Playlists and EPG: 10 s / 30 s / 120 s.
    public static let playlist = HTTPTimeouts(connect: 10, read: 30, total: 120)
    /// Backend API calls.
    public static let backend = HTTPTimeouts(connect: 10, read: 30, total: 30)
}

/// HTTP method.
public enum HTTPMethod: String, Sendable, Hashable {
    case get = "GET", post = "POST", put = "PUT", delete = "DELETE"
}

/// A transport-independent HTTP request.
public struct HTTPRequest: Sendable, Hashable {
    public var method: HTTPMethod
    public var url: URL
    public var headers: [String: String]
    public var body: Data?
    public var timeouts: HTTPTimeouts

    public init(method: HTTPMethod = .get, url: URL, headers: [String: String] = [:], body: Data? = nil,
                timeouts: HTTPTimeouts = .xtreamJSON) {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
        self.timeouts = timeouts
    }
}

/// A buffered HTTP response.
public struct HTTPResponse: Sendable, Hashable {
    public var statusCode: Int
    /// Header names lowercased.
    public var headers: [String: String]
    public var body: Data

    public init(statusCode: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.statusCode = statusCode
        self.headers = Dictionary(headers.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { a, _ in a })
        self.body = body
    }

    public func header(_ name: String) -> String? { headers[name.lowercased()] }
}

/// A streamed HTTP response: status/headers first, then the body in chunks.
public struct HTTPStreamResponse: Sendable {
    public var statusCode: Int
    /// Header names lowercased.
    public var headers: [String: String]
    public var body: AsyncThrowingStream<Data, Error>

    public init(statusCode: Int, headers: [String: String], body: AsyncThrowingStream<Data, Error>) {
        self.statusCode = statusCode
        self.headers = Dictionary(headers.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { a, _ in a })
        self.body = body
    }

    public func header(_ name: String) -> String? { headers[name.lowercased()] }

    /// Collects the whole body (only for small responses, e.g. error pages).
    public func collect(limit: Int = 1 << 20) async throws -> Data {
        var data = Data()
        for try await chunk in body {
            data.append(chunk)
            if data.count >= limit { break }
        }
        return data
    }
}

/// Abstraction over HTTP so clients can be tested without a server.
///
/// Implementations throw `URLError` (or `CancellationError`) for transport failures; HTTP
/// error statuses are returned, not thrown. Requests must honour task cancellation.
public protocol HTTPTransport: Sendable {
    /// Performs a request and buffers the body.
    func send(_ request: HTTPRequest) async throws -> HTTPResponse
    /// Performs a request and streams the body (playlists, EPG).
    func stream(_ request: HTTPRequest) async throws -> HTTPStreamResponse
}

extension HTTPTransport {
    /// Default streaming: buffer via `send` and emit one chunk (fine for fakes/small bodies).
    public func stream(_ request: HTTPRequest) async throws -> HTTPStreamResponse {
        let response = try await send(request)
        let body = AsyncThrowingStream<Data, Error> { continuation in
            if !response.body.isEmpty { continuation.yield(response.body) }
            continuation.finish()
        }
        return HTTPStreamResponse(statusCode: response.statusCode, headers: response.headers, body: body)
    }
}

/// Async sleep abstraction (retry/back-off delays) so tests run instantly.
public struct Sleeper: Sendable {
    public let sleep: @Sendable (TimeInterval) async throws -> Void

    public init(_ sleep: @escaping @Sendable (TimeInterval) async throws -> Void) {
        self.sleep = sleep
    }

    /// Real `Task.sleep`; throws `CancellationError` when cancelled.
    public static let live = Sleeper { seconds in
        try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
    }

    /// No delay (tests).
    public static let immediate = Sleeper { _ in try Task.checkCancellation() }
}

/// Retry policy for idempotent source GETs (CONTRACT §2): at most 2 retries after 2 s and
/// 4 s, only for `Network` and `ServerError(5xx)`; never for 4xx.
public struct RetryPolicy: Sendable, Hashable {
    /// Delay before each retry; the count is the maximum number of retries.
    public var delays: [TimeInterval]

    public init(delays: [TimeInterval]) {
        self.delays = delays
    }

    public static let sourceDefault = RetryPolicy(delays: [2, 4])
    public static let none = RetryPolicy(delays: [])

    /// Runs `operation`, retrying retryable `SourceError`s. Every error is mapped to
    /// `SourceError`; cancellation (also during back-off) yields `.cancelled`.
    public func run<T: Sendable>(sleeper: Sleeper = .live, _ operation: () async throws -> T) async throws -> T {
        var attempt = 0
        while true {
            do {
                try Task.checkCancellation()
                return try await operation()
            } catch {
                let mapped = ErrorClassifier.sourceError(from: error)
                guard mapped.isRetryable, attempt < delays.count, !Task.isCancelled else { throw mapped }
                do {
                    try await sleeper.sleep(delays[attempt])
                } catch {
                    throw SourceError.cancelled
                }
                attempt += 1
            }
        }
    }
}
