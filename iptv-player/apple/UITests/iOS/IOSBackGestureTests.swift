import XCTest

/// Owner request (Build 10): "swiping from left to right should go back" – the app hides the navigation bar,
/// which used to disable the system edge swipe. Pushed pages pop, the full-screen category page closes.
final class IOSBackGestureTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    /// Drag from the very left edge to the middle of the screen.
    @MainActor
    private func edgeSwipe(in app: XCUIApplication) {
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0.5)).withOffset(CGVector(dx: 2, dy: 0))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .default, thenHoldForDuration: 0.05)
    }

    @MainActor
    func testEdgeSwipeGoesBackFromDetailAndClosesCategoryPage() throws {
        try UITestSupport.requireServed(UITestSupport.seriesCategoriesM3U)
        let app = UITestSupport.launch(["-seedM3U", UITestSupport.seriesCategoriesM3U, "-seedName", "Series"], seed: false)
        IOSFlowTests.openSection("series", in: app)
        let categories = app.buttons["category_button"]
        XCTAssertTrue(categories.waitForExistence(timeout: 20))

        // Series detail pushed from a shelf → edge swipe → back on the Series page.
        let poster = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'poster_'")).firstMatch
        XCTAssertTrue(poster.waitForExistence(timeout: 10), "a poster on the page")
        poster.tap()
        let close = app.buttons["detail_close"]
        XCTAssertTrue(close.waitForExistence(timeout: 10), "detail pushed")
        edgeSwipe(in: app)
        XCTAssertTrue(close.waitForNonExistence(timeout: 5), "edge swipe pops the detail")
        XCTAssertTrue(categories.waitForExistence(timeout: 5), "Series page back")

        categories.tap()
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'category_row_'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))

        // Full-screen category page → edge swipe closes it.
        edgeSwipe(in: app)
        XCTAssertTrue(row.waitForNonExistence(timeout: 5), "edge swipe closes the category page")
        XCTAssertTrue(categories.isHittable, "Series page back")

        // The root (nothing to go back to) ignores the swipe: the page stays usable.
        edgeSwipe(in: app)
        XCTAssertTrue(categories.isHittable, "root unaffected")
        XCTAssertTrue(app.buttons["tab_series"].isSelected || app.buttons["tab_series"].exists)
    }
}
