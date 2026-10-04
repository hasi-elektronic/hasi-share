import Foundation

/// Streaming M3U drivers: parse from `Data`, a file, raw byte chunks, or async sequences of
/// lines/bytes/chunks, emitting entries in batches of at most `batchSize` (≤ 1000 by
/// default, CONTRACT §3.12) without ever materializing the playlist as one string.
///
/// All entry points end with `M3UParseSummary.validate()`, i.e. they throw
/// `SourceError.invalidFormat` / `.empty` per CONTRACT §3.11, and `SourceError.cancelled`
/// when the surrounding task is cancelled.
public enum M3UPlaylist {
    public static let defaultBatchSize = 1000

    /// Parses an in-memory playlist and returns all entries (small lists, tests).
    public static func parse(data: Data) throws -> M3UParseResult {
        var entries: [M3UEntry] = []
        let summary = try parse(data: data, batchSize: defaultBatchSize) { entries.append(contentsOf: $0) }
        return M3UParseResult(epgUrls: summary.epgUrls, skipped: summary.skipped, entries: entries)
    }

    /// Parses an in-memory playlist, delivering batches.
    @discardableResult
    public static func parse(data: Data, batchSize: Int = defaultBatchSize,
                             onBatch: ([M3UEntry]) throws -> Void) throws -> M3UParseSummary {
        var driver = M3UStreamParser(batchSize: batchSize)
        try driver.consume(data, onBatch: onBatch)
        return try driver.finish(onBatch: onBatch)
    }

    /// Parses a playlist file in 64 KiB chunks, delivering batches.
    @discardableResult
    public static func parse(fileURL: URL, batchSize: Int = defaultBatchSize,
                             onBatch: ([M3UEntry]) throws -> Void) throws -> M3UParseSummary {
        let handle: FileHandle
        do { handle = try FileHandle(forReadingFrom: fileURL) } catch { throw SourceError.notFound }
        defer { try? handle.close() }
        var driver = M3UStreamParser(batchSize: batchSize)
        while true {
            if Task.isCancelled { throw SourceError.cancelled }
            let chunk = handle.readData(ofLength: 64 * 1024)
            if chunk.isEmpty { break }
            try driver.consume(chunk, onBatch: onBatch)
        }
        return try driver.finish(onBatch: onBatch)
    }

    /// Parses an async sequence of lines (e.g. `URLSession.AsyncBytes.lines` on Apple).
    @discardableResult
    public static func parse<Lines: AsyncSequence>(lines: Lines, batchSize: Int = defaultBatchSize,
                                                   onBatch: ([M3UEntry]) async throws -> Void) async throws -> M3UParseSummary
    where Lines.Element == String {
        var parser = M3UParser()
        var batch: [M3UEntry] = []
        batch.reserveCapacity(batchSize)
        for try await line in lines {
            if let entry = parser.feed(line: line) {
                batch.append(entry)
                if batch.count >= batchSize {
                    if Task.isCancelled { throw SourceError.cancelled }
                    try await onBatch(batch)
                    batch.removeAll(keepingCapacity: true)
                }
            }
        }
        if Task.isCancelled { throw SourceError.cancelled }
        if !batch.isEmpty { try await onBatch(batch) }
        let summary = parser.finish()
        try summary.validate()
        return summary
    }

    /// Parses an async sequence of data chunks (e.g. `HTTPTransport.stream(_:)` bodies).
    @discardableResult
    public static func parse<Chunks: AsyncSequence>(chunks: Chunks, batchSize: Int = defaultBatchSize,
                                                    onBatch: ([M3UEntry]) async throws -> Void) async throws -> M3UParseSummary
    where Chunks.Element == Data {
        var driver = M3UStreamParser(batchSize: batchSize)
        var ready: [[M3UEntry]] = []
        for try await chunk in chunks {
            if Task.isCancelled { throw SourceError.cancelled }
            driver.consume(chunk) { ready.append($0) }
            for batch in ready { try await onBatch(batch) }
            ready.removeAll(keepingCapacity: true)
        }
        if Task.isCancelled { throw SourceError.cancelled }
        let summary = try driver.finish { ready.append($0) }
        for batch in ready { try await onBatch(batch) }
        return summary
    }

