import Foundation
import Network

/// Minimal HTTP/1.1 server on 127.0.0.1 (ephemeral port, Network.framework, no dependencies) that
/// serves the remux sessions to AVPlayer:
///
///     /<token>/master.m3u8 · /<token>/media.m3u8 · /<token>/init.mp4 · /<token>/seg<N>.m4s
///
/// The 128-bit random token is the only access control: other processes on the device can reach
/// loopback ports, so a session is only reachable while it exists and by whoever knows its token.
/// Keep-alive, GET/HEAD and single byte ranges are supported.
final class RemuxHTTPServer: @unchecked Sendable {
    static let shared = RemuxHTTPServer()

    private let queue = DispatchQueue(label: "nova.remux.http")
    private let lock = NSLock()
    private var listener: NWListener?
    private var port: UInt16 = 0
    private var sessions: [String: RemuxSession] = [:]
    private var starting: [CheckedContinuation<UInt16, Error>] = []

    /// Starts the listener once; returns the port.
    func start() async throws -> UInt16 {
        if let port = lock.withLock({ self.port > 0 ? self.port : nil }) { return port }
        return try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if port > 0 { lock.unlock(); continuation.resume(returning: port); return }
            starting.append(continuation)
            let needsListener = listener == nil
            lock.unlock()
            if needsListener { startListener() }
        }
    }

    private func startListener() {
        do {
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
            parameters.allowLocalEndpointReuse = true
            let listener = try NWListener(using: parameters)
            listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
            listener.stateUpdateHandler = { [weak self] state in self?.listenerState(state) }
            lock.withLock { self.listener = listener }
            listener.start(queue: queue)
        } catch {
            finishStart(.failure(error))
        }
    }

    private func listenerState(_ state: NWListener.State) {
        switch state {
        case .ready:
            let value = lock.withLock { listener?.port?.rawValue ?? 0 }
            lock.withLock { port = value }
            finishStart(.success(value))
        case .failed(let error):
            lock.withLock {
                listener?.cancel()
                listener = nil
                port = 0
            }
            finishStart(.failure(error))
        case .cancelled:
            lock.withLock { listener = nil; port = 0 }
        default:
            break
        }
    }

    private func finishStart(_ result: Result<UInt16, Error>) {
        let waiting = lock.withLock { () -> [CheckedContinuation<UInt16, Error>] in
            defer { starting.removeAll() }
            return starting
        }
        for continuation in waiting { continuation.resume(with: result) }
    }

    func register(_ session: RemuxSession) {
        lock.withLock { sessions[session.token] = session }
    }

    func unregister(_ session: RemuxSession) {
        lock.withLock { sessions[session.token] = nil }
    }

    /// `http://127.0.0.1:<port>/<token>/master.m3u8`
    func url(for session: RemuxSession, port: UInt16) -> URL {
        URL(string: "http://127.0.0.1:\(port)/\(session.token)/master.m3u8")!
    }

    // MARK: Connections

    private func accept(_ connection: NWConnection) {
        let handler = Connection(connection: connection, server: self)
        handler.start(on: queue)
    }

    fileprivate func session(_ token: Substring) -> RemuxSession? {
        lock.withLock { sessions[String(token)] }
    }

    /// One client connection: reads requests (keep-alive) and answers them in order.
    private final class Connection: @unchecked Sendable {
        let connection: NWConnection
        weak var server: RemuxHTTPServer?
        private var buffer = Data()
        /// Pending segment request (for `cancel(waiter:)` when the client disconnects).
        private var waiting: (session: RemuxSession, id: UInt64)?
        private var closed = false

        init(connection: NWConnection, server: RemuxHTTPServer) {
            self.connection = connection
            self.server = server
        }

        func start(on queue: DispatchQueue) {
            connection.stateUpdateHandler = { [self] state in
                switch state {
                case .failed:
                    disconnected()
                    connection.cancel()
                case .cancelled: disconnected()
                default: break
                }
            }
            connection.start(queue: queue)
            receive()
        }

        private func disconnected() {
            guard !closed else { return }
            closed = true
            if let waiting { waiting.session.cancel(waiter: waiting.id) }
            waiting = nil
            connection.stateUpdateHandler = nil
        }

        private func receive() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [self] data, _, isComplete, error in
                if let data { buffer.append(data) }
                if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                    let head = String(decoding: buffer[buffer.startIndex..<end.lowerBound], as: UTF8.self)
                    buffer.removeSubrange(buffer.startIndex..<end.upperBound)
                    handle(head)
                } else if isComplete || error != nil || buffer.count > 64 * 1024 {
                    connection.cancel()
                } else {
                    receive()
                }
            }
        }

        private func handle(_ head: String) {
            let lines = head.split(separator: "\r\n", omittingEmptySubsequences: false)
            let parts = lines.first?.split(separator: " ") ?? []
            guard parts.count >= 2, parts[0] == "GET" || parts[0] == "HEAD" else { return respond(405, body: Data()) }
            let isHead = parts[0] == "HEAD"
            var parsedRange: (Int, Int?)?
            for line in lines.dropFirst() {
                let lower = line.lowercased()
                if lower.hasPrefix("range:"), let spec = lower.split(separator: "=").last {
                    let bounds = spec.split(separator: "-", omittingEmptySubsequences: false)
                    if bounds.count == 2, let a = Int(bounds[0].trimmingCharacters(in: .whitespaces)) {
                        parsedRange = (a, Int(bounds[1].trimmingCharacters(in: .whitespaces)))
                    }
                }
            }
            let range = parsedRange
            let path = parts[1].split(separator: "?").first ?? ""
            let components = path.split(separator: "/")
            guard components.count == 2, let session = server?.session(components[0]) else { return respond(404, body: Data()) }
            let name = components[1]
            switch name {
            case "master.m3u8":
                respond(200, type: "application/vnd.apple.mpegurl", body: Data(session.masterPlaylist().utf8), head: isHead)
            case "media.m3u8":
                respond(200, type: "application/vnd.apple.mpegurl", body: Data(session.mediaPlaylist().utf8), head: isHead)
            case "init.mp4":
                session.initSegment { [self] result in deliver(result, type: "video/mp4", range: range, head: isHead) }
            default:
                guard name.hasPrefix("seg"), name.hasSuffix(".m4s"),
                      let index = Int(name.dropFirst(3).dropLast(4)), index >= 0, index < session.info.segments.count else {
                    return respond(404, body: Data())
                }
                let id = session.segment(index) { [self] result in
                    connection.queue?.async { [self] in
                        waiting = nil
                        deliver(result, type: "video/iso.segment", range: range, head: isHead)
                    }
                }
                if id != 0 { waiting = (session, id) }
            }
        }

        private func deliver(_ result: Result<Data, RemuxSession.RemuxError>, type: String, range: (Int, Int?)?, head: Bool) {
            guard !closed else { return }
            switch result {
            case .success(let data):
                if let range, range.0 < data.count {
                    let end = min(range.1 ?? data.count - 1, data.count - 1)
                    let slice = data.subdata(in: range.0..<(end + 1))
                    respond(206, type: type, body: slice, head: head,
                            extra: "Content-Range: bytes \(range.0)-\(end)/\(data.count)\r\n")
                } else {
                    respond(200, type: type, body: data, head: head)
                }
            case .failure(.cancelled):
                respond(503, body: Data())
            case .failure:
                respond(500, body: Data())
            }
        }

        private func respond(_ status: Int, type: String = "text/plain", body: Data, head: Bool = false, extra: String = "") {
            guard !closed else { return }
            let reason = [200: "OK", 206: "Partial Content", 404: "Not Found", 405: "Method Not Allowed",
                          500: "Internal Server Error", 503: "Service Unavailable"][status] ?? "Error"
            var header = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\n"
            header += "Accept-Ranges: bytes\r\nCache-Control: no-cache\r\nConnection: keep-alive\r\n\(extra)\r\n"
            var payload = Data(header.utf8)
            if !head { payload.append(body) }
            connection.send(content: payload, completion: .contentProcessed { [self] error in
                if error != nil { connection.cancel(); return }
                // Pipelined request already buffered → answer it, else wait for the next one.
                if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                    let head = String(decoding: buffer[buffer.startIndex..<end.lowerBound], as: UTF8.self)
                    buffer.removeSubrange(buffer.startIndex..<end.upperBound)
                    handle(head)
                } else {
                    receive()
                }
            })
        }
    }
}
