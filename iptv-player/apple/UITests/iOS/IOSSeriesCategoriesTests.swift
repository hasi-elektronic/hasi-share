import XCTest

/// Build 9 category navigation (SCREENS §3.2). `series-cats.m3u` (next to the seed playlist on the local
/// media server; copy in UITests/Fixtures) has 14 series categories (EN/DE/TR/… prefixes, "Türk Dizileri"
/// without one, the Turkish ones last). Every category must be reachable from the sticky "Categories" button:
/// sheet → search → country filter → pin → open the category grid.
final class IOSSeriesCategoriesTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    private func element(_ prefix: String, containing text: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", prefix, text)).firstMatch
    }

    @MainActor
    func testCategorySheetSearchCountryPinAndOpen() throws {
        try UITestSupport.requireServed(UITestSupport.seriesCategoriesM3U)
        let app = UITestSupport.launch(["-seedM3U", UITestSupport.seriesCategoriesM3U, "-seedName", "Series"], seed: false)
        IOSFlowTests.openSection("series", in: app)

        // Sticky row under the header: Categories ▾ + country picker (English UI → "All").
        let categories = app.buttons["category_button"]
        XCTAssertTrue(categories.waitForExistence(timeout: 20), "sticky Categories button")
        XCTAssertTrue(app.buttons["country_picker"].exists, "country picker")
        XCTAssertFalse(app.descendants(matching: .any)["categories"].exists, "old chip shelf removed")
        UITestSupport.snap("catnav-ios-01-page", in: self)

        // Still there after scrolling the page.
        app.swipeUp()
        XCTAssertTrue(categories.isHittable, "Categories row is sticky")
        app.swipeDown()

        categories.tap()
        XCTAssertTrue(app.navigationBars["Series categories"].waitForExistence(timeout: 5), "sheet title")
        // A series-only category is listed.
        XCTAssertTrue(element("category_row_", containing: "Netflix Series", in: app).waitForExistence(timeout: 5))
        UITestSupport.snap("catnav-ios-02-sheet", in: self)

        // Search: case/diacritics-insensitive, finds the last (14th) category.
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("turk")
        XCTAssertTrue(element("category_row_", containing: "Türk Dizileri", in: app).waitForExistence(timeout: 5), "search hit")
        XCTAssertFalse(element("category_row_", containing: "Netflix", in: app).exists, "search filters")
        UITestSupport.snap("catnav-ios-03-search", in: self)
        // Clear the search (cancel button of the search bar).
        if app.buttons["Cancel"].exists { app.buttons["Cancel"].tap() } else { search.buttons.firstMatch.tap() }

        // Country filter: TR → only the TR-prefixed category; "Türk Dizileri" (no country) only under All.
        let trChip = app.buttons["country_chip_TR"]
        XCTAssertTrue(trChip.waitForExistence(timeout: 5), "TR country chip")
        trChip.tap()
        let turkish = element("category_row_", containing: "DİZİLER", in: app)
        XCTAssertTrue(turkish.waitForExistence(timeout: 5), "TR category under TR")
        XCTAssertFalse(element("category_row_", containing: "Netflix", in: app).exists, "EN categories filtered out")
        XCTAssertFalse(element("category_row_", containing: "Türk Dizileri", in: app).exists, "no-country category only under All")
        UITestSupport.snap("catnav-ios-04-country", in: self)

        // Pin (long press menu) → appears under Pinned.
        turkish.press(forDuration: 1.2)
        let pin = app.buttons["Pin"]
        XCTAssertTrue(pin.waitForExistence(timeout: 5), "context menu: Pin")
        pin.tap()
        XCTAssertTrue(app.descendants(matching: .any)["category_section_pinned"].waitForExistence(timeout: 5), "Pinned section")
        let pinned = element("category_pinned_", containing: "DİZİLER", in: app)
        XCTAssertTrue(pinned.exists, "pinned entry")
        UITestSupport.snap("catnav-ios-05-pinned", in: self)

        // Open → sheet closes, the category grid lists its series.
        pinned.tap()
        let poster = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'grid_' AND label CONTAINS 'Kuruluş Osman'")).firstMatch
        XCTAssertTrue(poster.waitForExistence(timeout: 10), "category grid lists the Turkish series")
        UITestSupport.snap("catnav-ios-06-grid", in: self)

        // Back on the page: country follows (TR), pinned row first, recent recorded in the sheet.
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(categories.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["country_picker"].label.contains("Turkey") || app.buttons["country_picker"].label.contains("Türkiye"),
                      "page follows the country chosen in the sheet")
        categories.tap()
        XCTAssertTrue(element("category_recent_", containing: "DİZİLER", in: app).waitForExistence(timeout: 5), "Recently opened")
        app.buttons["category_sheet_close"].tap()

        // Country picker menu on the page: back to All.
        app.buttons["country_picker"].tap()
        let all = app.buttons["country_option_all"]
        XCTAssertTrue(all.waitForExistence(timeout: 5), "country menu")
        UITestSupport.snap("catnav-ios-07-country-menu", in: self)
        all.tap()
        XCTAssertTrue(app.buttons["country_picker"].label.contains("All"))
    }
}
