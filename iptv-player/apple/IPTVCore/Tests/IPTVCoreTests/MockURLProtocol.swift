import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import IPTVCore

/// Canned answer of `MockURLProtocol`.
struct MockReply: Sendable {
    var status: Int = 200
    var headers: [String: String] = [:]
    /// Body delivered in these chunks (one `didLoad` per chunk).
    var chunks: [Data] = []
    /// Delay before the response head is delivered.
    var delay: TimeInterval = 0
    /// Fail with this error instead of answering.
    var error: URLError?

    static func body(_ data: Data, status: Int = 200, headers: [String: String] = [:], chunkSize: Int? = nil) -> MockReply {
        var chunks: [Data] = []
        if let chunkSize, chunkSize > 0 {
            var offset = 0
            while offset < data.count {
                let end = min(offset + chunkSize, data.count)
                chunks.append(data.subdata(in: offset..<end))
                offset = end
            }
        } else if !data.isEmpty {
            chunks = [data]
        }
        return MockReply(status: status, headers: headers, chunks: chunks)
    }

    static func text(_ s: String, status: Int = 200, contentType: String = "text/html") -> MockReply {
        body(Data(s.utf8), status: status, headers: ["Content-Type": contentType])
    }

    static func failure(_ code: URLError.Code) -> MockReply { MockReply(error: URLError(code)) }
}

/// URLProtocol that answers requests from per-host handlers, so tests can run in parallel
/// with distinct hosts. Each handler is called once per request (retries see it again).
final class MockURLProtocol: URLProtocol, @unchecked Sendable {   // URLProtocol drives one request per instance
    typealias Handler = @Sendable (URLRequest, Int) -> MockReply

    private final class Registry: @unchecked Sendable {   // guarded by `lock`
        let lock = NSLock()
        var handlers: [String: Handler] = [:]
        var counts: [String: Int] = [:]
        var requests: [String: [URLRequest]] = [:]
    }

    private static let registry = Registry()
    private let cancelled = LockedFlag()

    /// Registers a handler for `host` (lowercased) and returns a session configuration that
    /// routes through this protocol.
    static func register(host: String, _ handler: @escaping Handler) -> URLSessionConfiguration {
        registry.lock.withLock {
            registry.handlers[host.lowercased()] = handler
            registry.counts[host.lowercased()] = 0
            registry.requests[host.lowercased()] = []
        }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return config
    }

    static func requests(host: String) -> [URLRequest] {
        registry.lock.withLock { registry.requests[host.lowercased()] ?? [] }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        guard let host = request.url?.host?.lowercased() else { return false }
        return registry.lock.withLock { registry.handlers[host] != nil }
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let request = self.request
        let host = request.url?.host?.lowercased() ?? ""
        let (handler, attempt): (Handler?, Int) = Self.registry.lock.withLock {
            let n = (Self.registry.counts[host] ?? 0) + 1
            Self.registry.counts[host] = n
            Self.registry.requests[host, default: []].append(request)
            return (Self.registry.handlers[host], n)
        }
        let reply = handler?(request, attempt) ?? MockReply(status: 500)
        let deliver = { [self] in
            guard !self.cancelled.value else { return }
            if let error = reply.error {
                self.client?.urlProtocol(self, didFailWithError: error)
                return
            }
            let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1",
                                           headerFields: reply.headers)!
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            for chunk in reply.chunks {
                guard !self.cancelled.value else { return }
                self.client?.urlProtocol(self, didLoad: chunk)
            }
            self.client?.urlProtocolDidFinishLoading(self)
        }
        if reply.delay > 0 {
            DispatchQueue.global().asyncAfter(deadline: .now() + reply.delay, execute: deliver)
        } else {
            deliver()
        }
    }

    override func stopLoading() {
        cancelled.set()
    }
}

final class LockedFlag: @unchecked Sendable {   // guarded by `lock`
    private let lock = NSLock()
    private var flag = false
    var value: Bool { lock.withLock { flag } }
    func set() { lock.withLock { flag = true } }
}
