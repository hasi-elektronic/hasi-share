import Foundation

/// A lenient JSON tree used to decode inconsistent panel responses (CONTRACT §4.3).
public enum JSONValue: Sendable, Hashable, Codable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let b = try? c.decode(Bool.self) { self = .bool(b); return }
        if let i = try? c.decode(Int64.self) { self = .int(i); return }
        if let d = try? c.decode(Double.self) { self = .double(d); return }
        if let s = try? c.decode(String.self) { self = .string(s); return }
        if let a = try? c.decode([JSONValue].self) { self = .array(a); return }
        if let o = try? c.decode([String: JSONValue].self) { self = .object(o); return }
        throw DecodingError.dataCorruptedError(in: c, debugDescription: "Unsupported JSON value")
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .int(let i): try c.encode(i)
        case .double(let d): try c.encode(d)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }

    /// Parses any JSON document (fast byte-level parser); nil if `data` is not valid JSON.
    /// A UTF-8 BOM and surrounding whitespace are tolerated.
    public static func parse(_ data: Data) -> JSONValue? {
        data.withUnsafeBytes { raw -> JSONValue? in
            var reader = JSONByteParser(raw.bindMemory(to: UInt8.self))
            return reader.parseDocument()
        }
    }

    // MARK: Lenient accessors

    /// Member of an object (nil for other types, including `[]` standing for `{}`).
    public subscript(key: String) -> JSONValue? {
        if case .object(let o) = self { return o[key] }
        return nil
    }

    public var objectValue: [String: JSONValue]? {
        switch self {
        case .object(let o): return o
        case .array(let a) where a.isEmpty: return [:]   // empty objects may arrive as []
        default: return nil
        }
    }

    public var arrayValue: [JSONValue]? {
        if case .array(let a) = self { return a }
        return nil
    }

    /// Non-empty string; numbers are rendered as decimal strings. `""`/null → nil.
    public var stringValue: String? {
        switch self {
        case .string(let s): return s.isEmpty ? nil : s
        case .int(let i): return String(i)
        case .double(let d):
            if d.rounded() == d, abs(d) < 1e15 { return String(Int64(d)) }
            return String(d)
        case .bool(let b): return b ? "1" : "0"
        default: return nil
        }
    }

    /// Number, numeric string, `""` or null → Int?.
    public var intValue: Int? {
        switch self {
        case .int(let i): return Int(exactly: i)
        case .double(let d): return d.isFinite ? Int(d) : nil
        case .string(let s):
            let t = s.trimmingCharacters(in: .whitespaces)
            if let i = Int(t) { return i }
            if let d = Double(t), d.isFinite { return Int(d) }
            return nil
        case .bool(let b): return b ? 1 : 0
        default: return nil
        }
    }

    /// Number, numeric string, `""` or null → Int64?.
    public var int64Value: Int64? {
        switch self {
        case .int(let i): return i
        case .double(let d): return d.isFinite ? Int64(d) : nil
        case .string(let s):
            let t = s.trimmingCharacters(in: .whitespaces)
            if let i = Int64(t) { return i }
            if let d = Double(t), d.isFinite { return Int64(d) }
            return nil
        default: return nil
        }
    }

    /// Number, numeric string, `""` or null → Double?.
    public var doubleValue: Double? {
        switch self {
        case .int(let i): return Double(i)
        case .double(let d): return d.isFinite ? d : nil
        case .string(let s): return Double(s.trimmingCharacters(in: .whitespaces)).flatMap { $0.isFinite ? $0 : nil }
        default: return nil
        }
    }

    /// `1`, `"1"`, `true` → true; anything else false.
    public var boolValue: Bool {
        switch self {
        case .bool(let b): return b
        case .int(let i): return i == 1
        case .double(let d): return d == 1
        case .string(let s): return s.trimmingCharacters(in: .whitespaces) == "1" || s.lowercased() == "true"
        default: return false
        }
    }
}

/// Minimal RFC 8259 parser producing `JSONValue` without intermediate Foundation objects.
struct JSONByteParser {
    private let b: UnsafeBufferPointer<UInt8>
    private var i = 0
    private var depth = 0

    init(_ bytes: UnsafeBufferPointer<UInt8>) { b = bytes }

    mutating func parseDocument() -> JSONValue? {
        if b.count >= 3, b[0] == 0xEF, b[1] == 0xBB, b[2] == 0xBF { i = 3 }
        skipSpace()
        guard let value = parseValue() else { return nil }
        skipSpace()
        return i == b.count ? value : nil
    }

    private mutating func skipSpace() {
        while i < b.count, b[i] == 0x20 || b[i] == 0x0A || b[i] == 0x0D || b[i] == 0x09 { i += 1 }
    }

    private mutating func parseValue() -> JSONValue? {
        guard i < b.count else { return nil }
        switch b[i] {
        case 0x7B: return parseObject()
        case 0x5B: return parseArray()
        case 0x22: return parseString().map(JSONValue.string)
        case 0x74: return literal("true", .bool(true))
        case 0x66: return literal("false", .bool(false))
        case 0x6E: return literal("null", .null)
        case 0x2D, 0x30...0x39: return parseNumber()
        default: return nil
        }
    }

