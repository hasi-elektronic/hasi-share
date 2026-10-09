import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// SHA-256 helpers (lowercase hex output, UTF-8 input).
public enum Hashing {
    /// Lowercase hex SHA-256 of the UTF-8 bytes of `string`.
    public static func sha256Hex(_ string: String) -> String {
        sha256Hex(Data(string.utf8))
    }

    /// Lowercase hex SHA-256 of `data`.
    public static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).hexString
    }
}

extension Sequence where Element == UInt8 {
    /// Lowercase hex representation of the bytes.
    public var hexString: String {
        let digits: [UInt8] = Array("0123456789abcdef".utf8)
        var out: [UInt8] = []
        out.reserveCapacity(underestimatedCount * 2)
        for byte in self {
            out.append(digits[Int(byte >> 4)])
            out.append(digits[Int(byte & 0x0F)])
        }
        return String(decoding: out, as: UTF8.self)
    }
}

extension Data {
    /// Decodes a hex string (case-insensitive). Returns nil for odd length or non-hex characters.
    public init?(hexString: String) {
        let chars = Array(hexString.utf8)
        guard chars.count % 2 == 0 else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(chars.count / 2)
        var index = 0
        while index < chars.count {
            guard let hi = Data.hexValue(chars[index]), let lo = Data.hexValue(chars[index + 1]) else { return nil }
            bytes.append(hi << 4 | lo)
            index += 2
        }
        self.init(bytes)
    }

    private static func hexValue(_ c: UInt8) -> UInt8? {
        switch c {
        case 0x30...0x39: return c - 0x30
        case 0x61...0x66: return c - 0x61 + 10
        case 0x41...0x46: return c - 0x41 + 10
        default: return nil
        }
    }
}

/// Base64url without padding (RFC 4648 §5), as used by JWS and JWK.
public enum Base64URL {
    /// Encodes `data` as unpadded base64url.
    public static func encode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Decodes base64url (padding optional). Also accepts standard base64 characters.
    public static func decode(_ string: String) -> Data? {
        var s = string.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        s = s.replacingOccurrences(of: "=", with: "")
        let remainder = s.utf8.count % 4
        if remainder == 1 { return nil }
        if remainder > 0 { s += String(repeating: "=", count: 4 - remainder) }
        return Data(base64Encoded: s)
    }
}
