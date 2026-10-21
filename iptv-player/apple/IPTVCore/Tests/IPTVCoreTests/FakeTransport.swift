import Foundation
@testable import IPTVCore

/// In-memory `HTTPTransport` that records requests and answers from a closure.
final class FakeTransport: HTTPTransport, @unchecked Sendable {   // state guarded by `lock`
    private let lock = NSLock()
    private var recorded: [HTTPRequest] = []
    private let handler: @Sendable (HTTPRequest) throws -> HTTPResponse

    init(_ handler: @escaping @Sendable (HTTPRequest) throws -> HTTPResponse) {
        self.handler = handler
    }

    var requests: [HTTPRequest] {
        lock.withLock { recorded }
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        lock.withLock { recorded.append(request) }
        return try handler(request)
    }
}