    private mutating func literal(_ word: StaticString, _ value: JSONValue) -> JSONValue? {
        let count = word.utf8CodeUnitCount
        guard i + count <= b.count else { return nil }
        let w = word.utf8Start
        for k in 0..<count where b[i + k] != w[k] { return nil }
        i += count
        return value
    }

    private mutating func parseObject() -> JSONValue? {
        depth += 1
        defer { depth -= 1 }
        guard depth < 512 else { return nil }
        i += 1
        var object: [String: JSONValue] = [:]
        skipSpace()
        if i < b.count, b[i] == 0x7D { i += 1; return .object(object) }
        while true {
            skipSpace()
            guard i < b.count, b[i] == 0x22, let key = parseString() else { return nil }
            skipSpace()
            guard i < b.count, b[i] == 0x3A else { return nil }
            i += 1
            skipSpace()
            guard let value = parseValue() else { return nil }
            object[key] = value
            skipSpace()
            guard i < b.count else { return nil }
            if b[i] == 0x2C { i += 1; continue }
            if b[i] == 0x7D { i += 1; return .object(object) }
            return nil
        }
    }

    private mutating func parseArray() -> JSONValue? {
        depth += 1
        defer { depth -= 1 }
        guard depth < 512 else { return nil }
        i += 1
        var array: [JSONValue] = []
        skipSpace()
        if i < b.count, b[i] == 0x5D { i += 1; return .array(array) }
        while true {
            skipSpace()
            guard let value = parseValue() else { return nil }
            array.append(value)
            skipSpace()
            guard i < b.count else { return nil }
            if b[i] == 0x2C { i += 1; continue }
            if b[i] == 0x5D { i += 1; return .array(array) }
            return nil
        }
    }

    private mutating func parseNumber() -> JSONValue? {
        let start = i
        var isInteger = true
        if b[i] == 0x2D { i += 1 }
        while i < b.count {
            let c = b[i]
            if c >= 0x30 && c <= 0x39 { i += 1; continue }
            if c == 0x2E || c == 0x65 || c == 0x45 || c == 0x2B || c == 0x2D { isInteger = false; i += 1; continue }
            break
        }
        let text = String(decoding: UnsafeBufferPointer(rebasing: b[start..<i]), as: UTF8.self)
        if isInteger, let value = Int64(text) { return .int(value) }
        return Double(text).map(JSONValue.double)
    }

    private mutating func parseString() -> String? {
        i += 1   // opening quote
        let start = i
        while i < b.count, b[i] != 0x22, b[i] != 0x5C { i += 1 }
        guard i < b.count else { return nil }
        if b[i] == 0x22 {
            let s = String(decoding: UnsafeBufferPointer(rebasing: b[start..<i]), as: UTF8.self)
            i += 1
            return s
        }
        var out = Array(b[start..<i])
        while i < b.count {
            let c = b[i]
            if c == 0x22 { i += 1; return String(decoding: out, as: UTF8.self) }
            if c != 0x5C { out.append(c); i += 1; continue }
            i += 1
            guard i < b.count else { return nil }
            let e = b[i]
            i += 1
            switch e {
            case 0x22: out.append(0x22)
            case 0x5C: out.append(0x5C)
            case 0x2F: out.append(0x2F)
            case 0x62: out.append(0x08)
            case 0x66: out.append(0x0C)
            case 0x6E: out.append(0x0A)
            case 0x72: out.append(0x0D)
            case 0x74: out.append(0x09)
            case 0x75:
                guard var scalar = readHex4() else { return nil }
                if (0xD800...0xDBFF).contains(scalar), i + 1 < b.count, b[i] == 0x5C, b[i + 1] == 0x75 {
                    i += 2
                    guard let low = readHex4() else { return nil }
                    if (0xDC00...0xDFFF).contains(low) {
                        scalar = 0x10000 + ((scalar - 0xD800) << 10) + (low - 0xDC00)
                    } else {
                        appendScalar(0xFFFD, to: &out)
                        scalar = low
                    }
                }
                appendScalar(scalar, to: &out)
            default: return nil
            }
        }
        return nil
    }

    private mutating func readHex4() -> UInt32? {
        guard i + 4 <= b.count else { return nil }
        var value: UInt32 = 0
        for _ in 0..<4 {
            let c = b[i]
            let digit: UInt32
            switch c {
            case 0x30...0x39: digit = UInt32(c - 0x30)
            case 0x61...0x66: digit = UInt32(c - 0x61 + 10)
            case 0x41...0x46: digit = UInt32(c - 0x41 + 10)
            default: return nil
            }
            value = value << 4 | digit
            i += 1
        }
        return value
    }

    private func appendScalar(_ value: UInt32, to out: inout [UInt8]) {
        let scalar = Unicode.Scalar(value) ?? Unicode.Scalar(0xFFFD)!
        out.append(contentsOf: Array(String(Character(scalar)).utf8))
    }
}
