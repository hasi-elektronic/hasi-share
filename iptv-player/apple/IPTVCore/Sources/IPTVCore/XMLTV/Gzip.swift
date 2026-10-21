import Foundation
import CZlib

/// gzip errors.
public enum GzipError: Error, Sendable, Hashable {
    case initFailed(code: Int32)
    case corruptData(code: Int32)
    /// Input ended before the gzip stream was complete.
    case truncated
}

/// gzip support on top of the system zlib (identical code on Apple platforms and Linux).
///
/// Apple's URLSession transparently decodes `Content-Encoding: gzip`, but `.xml.gz` EPG files
/// are usually served as `application/gzip` and must be inflated by the app; detection is by
/// magic bytes (`1f 8b`) regardless of file extension (CONTRACT §5).
public enum Gzip {
    /// True if `data` starts with the gzip magic `1f 8b`.
    public static func isGzip(_ data: Data) -> Bool {
        data.count >= 2 && data[data.startIndex] == 0x1F && data[data.startIndex + 1] == 0x8B
    }

    /// Inflates a complete gzip (or zlib) buffer.
    public static func decompress(_ data: Data) throws -> Data {
        let inflater = try GzipInflater()
        var out = Data()
        try inflater.process(data) { out.append($0) }
        try inflater.finish()
        return out
    }

    /// Compresses `data` into a gzip member (used by tests and diagnostics).
    public static func compress(_ data: Data, level: Int32 = 6) throws -> Data {
        let strm = UnsafeMutablePointer<z_stream>.allocate(capacity: 1)
        strm.initialize(to: z_stream())
        defer {
            deflateEnd(strm)
            strm.deinitialize(count: 1)
            strm.deallocate()
        }
        let initCode = czlib_deflate_init2(strm, level, 15 + 16)
        guard initCode == Z_OK else { throw GzipError.initFailed(code: initCode) }
        var out = Data()
        let chunk = 64 * 1024
        let buffer = UnsafeMutablePointer<Bytef>.allocate(capacity: chunk)
        defer { buffer.deallocate() }
        try data.withUnsafeBytes { raw in
            let input = raw.bindMemory(to: Bytef.self)
            strm.pointee.next_in = UnsafeMutablePointer(mutating: input.baseAddress)
            strm.pointee.avail_in = uInt(input.count)
            while true {
                strm.pointee.next_out = buffer
                strm.pointee.avail_out = uInt(chunk)
                let code = deflate(strm, Z_FINISH)
                let produced = chunk - Int(strm.pointee.avail_out)
                if produced > 0 { out.append(buffer, count: produced) }
                if code == Z_STREAM_END { break }
                guard code == Z_OK || code == Z_BUF_ERROR else { throw GzipError.corruptData(code: code) }
            }
        }
        return out
    }

    /// Inflates `source` into `destination` in chunks (constant memory).
    public static func decompressFile(at source: URL, to destination: URL) throws {
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }
        let inflater = try GzipInflater()
        while true {
            if Task.isCancelled { throw SourceError.cancelled }
            let chunk = input.readData(ofLength: 256 * 1024)
            if chunk.isEmpty { break }
            try inflater.process(chunk) { output.write($0) }
        }
        try inflater.finish()
    }
}

/// Streaming inflater: feed compressed chunks, receive decompressed chunks.
/// Handles concatenated (multi-member) gzip streams and ignores trailing garbage after a
/// complete member. Not thread-safe; use from one task at a time.
public final class GzipInflater {
    private let strm: UnsafeMutablePointer<z_stream>
    private let buffer: UnsafeMutablePointer<Bytef>
    private let bufferSize = 64 * 1024
    private var memberEnded = false
    private var completedMembers = 0
    private var ignoreRest = false

    public init() throws {
        strm = UnsafeMutablePointer<z_stream>.allocate(capacity: 1)
        strm.initialize(to: z_stream())
        buffer = UnsafeMutablePointer<Bytef>.allocate(capacity: bufferSize)
        // 15 + 32: auto-detect gzip or zlib header.
        let code = czlib_inflate_init2(strm, 15 + 32)
        guard code == Z_OK else {
            strm.deinitialize(count: 1)
            strm.deallocate()
            buffer.deallocate()
            throw GzipError.initFailed(code: code)
        }
    }

    deinit {
        inflateEnd(strm)
        strm.deinitialize(count: 1)
        strm.deallocate()
        buffer.deallocate()
    }

    /// Inflates `chunk`, calling `output` with each produced block.
    public func process(_ chunk: Data, output: (Data) throws -> Void) throws {
        guard !chunk.isEmpty, !ignoreRest else { return }
        try chunk.withUnsafeBytes { raw in
            let input = raw.bindMemory(to: Bytef.self)
            strm.pointee.next_in = UnsafeMutablePointer(mutating: input.baseAddress)
            strm.pointee.avail_in = uInt(input.count)
            while strm.pointee.avail_in > 0 || !memberEnded {
                if memberEnded {
                    // Another gzip member follows.
                    inflateReset(strm)
                    memberEnded = false
                }
                strm.pointee.next_out = buffer
                strm.pointee.avail_out = uInt(bufferSize)
                let code = inflate(strm, Z_NO_FLUSH)
                let produced = bufferSize - Int(strm.pointee.avail_out)
                if produced > 0 { try output(Data(bytes: buffer, count: produced)) }
                switch code {
                case Z_STREAM_END:
                    memberEnded = true
                    completedMembers += 1
                case Z_OK:
                    if strm.pointee.avail_in == 0 && strm.pointee.avail_out > 0 { return }
                case Z_BUF_ERROR:
                    return   // needs more input
                default:
                    if completedMembers > 0 {
                        ignoreRest = true   // trailing garbage after a complete member
                        return
                    }
                    throw GzipError.corruptData(code: code)
                }
                if memberEnded && strm.pointee.avail_in == 0 { return }
            }
        }
    }

    /// Verifies that the stream ended cleanly.
    public func finish() throws {
        guard memberEnded || ignoreRest else { throw GzipError.truncated }
    }
}
