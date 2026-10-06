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
        f.toggleCategory(sourceId: "s1", categoryId: "k1"); XCTAssertEqual(f.favoriteCategoryIds, ["s1|k1"])
        XCTAssertEqual(try make(kv: kv).favoriteCategoryIds, ["s1|k1"])   // persisted per device
        f.toggleCategory(sourceId: "s1", categoryId: "k1"); XCTAssertTrue(f.favoriteCategoryIds.isEmpty)
    }

    // (e) Category ids are source-scoped: the same provider category id in two sources is independent.
    func testFavoriteCategoriesAreSourceScoped() throws {
        let f = try make()
        f.toggleCategory(sourceId: "s1", categoryId: "k1")
        XCTAssertTrue(f.isFavoriteCategory(sourceId: "s1", categoryId: "k1"))
        XCTAssertFalse(f.isFavoriteCategory(sourceId: "s2", categoryId: "k1"))
        f.toggleCategory(sourceId: "s2", categoryId: "k1")
        f.toggleCategory(sourceId: "s1", categoryId: "k1")
        XCTAssertFalse(f.isFavoriteCategory(sourceId: "s1", categoryId: "k1"))
        XCTAssertTrue(f.isFavoriteCategory(sourceId: "s2", categoryId: "k1"))
        XCTAssertEqual(f.favoriteCategoryIds(sourceId: "s2"), ["k1"])
        XCTAssertTrue(f.favoriteCategoryIds(sourceId: "s1").isEmpty)
    }

    // (a) A failed database write must not leave the cached state flipped.
    func testFailedWriteRevertsCacheAndSetsNoUndo() throws {
        let database = try AppDatabase.inMemory()
        let lib = LibraryRepository(database: database)
        var changes = 0
        let f = try make(library: lib, onChange: { changes += 1 })
        try database.db.run("DROP TABLE library")
        XCTAssertFalse(f.toggle(a), "returns the real (unchanged) state")
        XCTAssertFalse(f.isFavorite("ch:a"))
        XCTAssertNil(f.pendingUndo)
        XCTAssertEqual(changes, 0, "no sync push for a change that did not happen")
    }

    // (b) Undo restores the state before the toggle, even if a sync changed it in between.
    func testUndoRestoresPriorStateInsteadOfFlipping() throws {
        let lib = try LibraryRepository(database: AppDatabase.inMemory())
        let f = try make(library: lib)
        f.toggle(a)                                                    // off -> on
        try lib.setFavorite(false, contentKey: "ch:a", title: "A", kind: .live, posterUrl: nil, nowMs: 50_000)  // remote removal
        f.reload()
        f.undo()                                                       // prior state was "off"
        XCTAssertFalse(f.isFavorite("ch:a"))
        XCTAssertFalse(try lib.isFavorite(contentKey: "ch:a"))
        XCTAssertNil(f.pendingUndo)
    }

    // (c) Order / category changes are device-local: UI refresh only, no sync push.
    func testMoveAndCategoryUseLocalCallbackOnly() throws {
        var changes = 0
        var local = 0
        let f = try make(onChange: { changes += 1 })
        f.onLocalChange = { local += 1 }
        f.toggle(a); f.toggle(b)
        XCTAssertEqual(changes, 2)
        f.move(kind: .live, from: IndexSet(integer: 1), to: 0)
        f.toggleCategory(sourceId: "s1", categoryId: "k1")
        XCTAssertEqual(changes, 2, "no sync push")
        XCTAssertEqual(local, 2, "UI refresh")
    }

    // (d) Un-favoriting prunes the saved order; a re-added favorite counts as new.
    func testUnfavoritePrunesSavedOrder() throws {
        let kv = InMemoryKeyValueStore()
        let f = try make(kv: kv)
        f.toggle(a); f.toggle(b)                                        // b a
        f.move(kind: .live, from: IndexSet(integer: 1), to: 0)          // a b (saved)
        f.toggle(a)                                                    // remove a
        XCTAssertEqual(kv.value([String].self, forKey: "fav.order.live"), ["ch:b"])
        f.toggle(a)                                                    // re-add: after the saved order
        XCTAssertEqual(f.orderedKeys(kind: .live), ["ch:b", "ch:a"])
    }

    /// Favorites screen shows only the current source: a move inside that subset keeps the
    /// other sources' keys in their slots.
    func testMoveWithinVisibleSubset() throws {
        let f = try make()
        let x = FavoriteTarget(contentKey: "ch:x", title: "X", kind: .live, posterUrl: nil)
        f.toggle(a); f.toggle(x); f.toggle(b)                           // b x a
        f.move(kind: .live, from: IndexSet(integer: 1), to: 0, within: ["ch:b", "ch:a"])
        XCTAssertEqual(f.orderedKeys(kind: .live), ["ch:a", "ch:x", "ch:b"])
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