    /// Parses an async sequence of bytes (e.g. `URLSession.AsyncBytes` on Apple).
    @discardableResult
    public static func parse<Bytes: AsyncSequence>(bytes: Bytes, batchSize: Int = defaultBatchSize,
                                                   onBatch: ([M3UEntry]) async throws -> Void) async throws -> M3UParseSummary
    where Bytes.Element == UInt8 {
        var driver = M3UStreamParser(batchSize: batchSize)
        var buffer: [UInt8] = []
        buffer.reserveCapacity(64 * 1024)
        var ready: [[M3UEntry]] = []
        func drain() async throws {
            driver.consume(bytes: buffer) { ready.append($0) }
            buffer.removeAll(keepingCapacity: true)
            for batch in ready { try await onBatch(batch) }
            ready.removeAll(keepingCapacity: true)
        }
        for try await byte in bytes {
            buffer.append(byte)
            if buffer.count >= 64 * 1024 {
                if Task.isCancelled { throw SourceError.cancelled }
                try await drain()
            }
        }
        try await drain()
        let summary = try driver.finish { ready.append($0) }
        for batch in ready { try await onBatch(batch) }
        return summary
    }
}

/// Chunk-level driver: line splitting + parsing + batching. Use it directly when you own
/// the read loop (e.g. a `URLSessionDataDelegate`).
public struct M3UStreamParser: Sendable {
    private var splitter = LineSplitter()
    private var parser = M3UParser()
    private var batch: [M3UEntry] = []
    private let batchSize: Int

    public init(batchSize: Int = M3UPlaylist.defaultBatchSize) {
        self.batchSize = max(1, batchSize)
        batch.reserveCapacity(self.batchSize)
    }

    /// Current counters.
    public var summary: M3UParseSummary { parser.summary }

    /// Consumes a chunk; full batches are delivered to `onBatch`.
    public mutating func consume(_ chunk: Data, onBatch: ([M3UEntry]) throws -> Void) rethrows {
        try chunk.withUnsafeBytes { raw in try consume(raw: raw, onBatch: onBatch) }
    }

    /// Consumes a chunk of bytes.
    public mutating func consume(bytes: [UInt8], onBatch: ([M3UEntry]) throws -> Void) rethrows {
        try bytes.withUnsafeBytes { raw in try consume(raw: raw, onBatch: onBatch) }
    }

    private mutating func consume(raw: UnsafeRawBufferPointer, onBatch: ([M3UEntry]) throws -> Void) rethrows {
        // Move state into locals (no copy-on-write) so the splitter closure does not capture self.
        var parser = M3UParser()
        swap(&parser, &self.parser)
        var batch: [M3UEntry] = []
        swap(&batch, &self.batch)
        defer {
            swap(&parser, &self.parser)
            swap(&batch, &self.batch)
        }
        let batchSize = self.batchSize
        try splitter.consume(raw) { line in
            if let entry = parser.feed(bytes: line) {
                batch.append(entry)
                if batch.count >= batchSize {
                    try onBatch(batch)
                    batch.removeAll(keepingCapacity: true)
                }
            }
        }
    }

    /// Flushes the last line and batch, then validates (throws `.invalidFormat` / `.empty`).
    public mutating func finish(onBatch: ([M3UEntry]) throws -> Void) throws -> M3UParseSummary {
        var parser = M3UParser()
        swap(&parser, &self.parser)
        var batch: [M3UEntry] = []
        swap(&batch, &self.batch)
        splitter.finish { line in
            if let entry = parser.feed(bytes: line) { batch.append(entry) }
        }
        if !batch.isEmpty { try onBatch(batch) }
        let summary = parser.finish()
        self.parser = parser
        try summary.validate()
        return summary
    }
}
