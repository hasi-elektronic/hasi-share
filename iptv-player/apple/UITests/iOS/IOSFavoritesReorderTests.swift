import XCTest

/// Favorites screen "Reorder" (SCREENS §3.6): drag handles (`onMove`), device-local order kept.
final class IOSFavoritesReorderTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    /// Titles of the reorder list, top to bottom.
    @MainActor
    private func titles(_ app: XCUIApplication) -> [String] {
        app.cells.allElementsBoundByIndex.compactMap { cell in
            cell.staticTexts.allElementsBoundByIndex.map(\.label).first { Int($0) == nil }
        }
    }

    @MainActor
    func testDragReorderPersists() throws {
        let app = UITestSupport.launch(["-uiScreen", "favorites", "-uiSeedLibrary"])
        let move = app.buttons["fav_move"]
        XCTAssertTrue(move.waitForExistence(timeout: 30), "Reorder in the toolbar (2 seeded favorite channels)")
        move.tap()
        XCTAssertTrue(app.cells.element(boundBy: 1).waitForExistence(timeout: 5))
        let before = titles(app)
        XCTAssertEqual(before.count, 2, "\(before)")
        UITestSupport.snap("fav-ios-05-reorder", in: self)

        let handles = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Reorder'"))
        XCTAssertEqual(handles.count, 2, "drag handles")
        let from = handles.element(boundBy: 1).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let to = handles.element(boundBy: 0).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1))
        from.press(forDuration: 0.6, thenDragTo: to)
        sleep(1)
        XCTAssertEqual(titles(app), Array(before.reversed()), "dragged to the top")

        app.buttons["fav_move_done"].tap()
        XCTAssertTrue(move.waitForExistence(timeout: 3))
        move.tap()
        XCTAssertTrue(app.cells.element(boundBy: 1).waitForExistence(timeout: 5))
        XCTAssertEqual(titles(app), Array(before.reversed()), "order kept")
    }
}
