import CryptoKit
import Foundation
import IPTVCore
import XCTest
@testable import IPTVKit

final class FakeSyncBackend: SyncBackend, @unchecked Sendable {
    private let lock = NSLock()
    var pushed: [[SyncItem]] = []
    var pages: [SyncPage] = []
    var pulls: [Int64] = []

    func syncPull(since cursor: Int64, limit: Int, sessionToken: String) async throws -> SyncPage {
        lock.withLock {
            pulls.append(cursor)
            return pages.isEmpty ? SyncPage(items: [], cursor: cursor, hasMore: false) : pages.removeFirst()
        }
    }

    func syncPush(_ items: [SyncItem], sessionToken: String) async throws -> SyncPushResult {
        lock.withLock {
            pushed.append(items)
            return SyncPushResult(applied: items.count, cursor: Int64(pushed.count))
        }
    }
}

final class SyncManagerTests: XCTestCase {
    func testPushesInBatchesOf500() async throws {
        let db = try AppDatabase.inMemory()
        let library = LibraryRepository(database: db)
        for i in 0..<1_200 {
            try library.setFavorite(true, contentKey: "fp:live:\(i)", title: "C\(i)", kind: .live, posterUrl: nil, nowMs: Int64(1_000 + i))
        }
        let backend = FakeSyncBackend()
        let sync = SyncManager(backend: backend, library: library, database: db, sessionToken: { "tok" })
        try await sync.push()
        XCTAssertEqual(backend.pushed.map(\.count), [500, 500, 200])
        let lastPush = await sync.lastPushMs
        XCTAssertEqual(lastPush, 2_199)
        // Nothing new → no call.
        try await sync.push()
        XCTAssertEqual(backend.pushed.count, 3)
        // Only items changed after the last push are sent.
        try library.setFavorite(false, contentKey: "fp:live:7", title: "C7", kind: .live, posterUrl: nil, nowMs: 5_000)
        try await sync.push()
        XCTAssertEqual(backend.pushed.last?.map(\.key), ["fav:fp:live:7"])
    }

    func testDebounceCoalescesChanges() async throws {
        let db = try AppDatabase.inMemory()
        let library = LibraryRepository(database: db)
        let backend = FakeSyncBackend()
        let sync = SyncManager(backend: backend, library: library, database: db, debounce: .milliseconds(80), sessionToken: { "tok" })
        for i in 0..<5 {
            try library.setFavorite(true, contentKey: "fp:movie:\(i)", title: "M", kind: .movie, posterUrl: nil, nowMs: Int64(10 + i))
            await sync.noteLocalChange()
        }
        await sync.waitForScheduledPush()
        XCTAssertEqual(backend.pushed.count, 1)
        XCTAssertEqual(backend.pushed.first?.count, 5)
    }

    func testNoSessionNoNetwork() async throws {
        let db = try AppDatabase.inMemory()
        let library = LibraryRepository(database: db)
        try library.setFavorite(true, contentKey: "fp:live:1", title: "C", kind: .live, posterUrl: nil, nowMs: 1)
        let backend = FakeSyncBackend()
        let sync = SyncManager(backend: backend, library: library, database: db, sessionToken: { nil })
        await sync.syncNow()
        XCTAssertTrue(backend.pushed.isEmpty)
        XCTAssertTrue(backend.pulls.isEmpty)
    }

    func testPullFollowsCursorAndMergesLWW() async throws {
        let db = try AppDatabase.inMemory()
        let library = LibraryRepository(database: db)
        try library.setFavorite(true, contentKey: "fp:live:1", title: "Local", kind: .live, posterUrl: nil, nowMs: 500)
        let backend = FakeSyncBackend()
        backend.pages = [
            SyncPage(items: [SyncItem.favorite(contentKey: "fp:live:1", title: "Old remote", contentKind: .live, posterUrl: nil, updatedAt: 100, deleted: true)],
                     cursor: 10, hasMore: true),
            SyncPage(items: [SyncItem.progress(contentKey: "fp:movie:2", title: "M", contentKind: .movie, positionMs: 10, durationMs: 100, updatedAt: 900)],
                     cursor: 20, hasMore: false),
        ]
        let sync = SyncManager(backend: backend, library: library, database: db, sessionToken: { "tok" })
        let applied = try await sync.pull()
        XCTAssertEqual(applied, 1)
        XCTAssertEqual(backend.pulls, [0, 10])
        let cursor = await sync.cursor
        XCTAssertEqual(cursor, 20)
        XCTAssertTrue(try library.isFavorite(contentKey: "fp:live:1"))
        XCTAssertNotNil(try library.progress(contentKey: "fp:movie:2"))
    }
}

final class FakePairingBackend: PairingBackend, @unchecked Sendable {
    private let lock = NSLock()
    var publicKey: ECPublicJWK?
    var polls = 0
    let payload: PairPayload

    init(payload: PairPayload) { self.payload = payload }

    func createPairSession(publicKey: ECPublicJWK) async throws -> PairSession {
        lock.withLock { self.publicKey = publicKey }
        return PairSession(code: "ABC234", secret: "s", expiresAt: Int64((Date().timeIntervalSince1970 + 600) * 1000),
                           pairUrl: "https://b.example.com/pair?c=ABC234")
    }

    func pollPairSession(code: String, secret: String) async throws -> PairPollResult {
        let (count, key) = lock.withLock { () -> (Int, ECPublicJWK?) in
            polls += 1
            return (polls, publicKey)
        }
        if count < 2 { return .pending }
        // Phone side: encrypt to the TV's public key.
        let envelope = try PairCrypto.encrypt(try JSONEncoder().encode(payload), to: key!)
        return .ready(envelope)
    }
}

@MainActor
final class PairingManagerTests: XCTestCase {
    func testReceivesAndDecryptsPayload() async throws {
        let payload = PairPayload.xtream(name: "Panel", server: "http://p.example.com", username: "u", password: "p w")
        let backend = FakePairingBackend(payload: payload)
        let manager = PairingManager(backend: backend, pollInterval: .milliseconds(10))
        manager.start()
        for _ in 0..<200 {
            if case .received = manager.state { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(manager.state, .received(payload))
        XCTAssertEqual(backend.polls, 2)
    }

    func testShowsCodeWhileWaiting() async throws {
        let backend = FakePairingBackend(payload: .m3u(name: "x", url: "http://a", epgUrl: nil))
        let manager = PairingManager(backend: backend, pollInterval: .seconds(30))
        manager.start()
        for _ in 0..<100 {
            if manager.displayCode != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(manager.displayCode, "ABC-234")
        manager.cancel()
        XCTAssertEqual(manager.state, .idle)
    }
}
