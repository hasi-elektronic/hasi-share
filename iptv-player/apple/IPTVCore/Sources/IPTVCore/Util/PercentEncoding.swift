import Foundation

/// RFC 3986 percent-encoding used for every URL component the apps build (CONTRACT §4.5).
///
/// Every UTF-8 byte except the unreserved set `A–Z a–z 0–9 - . _ ~` is encoded as `%XX`
/// (uppercase hex). Space becomes `%20`, never `+`. Do not use `.urlPathAllowed` – it keeps
/// characters like `@` and `/` that must be encoded inside credentials.
public enum PercentEncoding {
    private static let hex: [UInt8] = Array("0123456789ABCDEF".utf8)

    /// True for RFC 3986 unreserved ASCII bytes.
    @inline(__always)
    public static func isUnreserved(_ byte: UInt8) -> Bool {
        switch byte {
        case 0x41...0x5A, 0x61...0x7A, 0x30...0x39, 0x2D, 0x2E, 0x5F, 0x7E: return true
        default: return false
        }
    }

    /// Percent-encodes `string` (path segments and query values alike).
    public static func encode(_ string: String) -> String {
        var out: [UInt8] = []
        out.reserveCapacity(string.utf8.count)
        for byte in string.utf8 {
            if isUnreserved(byte) {
                out.append(byte)
            } else {
                out.append(0x25)
                out.append(hex[Int(byte >> 4)])
                out.append(hex[Int(byte & 0x0F)])
            }
        }
        return String(decoding: out, as: UTF8.self)
    }

    /// Builds `k1=v1&k2=v2` with both keys and values encoded.
    public static func query(_ items: [(String, String)]) -> String {
        items.map { "\(encode($0.0))=\(encode($0.1))" }.joined(separator: "&")
    }
}
