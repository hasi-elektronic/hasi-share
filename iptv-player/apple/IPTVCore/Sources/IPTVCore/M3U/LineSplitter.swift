import Foundation

/// Splits a byte stream arriving in arbitrary chunks into `\n`-terminated lines
/// (a trailing `\r` is left for the consumer to trim). Only the current partial line is
/// buffered; overlong lines are truncated at `maxLineLength` bytes.
struct LineSplitter: Sendable {
    private var carry: [UInt8] = []
    private let maxLineLength: Int

    init(maxLineLength: Int = 1 << 20) {
        self.maxLineLength = maxLineLength
    }

    /// Calls `body` for every complete line contained in `chunk` (plus the buffered prefix).
    mutating func consume(_ chunk: UnsafeRawBufferPointer, _ body: (UnsafeBufferPointer<UInt8>) throws -> Void) rethrows {
        let bytes = chunk.bindMemory(to: UInt8.self)
        var lineStart = 0
        var i = 0
        let n = bytes.count
        while i < n {
            if bytes[i] == 0x0A {
                if carry.isEmpty {
                    try body(UnsafeBufferPointer(rebasing: bytes[lineStart..<i]))
                } else {
                    append(UnsafeBufferPointer(rebasing: bytes[lineStart..<i]))
                    try carry.withUnsafeBufferPointer { try body($0) }
                    carry.removeAll(keepingCapacity: true)
                }
                lineStart = i + 1
            }
            i += 1
        }
        if lineStart < n {
            append(UnsafeBufferPointer(rebasing: bytes[lineStart..<n]))
        }
    }

    mutating func consume(_ data: Data, _ body: (UnsafeBufferPointer<UInt8>) throws -> Void) rethrows {
        try data.withUnsafeBytes { try consume($0, body) }
    }

    /// Emits the final unterminated line, if any.
    mutating func finish(_ body: (UnsafeBufferPointer<UInt8>) throws -> Void) rethrows {
        if !carry.isEmpty {
            try carry.withUnsafeBufferPointer { try body($0) }
            carry.removeAll()
        }
    }

    private mutating func append(_ bytes: UnsafeBufferPointer<UInt8>) {
        let room = maxLineLength - carry.count
        guard room > 0 else { return }
        if bytes.count <= room {
            carry.append(contentsOf: bytes)
        } else {
            carry.append(contentsOf: UnsafeBufferPointer(rebasing: bytes[0..<room]))
        }
    }
}
