import Foundation
import XCTest

/// Access to the shared cross-platform vectors (`spec/test-vectors`), resolved relative to
/// this file's directory: Tests/IPTVCoreTests → ../../../../spec/test-vectors.
enum Vectors {
    static let dir: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("../../../../spec/test-vectors", isDirectory: true)
        .standardizedFileURL

    static func url(_ path: String) -> URL { dir.appendingPathComponent(path) }

    static func data(_ path: String) throws -> Data {
        try Data(contentsOf: url(path))
    }

    static func text(_ path: String) throws -> String {
        String(decoding: try data(path), as: UTF8.self)
    }

    /// Parsed JSON (`[String: Any]`, `[Any]`, `String`, `NSNumber`, `NSNull`).
    static func json(_ path: String) throws -> Any {
        try JSONSerialization.jsonObject(with: try data(path), options: [.fragmentsAllowed])
    }

    static func object(_ path: String) throws -> [String: Any] {
        guard let o = try json(path) as? [String: Any] else { throw VectorError.shape(path) }
        return o
    }

    static func array(_ path: String) throws -> [[String: Any]] {
        guard let a = try json(path) as? [[String: Any]] else { throw VectorError.shape(path) }
        return a
    }

    /// File names (not paths) in a vector sub-directory.
    static func files(in sub: String) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: url(sub).path).sorted()
    }
}

enum VectorError: Error { case shape(String) }

// MARK: - JSON helpers

/// Typed accessors for JSONSerialization trees.
extension Dictionary where Key == String, Value == Any {
    func str(_ key: String) -> String? { self[key] as? String }
    func num(_ key: String) -> NSNumber? { self[key] as? NSNumber }
    func int64(_ key: String) -> Int64? { num(key)?.int64Value }
    func obj(_ key: String) -> [String: Any]? { self[key] as? [String: Any] }
    func arr(_ key: String) -> [[String: Any]]? { self[key] as? [[String: Any]] }
    func isNull(_ key: String) -> Bool { self[key] == nil || self[key] is NSNull }
}

/// Swift optional → JSON-ish value for comparisons (`nil` → `NSNull`).
func j(_ value: Any?) -> Any { value ?? NSNull() }

/// Structural JSON comparison mirroring the Kotlin `assertJsonEquals`: numbers compare
/// numerically (7200 == 7200.0), objects must have the same keys (keys starting with `_` in
/// the expected value are documentation and ignored), arrays in order.
func assertJSONEqual(_ expected: Any, _ actual: Any, _ path: String = "$",
                     file: StaticString = #filePath, line: UInt = #line) {
    switch expected {
    case is NSNull:
        if !(actual is NSNull) { XCTFail("\(path): expected null, got \(actual)", file: file, line: line) }
    case let e as String:
        guard let a = actual as? String else {
            return XCTFail("\(path): expected string \"\(e)\", got \(actual)", file: file, line: line)
        }
        XCTAssertEqual(e, a, path, file: file, line: line)
    case let e as NSNumber:
        if isBoolean(e) {
            guard let a = actual as? Bool else {
                return XCTFail("\(path): expected bool \(e.boolValue), got \(actual)", file: file, line: line)
            }
            XCTAssertEqual(e.boolValue, a, path, file: file, line: line)
        } else {
            let a: Double
            switch actual {
            case let v as Int: a = Double(v)
            case let v as Int64: a = Double(v)
            case let v as Double: a = v
            case let v as NSNumber where !isBoolean(v): a = v.doubleValue
            default: return XCTFail("\(path): expected number \(e), got \(actual)", file: file, line: line)
            }
            XCTAssertEqual(e.doubleValue, a, accuracy: 1e-9, path, file: file, line: line)
        }
    case let e as [Any]:
        guard let a = actual as? [Any] else {
            return XCTFail("\(path): expected array, got \(actual)", file: file, line: line)
        }
        guard e.count == a.count else {
            return XCTFail("\(path): array size \(e.count) != \(a.count) (actual=\(a))", file: file, line: line)
        }
        for (i, item) in e.enumerated() { assertJSONEqual(item, a[i], "\(path)[\(i)]", file: file, line: line) }
    case let e as [String: Any]:
        guard let a = actual as? [String: Any] else {
            return XCTFail("\(path): expected object, got \(actual)", file: file, line: line)
        }
        let eKeys = Set(e.keys.filter { !$0.hasPrefix("_") })
        let aKeys = Set(a.keys.filter { !$0.hasPrefix("_") })
        XCTAssertEqual(eKeys, aKeys, "\(path): keys", file: file, line: line)
        for key in eKeys.sorted() {
            guard let av = a[key] else { continue }
            assertJSONEqual(e[key]!, av, "\(path).\(key)", file: file, line: line)
        }
    default:
        XCTFail("\(path): unsupported expected value \(expected)", file: file, line: line)
    }
}

/// True for JSON booleans parsed by JSONSerialization (works on Darwin and Linux).
func isBoolean(_ n: NSNumber) -> Bool {
    String(cString: n.objCType) == "c"
}

/// Epoch seconds of a date (exact for whole seconds).
func epoch(_ date: Date?) -> Any {
    guard let date else { return NSNull() }
    return Int64(date.timeIntervalSince1970.rounded())
}
