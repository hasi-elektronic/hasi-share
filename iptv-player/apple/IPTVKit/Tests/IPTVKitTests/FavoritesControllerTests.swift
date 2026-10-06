import XCTest
@testable import IPTVKit
import IPTVCore

@MainActor
final class FavoritesControllerTests: XCTestCase {
    func make(kv: InMemoryKeyValueStore = InMemoryKeyValueStore(), library: LibraryRepository? = nil,
              undoWindow: Duration = .seconds(4), onChange: @escaping @MainActor () -> Void = {}) throws -> FavoritesController {
        let lib = try library ?? LibraryRepository(database: AppDatabase.inMemory())
        var t: Int64 = 1_000
        return FavoritesController(library: lib, kv: kv, now: { t += 1; return t }, onChange: onChange, undoWindow: undoWindow)
    }
    let a = FavoriteTarget(contentKey: "ch:a", title: "A", kind: .live, posterUrl: nil)
    let b = FavoriteTarget(contentKey: "ch:b", title: "B", kind: .live, posterUrl: nil)
    let c = FavoriteTarget(contentKey: "ch:c", title: "C", kind: .live, posterUrl: nil)

    func testToggleIsImmediateAndUndoable() throws {
        let f = try make()
        XCTAssertTrue(f.toggle(a))
        XCTAssertTrue(f.isFavorite("ch:a"))
        XCTAssertEqual(f.pendingUndo, a)
        f.undo()
        XCTAssertFalse(f.isFavorite("ch:a"))
        XCTAssertNil(f.pendingUndo)
    }

    func testLocalOrderPersistsAndNewestFirstForRest() throws {
        let f = try make()
        f.toggle(a); f.toggle(b)
        XCTAssertEqual(f.orderedKeys(kind: .live), ["ch:b", "ch:a"])
        f.move(kind: .live, from: IndexSet(integer: 1), to: 0)
        XCTAssertEqual(f.orderedKeys(kind: .live), ["ch:a", "ch:b"])
        f.toggle(c)  // new favorite is not in the saved order -> after it, newest-first
        XCTAssertEqual(f.orderedKeys(kind: .live), ["ch:a", "ch:b", "ch:c"])
    }

    func testMoveDownAndUnfavoritedKeysDropOut() throws {
        let f = try make()
        f.toggle(a); f.toggle(b); f.toggle(c)           // newest first: c b a
        f.move(kind: .live, from: IndexSet(integer: 0), to: 3)   // c to the end
        XCTAssertEqual(f.orderedKeys(kind: .live), ["ch:b", "ch:a", "ch:c"])
        f.toggle(b)                                      // remove b
        XCTAssertEqual(f.orderedKeys(kind: .live), ["ch:a", "ch:c"])
    }

    func testFavoriteCategories() throws {
        let kv = InMemoryKeyValueStore()
        let f = try make(kv: kv)
        f.toggleCategory("k1"); XCTAssertEqual(f.favoriteCategoryIds, ["k1"])
        XCTAssertEqual(try make(kv: kv).favoriteCategoryIds, ["k1"])   // persisted per device
        f.toggleCategory("k1"); XCTAssertTrue(f.favoriteCategoryIds.isEmpty)
    }

    func testPersistsToLibraryAndReloads() throws {
        let lib = try LibraryRepository(database: AppDatabase.inMemory())
        var changes = 0
        let f = try make(library: lib, onChange: { changes += 1 })
        f.toggle(a)
        XCTAssertTrue(try lib.isFavorite(contentKey: "ch:a"))
        XCTAssertEqual(changes, 1)
        try lib.setFavorite(true, contentKey: "ch:z", title: "Z", kind: .live, posterUrl: nil, nowMs: 9_999)  // e.g. sync merge
        XCTAssertFalse(f.isFavorite("ch:z"))
        f.reload()
        XCTAssertTrue(f.isFavorite("ch:z"))
        XCTAssertEqual(changes, 1)
        XCTAssertTrue(try make(library: lib).isFavorite("ch:a"))   // initial load from DB
    }

    func testUndoExpiresAfterWindow() async throws {
        let f = try make(undoWindow: .milliseconds(50))
        f.toggle(a)
        XCTAssertNotNil(f.pendingUndo)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertNil(f.pendingUndo)
        XCTAssertTrue(f.isFavorite("ch:a"))
    }
}
