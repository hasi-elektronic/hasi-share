import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// `HTTPTransport` on top of URLSession (Apple platforms and Linux).
///
/// * `send`: buffered data task; idle timeout = `timeouts.read` (`URLRequest.timeoutInterval`),
///   whole-call timeout = `timeouts.total` (raced, throws `URLError(.timedOut)`).
/// * `stream`: a dedicated delegate-based session per call (`timeoutIntervalForRequest` =
///   read, `timeoutIntervalForResource` = total); the body is delivered as it arrives.
/// * Both cancel the underlying task when the calling Swift task is cancelled.
public final class URLSessionTransport: HTTPTransport, @unchecked Sendable {
    /// Shared instance with default configuration.
    public static let shared = URLSessionTransport()

    private let configuration: URLSessionConfiguration
    private let session: URLSession
    private let defaultHeaders: [String: String]

    /// - Parameters:
    ///   - configuration: base configuration (copied).
    ///   - defaultHeaders: headers added to every request unless overridden (e.g. `User-Agent`).
    public init(configuration: URLSessionConfiguration = .default, defaultHeaders: [String: String] = [:]) {
        let config = configuration.copy() as? URLSessionConfiguration ?? .default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 600
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.configuration = config
        self.session = URLSession(configuration: config)
        self.defaultHeaders = defaultHeaders
    }

    private func makeURLRequest(_ request: HTTPRequest) -> URLRequest {
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method.rawValue
        urlRequest.timeoutInterval = request.timeouts.read
        urlRequest.cachePolicy = .reloadIgnoringLocalCacheData
        for (name, value) in defaultHeaders { urlRequest.setValue(value, forHTTPHeaderField: name) }
        for (name, value) in request.headers { urlRequest.setValue(value, forHTTPHeaderField: name) }
        urlRequest.httpBody = request.body
        return urlRequest
    }

    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let urlRequest = makeURLRequest(request)
        let session = self.session
        return try await withTotalTimeout(request.timeouts.total) {
            try await URLSessionTransport.dataTask(session: session, request: urlRequest)
        }
    }

    private static func dataTask(session: URLSession, request: URLRequest) async throws -> HTTPResponse {
        let box = TaskBox()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<HTTPResponse, Error>) in
                let task = session.dataTask(with: request) { data, response, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else if let http = response as? HTTPURLResponse {
                        continuation.resume(returning: HTTPResponse(statusCode: http.statusCode,
                                                                    headers: headerDictionary(http),
                                                                    body: data ?? Data()))
                    } else {
                        continuation.resume(throwing: URLError(.badServerResponse))
                    }
                }
                box.set(task)
                task.resume()
            }
        } onCancel: {
            box.cancel()
        }
    }

    public func stream(_ request: HTTPRequest) async throws -> HTTPStreamResponse {
        let config = configuration.copy() as? URLSessionConfiguration ?? .default
        config.timeoutIntervalForRequest = request.timeouts.read
        config.timeoutIntervalForResource = request.timeouts.total
        let (body, bodyContinuation) = AsyncThrowingStream<Data, Error>.makeStream()
        let delegate = StreamingDelegate(body: bodyContinuation)
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        let task = session.dataTask(with: makeURLRequest(request))
        let box = TaskBox()
        box.set(task)
        bodyContinuation.onTermination = { _ in
            box.cancel()
            session.invalidateAndCancel()
        }
        let head = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<HTTPResponse, Error>) in
                delegate.setHeadContinuation(continuation)
                task.resume()
            }
        } onCancel: {
            box.cancel()
        }
        return HTTPStreamResponse(statusCode: head.statusCode, headers: head.headers, body: body)
    }
}

/// Header dictionary of an HTTP response (names lowercased).
func headerDictionary(_ response: HTTPURLResponse) -> [String: String] {
    var headers: [String: String] = [:]
    for (key, value) in response.allHeaderFields {
        headers[String(describing: key).lowercased()] = String(describing: value)
    }
    return headers
}

/// Holds a URLSessionTask for cancellation from another thread (race-free).
final class TaskBox: @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionTask?
    private var cancelled = false

    func set(_ task: URLSessionTask) {
        lock.lock()
        self.task = task
        let cancelNow = cancelled
        lock.unlock()
        if cancelNow { task.cancel() }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let task = self.task
        lock.unlock()
        task?.cancel()
    }
}

/// Delegate for streamed downloads. The response head is delivered with the first body
/// chunk (or at completion for empty bodies), which keeps the delegate signatures identical
/// on Apple platforms and Linux.
final class StreamingDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var headContinuation: CheckedContinuation<HTTPResponse, Error>?
    private var headDelivered = false
    private let body: AsyncThrowingStream<Data, Error>.Continuation

    init(body: AsyncThrowingStream<Data, Error>.Continuation) {
        self.body = body
    }

    func setHeadContinuation(_ continuation: CheckedContinuation<HTTPResponse, Error>) {
        lock.lock()
        headContinuation = continuation
        lock.unlock()
    }

    private func deliverHead(_ task: URLSessionTask, error: Error?) {
        lock.lock()
        guard !headDelivered, let continuation = headContinuation else {
            lock.unlock()
            return
        }
        headDelivered = true
        headContinuation = nil
        lock.unlock()
        if let error {
            continuation.resume(throwing: error)
        } else if let http = task.response as? HTTPURLResponse {
            continuation.resume(returning: HTTPResponse(statusCode: http.statusCode, headers: headerDictionary(http)))
        } else {
            continuation.resume(throwing: URLError(.badServerResponse))
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        deliverHead(dataTask, error: nil)
        body.yield(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        deliverHead(task, error: error)
        if let error {
            body.finish(throwing: error)
        } else {
            body.finish()
        }
        session.finishTasksAndInvalidate()
    }
}

/// Races `operation` against a timer; throws `URLError(.timedOut)` after `seconds`.
func withTotalTimeout<T: Sendable>(_ seconds: TimeInterval, _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
            throw URLError(.timedOut)
        }
        defer { group.cancelAll() }
        guard let first = try await group.next() else { throw URLError(.unknown) }
        return first
    }
}
