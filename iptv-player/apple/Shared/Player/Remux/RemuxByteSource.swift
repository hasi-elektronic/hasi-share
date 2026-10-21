import Foundation

/// Seekable, blocking byte source over HTTP – the input of the FFmpeg demuxer (custom `AVIOContext`,
/// `nova_remux.c`). Reads happen on the remux worker thread and block until their block arrived;
/// `URLSession` callbacks fill the cache on their own queue.
///
/// Build 26 – one streaming connection (owner report: films froze after ~5 min): the source keeps ONE
/// open-ended range request (`Range: bytes=S-`) and slices what arrives into fixed-size blocks, like a
/// sequential player. Before, every 1 MiB block was its own request, one at a time: with a 300 ms server
/// response a 15 Mbit/s film was produced at only 1.6× real time – a slower answer or a dip in bandwidth
/// emptied AVPlayer's buffer within minutes. Now the request overhead is paid once per seek, not per MiB.
///
/// * One connection to the provider at any time (IPTV accounts often allow only one).
/// * A read outside the stream's reach (a seek, the cues at the file end) cancels the stream and opens a
///   new one at the needed block; a stream that runs `readAhead` blocks ahead of the reader is suspended
///   (TCP back-pressure) and resumed when the reader catches up.
/// * LRU cache of `maxBlocks` blocks. The stream's own headers (User-Agent, Referer, …) go with every
///   request; nothing is logged with the URL (SafeLog rules).
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
    private let timeout: TimeInterval
    /// A bundled file (the A/V calibration clip, Build 29): read directly, no HTTP.
    private let file: FileHandle?

    private let cond = NSCondition()
    // Guarded by `cond`.
    private var blocks: [Int: Data] = [:]
    private var lruOrder: [Int] = []
    private var stream: Stream?
    /// Error of the last stream for the block it was about to deliver (cleared when a read restarts it).
    private var streamFailure: (index: Int, error: SourceError)?
    private var interrupted = false
    private var closed = false
    private var total: Int64 = -1
    private var position: Int64 = 0
    /// Block the reader asked for last (drives suspend / resume of the stream).
    private var readerIndex = 0
    /// Transport drops of the stream since the last delivered block (each one reconnects at the block it was filling).
    private var transportRetries = 0
    static let maxTransportRetries = 3
    private var stats = Stats()

    /// The running request: its task, the block it is filling and the bytes received for it.
    private struct Stream {
        let task: URLSessionDataTask
        var index: Int
        var buffer = Data()
        var accepted = false
        var suspended = false
    }

    struct Stats: Sendable {
        var requests = 0
        var bytes: Int64 = 0
        var waitMs: Double = 0
    }

    /// - Parameters:
    ///   - maxBlocks: cache size in blocks.
    ///   - readAhead: blocks the stream may run ahead of the reader before it is suspended.
    ///   - maxInFlight: kept for callers / the harness; the source never opens more than one connection.
    init(url: URL, headers: [String: String], blockSize: Int = 512 * 1024, maxBlocks: Int = 48,
         readAhead: Int = 6, maxInFlight: Int = 1, timeout: TimeInterval = 15) {
        self.url = url
        self.headers = headers
        self.blockSize = blockSize
        self.maxBlocks = maxBlocks
        self.readAhead = max(2, min(readAhead, maxBlocks / 2))
        self.timeout = timeout
        if url.isFileURL, let handle = try? FileHandle(forReadingFrom: url) {
            file = handle
            total = (try? handle.seekToEnd()).map(Int64.init) ?? -1
        } else {
            file = nil
        }
        let config = URLSessionConfiguration.ephemeral
        config.httpMaximumConnectionsPerHost = 1   // never more than one connection per stream (single-connection IPTV accounts)
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = timeout
        let delegate = Delegate()
        session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        delegate.owner = self
    }

    /// Streams the response into blocks and rejects a 200 answer to a range request at once (a server
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

    deinit {
        session.invalidateAndCancel()
        try? file?.close()
    }

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
        stream?.task.cancel()
        stream = nil
        blocks.removeAll()
        cond.broadcast()
        cond.unlock()
        session.invalidateAndCancel()
    }

    // MARK: Blocks (cond held)

    private func waitForBlockLocked(_ index: Int) throws {
        readerIndex = index
        if let file {
            if blocks[index] == nil {
                guard (try? file.seek(toOffset: UInt64(index) * UInt64(blockSize))) != nil,
                      let data = try? file.read(upToCount: blockSize), !data.isEmpty || index == 0 else { throw SourceError.transport }
                storeLocked(index, data)
            }
            touchLocked(index)
            return
        }
        if blocks[index] != nil {
            touchLocked(index)
            regulateStreamLocked()
            return
        }
        if streamFailure?.index == index { streamFailure = nil }
        ensureStreamLocked(for: index)
        let started = DispatchTime.now().uptimeNanoseconds
        var deadline = Date().addingTimeInterval(timeout)
        var lastProgress = stats.bytes
        while blocks[index] == nil {
            if closed { throw SourceError.cancelled }
            if interrupted { throw SourceError.cancelled }
            if let failure = streamFailure, failure.index <= index {
                streamFailure = nil
                // A dropped connection (common with IPTV panels) reconnects at the same byte, not an error.
                if failure.error == .transport, transportRetries < Self.maxTransportRetries {
                    transportRetries += 1
                    cond.unlock()
                    Thread.sleep(forTimeInterval: 0.3 * Double(transportRetries))
                    cond.lock()
                    if closed || interrupted { throw SourceError.cancelled }
                    if blocks[index] == nil, stream == nil { startStreamLocked(at: failure.index) }
                    deadline = Date().addingTimeInterval(timeout)
                    continue
                }
                throw failure.error
            }
            if stream == nil { ensureStreamLocked(for: index) }   // ended before this block (a later read restarts it)
            if !cond.wait(until: deadline) {
                // Bytes still arriving (for this block or the ones before it): a slow link, not a dead one.
                let progress = stats.bytes
                if stream != nil, progress > lastProgress {
                    lastProgress = progress
                    deadline = Date().addingTimeInterval(timeout)
                    continue
                }
                stream?.task.cancel()
                stream = nil
                throw SourceError.timeout
            }
        }
        stats.waitMs += Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
        touchLocked(index)
        regulateStreamLocked()
    }

    /// The stream reaches `index` soon (it is at or a little before it) – else a new stream starts there.
    private func ensureStreamLocked(for index: Int) {
        if let s = stream, s.index <= index, index <= s.index + readAhead {
            if s.suspended { s.task.resume(); stream?.suspended = false }
            return
        }
        stream?.task.cancel()
        startStreamLocked(at: index)
    }

    /// Suspends a stream far ahead of the reader (memory, fairness to the provider); resumes it when the reader
    /// gets close again.
    private func regulateStreamLocked() {
        guard let s = stream else {
            // Sequential reading continues past what is cached: start streaming ahead of the reader.
            if let next = firstMissingBlockLocked(after: readerIndex), next <= readerIndex + readAhead / 2 {
                startStreamLocked(at: next)
            }
            return
        }
        if !s.suspended, s.index > readerIndex + readAhead {
            s.task.suspend()
            stream?.suspended = true
        } else if s.suspended, s.index <= readerIndex + readAhead / 2 {
            s.task.resume()
            stream?.suspended = false
        }
    }

    private func firstMissingBlockLocked(after index: Int) -> Int? {
        guard total > 0 else { return nil }
        let lastBlock = Int((total - 1) / Int64(blockSize))
        var next = index + 1
        while next <= lastBlock {
            if blocks[next] == nil { return next }
            next += 1
        }
        return nil
    }

    private func startStreamLocked(at index: Int) {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        request.setValue("bytes=\(Int64(index) * Int64(blockSize))-", forHTTPHeaderField: "Range")
        stats.requests += 1
        let task = session.dataTask(with: request)
        stream = Stream(task: task, index: index)
        task.resume()
    }

    // MARK: URLSession callbacks (delegate queue)

    fileprivate func accept(_ task: URLSessionDataTask, response: HTTPURLResponse?) -> Bool {
        cond.lock()
        defer { cond.broadcast(); cond.unlock() }
        guard let s = stream, s.task === task, !closed else { return false }
        let status = response?.statusCode ?? 0
        switch status {
        case 206:
            if total < 0, let range = response?.value(forHTTPHeaderField: "Content-Range"),
               let slash = range.lastIndex(of: "/"), let size = Int64(range[range.index(after: slash)...]) {
                total = size
            }
            stream?.accepted = true
            return true
        case 200 where s.index == 0 && (0...Int64(blockSize)).contains(response?.expectedContentLength ?? -1):
            // Whole (tiny) file without range support.
            total = response?.expectedContentLength ?? -1
            stream?.accepted = true
            return true
        case 200:
            failStreamLocked(.notSeekable)
            return false
        default:
            failStreamLocked(.httpStatus(status))
            return false
        }
    }

    fileprivate func append(_ task: URLSessionDataTask, data: Data) {
        cond.lock()
        defer { cond.unlock() }
        guard var s = stream, s.task === task, !closed else { return }
        stats.bytes += Int64(data.count)
        var offset = 0
        var filled = false
        while offset < data.count {
            let take = min(blockSize - s.buffer.count, data.count - offset)
            s.buffer.append(data.subdata(in: offset..<(offset + take)))
            offset += take
            if s.buffer.count == blockSize {
                transportRetries = 0
                storeLocked(s.index, s.buffer)
                s.index += 1
                s.buffer = Data()
                filled = true
            }
        }
        stream = s
        if filled {
            regulateStreamLocked()
            cond.broadcast()
        }
    }

    fileprivate func complete(_ task: URLSessionTask, error: Error?) {
        cond.lock()
        defer { cond.broadcast(); cond.unlock() }
        guard let s = stream, s.task === task else { return }
        stream = nil
        if closed { return }
        if error == nil {
            // End of file: the last (short) block.
            if !s.buffer.isEmpty { storeLocked(s.index, s.buffer) }
            return
        }
        let cancelled = (error as? URLError)?.code == .cancelled
        if !cancelled, streamFailure == nil { streamFailure = (s.index, .transport) }
    }

    /// cond held.
    private func failStreamLocked(_ error: SourceError) {
        guard let s = stream else { return }
        stream = nil
        streamFailure = (s.index, error)
    }

    private func storeLocked(_ index: Int, _ data: Data) {
        blocks[index] = data
        touchLocked(index)
        while blocks.count > maxBlocks, let oldest = lruOrder.first {
            lruOrder.removeFirst()
            blocks[oldest] = nil
        }
    }

    private func touchLocked(_ index: Int) {
        if let i = lruOrder.firstIndex(of: index) { lruOrder.remove(at: i) }
        lruOrder.append(index)
    }
}
