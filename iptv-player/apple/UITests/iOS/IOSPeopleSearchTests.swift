import XCTest

/// Build 10 (owner report: "Hasan" found nothing for Hasan Can Kaya's show; "disney" no Disney categories).
/// Seeds the fake Xtream panel of UITests/Fixtures/xtream (served by range_server.py on the VLC media port:
/// `/player_api.php?action=…` → `xtream/<action>.json`).
final class IOSPeopleSearchTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    private func search(_ text: String, in app: XCUIApplication) {
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        if let value = field.value as? String, !value.isEmpty, value != field.placeholderValue {
            field.buttons.firstMatch.tap()   // clear
            field.tap()   // iPad: the toolbar field can lose focus with the clear button
        }
        field.typeText(text)
    }

    @MainActor
    func testPersonAndCategoryResults() throws {
        let panel = "\(VLCTestSupport.base)"
        try UITestSupport.requireServed("\(panel)/player_api.php?username=demo&password=demo")
        let app = UITestSupport.launch(["-seedXtream", panel, "-seedName", "Panel"], seed: false)
        XCTAssertTrue(app.buttons["open_search"].waitForExistence(timeout: 30), "home loaded")
        app.buttons["open_search"].tap()

        // Person: "Hasan" is only in the cast of "Konuşanlar" → People section, subtitle = the person.
        search("Hasan", in: app)
        let person = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'search_person_' AND label CONTAINS 'Konuşanlar'")).firstMatch
        XCTAssertTrue(person.waitForExistence(timeout: 10), "series found by its cast")
        XCTAssertTrue(app.staticTexts["Hasan Can Kaya"].exists, "matched person shown")
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'search_series_'")).firstMatch.exists,
                       "not a title match")
        UITestSupport.snap("search-person", in: self)

        // Category: "disney" → category cards on top (movie, series, live), the series one opens its grid.
        search("disney", in: app)
        let seriesCategory = app.buttons["search_category_series_20"]
        XCTAssertTrue(seriesCategory.waitForExistence(timeout: 10), "series category found")
        XCTAssertTrue(app.buttons["search_category_movie_11"].exists, "movie category")
        XCTAssertTrue(app.buttons["search_category_live_2"].exists, "live category")
        XCTAssertLessThan(seriesCategory.frame.minY, app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'search_channel_'")).firstMatch.frame.minY,
                          "categories above the title results")
        UITestSupport.snap("search-category", in: self)
        seriesCategory.tap()
        let poster = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'grid_' AND label CONTAINS 'Konuşanlar'")).firstMatch
        XCTAssertTrue(poster.waitForExistence(timeout: 10), "category grid")

        // Live category → Live TV filtered to it.
        app.navigationBars.buttons.element(boundBy: 0).tap()   // back to the results (query kept)
        XCTAssertTrue(app.buttons["search_category_live_2"].waitForExistence(timeout: 10), "results kept after back")
        let live = app.buttons["search_category_live_2"]
        for _ in 0..<3 where live.frame.maxX > app.windows.firstMatch.frame.maxX { app.buttons["search_category_series_20"].swipeLeft() }
        live.tap()
        XCTAssertTrue(app.descendants(matching: .any)["channel_102"].waitForExistence(timeout: 10), "Disney Junior listed")
        XCTAssertFalse(app.descendants(matching: .any)["channel_101"].exists, "only the chosen category")
    }
}
