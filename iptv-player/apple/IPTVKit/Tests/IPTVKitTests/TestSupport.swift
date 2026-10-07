import CryptoKit
import Foundation
import IPTVCore
@testable import IPTVKit

/// Path of the shared test vectors (`iptv-player/spec/test-vectors`).
func vectorURL(_ relative: String, file: StaticString = #filePath) -> URL {
    URL(fileURLWithPath: "\(file)")
        .deletingLastPathComponent()   // IPTVKitTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // IPTVKit
        .deletingLastPathComponent()   // apple
        .deletingLastPathComponent()   // iptv-player
        .appendingPathComponent("spec/test-vectors/\(relative)")
}

/// Transport answering from a closure (records requests).
final class FakeTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var _requests: [HTTPRequest] = []
    let handler: @Sendable (HTTPRequest) throws -> HTTPResponse

    init(_ handler: @escaping @Sendable (HTTPRequest) throws -> HTTPResponse) {
        self.handler = handler
    }

    var requests: [HTTPRequest] {
        lock.lock(); defer { lock.unlock() }
        return _requests
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        lock.withLock { _requests.append(request) }
        return try handler(request)
    }
}

/// Signs license tokens like the backend (ES256, raw r‖s).
struct TestSigner {
    let key = P256.Signing.PrivateKey()
    let kid = "unit-1"

    var jwkSetJSON: Data {
        let raw = key.publicKey.rawRepresentation
        let set = [kid: ECPublicJWK(x: Base64URL.encode(raw.prefix(32)), y: Base64URL.encode(raw.suffix(32)))]
        return try! JSONEncoder().encode(set)
    }

    func token(aud: String = "de.hasielektronik.novaplayer", sub: String = "dev", iat: Int64, exp: Int64, lic: LicenseInfo) -> String {
        let header = Base64URL.encode(Data(#"{"alg":"ES256","kid":"\#(kid)","typ":"JWT"}"#.utf8))
        let claims = LicenseClaims(iss: ProtocolConstants.licenseIssuer, aud: aud, sub: sub, iat: iat, exp: exp, lic: lic)
        let payload = Base64URL.encode(try! JSONEncoder().encode(claims))
        let signature = try! key.signature(for: Data("\(header).\(payload)".utf8))
        return "\(header).\(payload).\(Base64URL.encode(signature.rawRepresentation))"
    }
}

/// Mutable test clock.
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var reading: ClockReading
    init(wallMs: Int64, monoMs: Int64 = 1_000, bootId: String = "boot-A") {
        reading = ClockReading(wallMs: wallMs, monoMs: monoMs, bootId: bootId)
    }
    func read() -> ClockReading {
        lock.lock(); defer { lock.unlock() }
        return reading
    }
    func advance(ms: Int64) {
        lock.lock(); defer { lock.unlock() }
        reading.wallMs += ms
        reading.monoMs += ms
    }
    func set(_ r: ClockReading) {
        lock.lock(); defer { lock.unlock() }
        reading = r
    }
}

/// Small model builders for tests.
enum TestData {
    static func channel(id: String, url: String? = nil, sourceId: String = "s1", name: String? = nil,
                        categoryId: String? = nil, epgId: String? = nil, sort: Int = 0) -> Channel {
        Channel(sourceId: sourceId, id: id, name: name ?? "Channel \(id)", categoryId: categoryId, epgId: epgId,
                url: url, sort: sort)
    }
}

/// Live search index rows (shared v7 table + per-source tables), optionally of one source / item.
func searchIndexCount(_ database: AppDatabase, sourceId: String? = nil, itemId: String? = nil) throws -> Int {
    try SearchIndex.targets(database.db, sourceId: sourceId).reduce(0) { sum, t in
        var sql = "SELECT COUNT(*) FROM \(t.table) WHERE 1 = 1" + t.filter
        var args = t.args
        if let itemId { sql += " AND item_id = ?"; args.append(.text(itemId)) }
        return sum + (try database.db.scalar(sql, args))
    }
}
