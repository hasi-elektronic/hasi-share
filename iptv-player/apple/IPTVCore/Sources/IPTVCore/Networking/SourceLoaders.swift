import Foundation

/// Downloads and parses an M3U playlist in a streaming fashion (CONTRACT §3.12).
public struct M3USourceLoader: Sendable {
    private let transport: any HTTPTransport
    private let retryPolicy: RetryPolicy
    private let sleeper: Sleeper
    private let defaultUserAgent: String?

    public init(transport: any HTTPTransport = URLSessionTransport.shared, retryPolicy: RetryPolicy = .sourceDefault,
                sleeper: Sleeper = .live, defaultUserAgent: String? = nil) {
        self.transport = transport
        self.retryPolicy = retryPolicy
        self.sleeper = sleeper
        self.defaultUserAgent = defaultUserAgent
    }

    /// Loads `secrets.url` (http(s) or a local `file://` URL) and delivers entries in batches.
    /// Connection and HTTP-status failures are retried; once the body is streaming a failure
    /// is thrown (callers discard the partial import). Throws `SourceError`.
    @discardableResult
    public func load(_ secrets: M3USecrets, batchSize: Int = M3UPlaylist.defaultBatchSize,
                     onBatch: ([M3UEntry]) async throws -> Void) async throws -> M3UParseSummary {
        let trimmed = secrets.url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased() else { throw SourceError.invalidFormat }
        if scheme == "file" {
            return try await loadFile(url, batchSize: batchSize, onBatch: onBatch)
        }
        guard scheme == "http" || scheme == "https" else { throw SourceError.invalidFormat }
        var headers: [String: String] = [:]
        if let ua = secrets.userAgent ?? defaultUserAgent { headers["User-Agent"] = ua }
        let request = HTTPRequest(url: url, headers: headers, timeouts: .playlist)
        let transport = self.transport
        let response = try await retryPolicy.run(sleeper: sleeper) { () -> HTTPStreamResponse in
            let response = try await transport.stream(request)
            if let error = ErrorClassifier.sourceError(httpStatus: response.statusCode) { throw error }
            return response
        }
        do {
            return try await M3UPlaylist.parse(chunks: response.body, batchSize: batchSize, onBatch: onBatch)
        } catch {
            throw ErrorClassifier.sourceError(from: error)
        }
    }
}

extension M3USourceLoader {
    /// Streams a local playlist file in 64 KiB chunks.
    private func loadFile(_ url: URL, batchSize: Int, onBatch: ([M3UEntry]) async throws -> Void) async throws -> M3UParseSummary {
        let handle: FileHandle
        do { handle = try FileHandle(forReadingFrom: url) } catch { throw SourceError.notFound }
        defer { try? handle.close() }
        var driver = M3UStreamParser(batchSize: batchSize)
        var ready: [[M3UEntry]] = []
        while true {
            if Task.isCancelled { throw SourceError.cancelled }
            let chunk = handle.readData(ofLength: 64 * 1024)
            if chunk.isEmpty { break }
            driver.consume(chunk) { ready.append($0) }
            for batch in ready { try await onBatch(batch) }
            ready.removeAll(keepingCapacity: true)
        }
        let summary = try driver.finish { ready.append($0) }
        for batch in ready { try await onBatch(batch) }
        return summary
    }
}

/// Downloads an XMLTV guide (plain or gzip, detected by magic bytes and inflated on the fly
/// into a temporary file) and parses it with `XMLTVParser`.
public struct XMLTVLoader: Sendable {
    private let transport: any HTTPTransport
    private let retryPolicy: RetryPolicy
    private let sleeper: Sleeper
    private let userAgent: String?

    public init(transport: any HTTPTransport = URLSessionTransport.shared, retryPolicy: RetryPolicy = .sourceDefault,
                sleeper: Sleeper = .live, userAgent: String? = nil) {
        self.transport = transport
        self.retryPolicy = retryPolicy
        self.sleeper = sleeper
        self.userAgent = userAgent
    }

    /// Loads and parses the guide at `url`. Throws `SourceError` (`.invalidFormat` when the
    /// body is not XMLTV).
    @discardableResult
    public func load(url: URL, options: XMLTVParseOptions = XMLTVParseOptions(),
                     onChannel: @escaping (XMLTVChannel) -> Void,
                     onProgrammes: @escaping ([XMLTVProgramme]) throws -> Void) async throws -> XMLTVSummary {
        if url.isFileURL {
            return try XMLTVParser.parse(fileURL: url, options: options, onChannel: onChannel, onProgrammes: onProgrammes)
        }
        let file = try await download(url)
        defer { try? FileManager.default.removeItem(at: file) }
        do {
            return try XMLTVParser.parse(fileURL: file, options: options, onChannel: onChannel, onProgrammes: onProgrammes)
        } catch {
            throw ErrorClassifier.sourceError(from: error)
        }
    }

    /// Downloads to a temporary plain-XML file (gzip inflated while streaming).
    func download(_ url: URL) async throws -> URL {
        let request = HTTPRequest(url: url, headers: userAgent.map { ["User-Agent": $0] } ?? [:], timeouts: .playlist)
        let transport = self.transport
        let response = try await retryPolicy.run(sleeper: sleeper) { () -> HTTPStreamResponse in
            let response = try await transport.stream(request)
            if let error = ErrorClassifier.sourceError(httpStatus: response.statusCode) { throw error }
            return response
        }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("epg-\(UUID().uuidString).xml")
        FileManager.default.createFile(atPath: file.path, contents: nil)
        do {
            let handle = try FileHandle(forWritingTo: file)
            defer { try? handle.close() }
            var inflater: GzipInflater?
            var sniffed = false
            var head = Data()
            for try await chunk in response.body {
                if Task.isCancelled { throw SourceError.cancelled }
                if !sniffed {
                    head.append(chunk)
                    guard head.count >= 2 else { continue }
                    sniffed = true
                    if Gzip.isGzip(head) { inflater = try GzipInflater() }
                    try write(head, inflater: inflater, to: handle)
                    head = Data()
                    continue
                }
                try write(chunk, inflater: inflater, to: handle)
            }
            if !sniffed, !head.isEmpty { handle.write(head) }
            try inflater?.finish()
        } catch {
            try? FileManager.default.removeItem(at: file)
            if error is GzipError { throw SourceError.invalidFormat }
            throw ErrorClassifier.sourceError(from: error)
        }
        return file
    }

    private func write(_ data: Data, inflater: GzipInflater?, to handle: FileHandle) throws {
        if let inflater {
            try inflater.process(data) { handle.write($0) }
        } else {
            handle.write(data)
        }
    }
}
