import Foundation

/// Seekable, blocking byte source over HTTP range requests – the input of the FFmpeg demuxer
/// (custom `AVIOContext`, `nova_remux.c`). Reads happen on the remux worker thread and block until
/// the block arrived; `URLSession` callbacks fill the cache on their own queue.
///
/// * Fixed-size blocks (RemuxSession: 1 MiB), LRU cache (≈ 24 MiB), read-ahead (≈ 3 MiB) with
///   at most `maxInFlight` parallel requests (IPTV panels often limit connections per account).
/// * The stream's own headers (User-Agent, Referer, …) go with every request; nothing is logged
///   with the URL (SafeLog rules).
final class RemuxByteSource: @unchecked Sendable {
    enum SourceError: Error, Equatable {
        case httpStatus(Int)
        case notSeekable
        case timeout
        case cancelled
        case transport
    }

    let blockSize: Int
    private let url: URL
    private let headers: [String: String]
    private let session: URLSession
    private let maxBlocks: Int
    private let readAhead: Int
    private let maxInFlight: Int
    private let timeout: TimeInterval

    private let cond = NSCondition()
    // Guarded by `cond`.
    private var blocks: [Int: Data] = [:]
    private var lruOrder: [Int] = []
    private var inFlight: [Int: URLSessionDataTask] = [:]
    /// Task id → (block, received bytes).
    private var pending: [Int: (index: Int, data: Data)] = [:]
    private var failures: [Int: SourceError] = [:]
    private var interrupted = false
    private var closed = false
    private var total: Int64 = -1
    private var position: Int64 = 0
    private var stats = Stats()

    struct Stats: Sendable {
        var requests = 0
        var bytes: Int64 = 0
        var waitMs: Double = 0
    }

    init(url: URL, headers: [String: String], blockSize: Int = 512 * 1024, maxBlocks: Int = 48,
         readAhead: Int = 6, maxInFlight: Int = 2, timeout: TimeInterval = 15) {
        self.url = url
        self.headers = headers
        self.blockSize = blockSize
        self.maxBlocks = maxBlocks
        self.readAhead = readAhead
        self.maxInFlight = maxInFlight
        self.timeout = timeout
        let config = URLSessionConfiguration.ephemeral
        config.httpMaximumConnectionsPerHost = maxInFlight + 1
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = timeout
        let delegate = Delegate()
        session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        delegate.owner = self
    }

    /// Streams each block into `pending` and rejects a 200 answer to a range request at once (a server
    /// without range support would otherwise send the whole film into memory).
    private final class Delegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        weak var owner: RemuxByteSource?

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
            completionHandler(owner?.accept(dataTask, response: response as? HTTPURLResponse) == true ? .allow : .cancel)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            owner?.append(dataTask, data: data)
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            owner?.complete(task, error: error)
        }
    }

    deinit { session.invalidateAndCancel() }

    var size: Int64 { cond.withLock { total } }
    var statistics: Stats { cond.withLock { stats } }

    /// Fetches block 0 (learns the size from `Content-Range`). Throws for HTTP errors and servers
    /// without byte-range support. Blocking – call off the main thread.
    func open() throws {
        cond.lock()
        defer { cond.unlock() }
        try waitForBlockLocked(0)
    }

    // MARK: Reading (worker thread)

    /// Copies up to `count` bytes at the current position; 0 = end, -1 = error/interrupt.
    func read(into buffer: UnsafeMutablePointer<UInt8>, count: Int) -> Int {
        cond.lock()
        defer { cond.unlock() }
        if total >= 0, position >= total { return 0 }
        let index = Int(position / Int64(blockSize))
        do {
            try waitForBlockLocked(index)
        } catch {
            return -1
        }
        guard let data = blocks[index] else { return -1 }
        let offset = Int(position - Int64(index) * Int64(blockSize))
        guard offset < data.count else { return 0 }
        let n = min(count, data.count - offset)
        data.withUnsafeBytes { raw in
            buffer.update(from: raw.baseAddress!.advanced(by: offset).assumingMemoryBound(to: UInt8.self), count: n)
        }
        position += Int64(n)
        prefetchLocked(after: index)
        return n
    }

    /// whence 0/1/2 = SET/CUR/END, 0x10000 = size query.
    func seek(offset: Int64, whence: Int32) -> Int64 {
        cond.lock()
        defer { cond.unlock() }
        switch whence {
        case 0x10000: return total
        case 0: position = offset
        case 1: position += offset
        case 2: guard total >= 0 else { return -1 }; position = total + offset
        default: return -1
        }
        if position < 0 { position = 0 }
        return position
    }

    /// Wakes a blocked read with an error (abort of the current remux job); `false` clears it.
    func setInterrupted(_ on: Bool) {
        cond.lock()
        interrupted = on
        cond.broadcast()
        cond.unlock()
    }

    func close() {
        cond.lock()
        closed = true
        for task in inFlight.values { task.cancel() }
        inFlight.removeAll()
        blocks.removeAll()
        cond.broadcast()
        cond.unlock()
        session.invalidateAndCancel()
    }

    // MARK: Blocks (cond held)

    private func waitForBlockLocked(_ index: Int) throws {
        if blocks[index] != nil { touchLocked(index); return }
        failures[index] = nil
        if inFlight[index] == nil { startFetchLocked(index) }
        let started = DispatchTime.now().uptimeNanoseconds
        let deadline = Date().addingTimeInterval(timeout)
        while blocks[index] == nil {
            if closed { throw SourceError.cancelled }
            if interrupted { throw SourceError.cancelled }
            if let failure = failures[index] { throw failure }
            if !cond.wait(until: deadline) {
                inFlight[index]?.cancel()
                inFlight[index] = nil
                throw SourceError.timeout
            }
        }
        stats.waitMs += Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
        touchLocked(index)
    }

    private func prefetchLocked(after index: Int) {
        guard total > 0 else { return }
        let lastBlock = Int((total - 1) / Int64(blockSize))
        var next = index + 1
        while next <= min(lastBlock, index + readAhead), inFlight.count < maxInFlight {
            if blocks[next] == nil, inFlight[next] == nil { startFetchLocked(next) }
            next += 1
        }
    }

    private func startFetchLocked(_ index: Int) {
        let start = Int64(index) * Int64(blockSize)
        var end = start + Int64(blockSize) - 1
        if total > 0 { end = min(end, total - 1) }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        request.setValue("bytes=\(start)-\(end)", forHTTPHeaderField: "Range")
        stats.requests += 1
        let task = session.dataTask(with: request)
        inFlight[index] = task
        pending[task.taskIdentifier] = (index, Data())
        task.resume()
    }

    // MARK: URLSession callbacks (delegate queue)

    fileprivate func accept(_ task: URLSessionDataTask, response: HTTPURLResponse?) -> Bool {
        cond.lock()
        defer { cond.broadcast(); cond.unlock() }
        guard let entry = pending[task.taskIdentifier], !closed else { return false }
        let status = response?.statusCode ?? 0
        switch status {
        case 206:
            if total < 0, let range = response?.value(forHTTPHeaderField: "Content-Range"),
               let slash = range.lastIndex(of: "/"), let size = Int64(range[range.index(after: slash)...]) {
                total = size
            }
            return true
        case 200 where entry.index == 0 && (0...Int64(blockSize)).contains(response?.expectedContentLength ?? -1):
            // Whole (tiny) file without range support.
            total = response?.expectedContentLength ?? -1
            return true
        case 200:
            fail(task, .notSeekable)
            return false
        default:
            fail(task, .httpStatus(status))
            return false
        }
    }

    fileprivate func append(_ task: URLSessionDataTask, data: Data) {
        cond.lock()
        pending[task.taskIdentifier]?.data.append(data)
        cond.unlock()
    }

    fileprivate func complete(_ task: URLSessionTask, error: Error?) {
        cond.lock()
        defer { cond.broadcast(); cond.unlock() }
        guard let entry = pending.removeValue(forKey: task.taskIdentifier) else { return }
        if inFlight[entry.index] === task { inFlight[entry.index] = nil }
        if closed { return }
        if error != nil {
            if failures[entry.index] == nil { failures[entry.index] = .transport }
            return
        }
        stats.bytes += Int64(entry.data.count)
        blocks[entry.index] = entry.data
        touchLocked(entry.index)
        while blocks.count > maxBlocks, let oldest = lruOrder.first {
            lruOrder.removeFirst()
            blocks[oldest] = nil
        }
    }

    /// cond held.
    private func fail(_ task: URLSessionTask, _ error: SourceError) {
        guard let entry = pending.removeValue(forKey: task.taskIdentifier) else { return }
        if inFlight[entry.index] === task { inFlight[entry.index] = nil }
        failures[entry.index] = error
    }

    private func touchLocked(_ index: Int) {
        if let i = lruOrder.firstIndex(of: index) { lruOrder.remove(at: i) }
        lruOrder.append(index)
    }
}
