import XCTest

/// Build 9 category navigation on Apple TV (SCREENS §3.2 TV): the Series tab has a left category column
/// (country picker · Discover · Pinned · Recently opened · categories). `series-cats.m3u` has 14 series
/// categories, the Turkish ones last; OK on one shows its grid on the right, Menu returns to the column.
final class TVSeriesCategoriesTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor private var remote: XCUIRemote { XCUIRemote.shared }

    @MainActor
    private func focus(_ element: XCUIElement, pressing direction: XCUIRemote.Button, limit: Int = 16) -> Bool {
        for _ in 0..<limit {
            if element.exists && element.hasFocus { return true }
            remote.press(direction)
            usleep(500_000)
        }
        return element.exists && element.hasFocus
    }

    @MainActor
    func testCategoryColumnOpensTurkishCategoryGrid() throws {
        try UITestSupport.requireServed(UITestSupport.seriesCategoriesM3U)
        let app = UITestSupport.launch(["-seedM3U", UITestSupport.seriesCategoriesM3U, "-seedName", "Series"], seed: false)
        let seriesTab = app.tabBars.buttons["Series"]
        XCTAssertTrue(seriesTab.waitForExistence(timeout: 30), "top tab bar")
        XCTAssertTrue(app.buttons["hero_play"].waitForExistence(timeout: 15))
        // Launch focus is on the tab bar (Home); Menu there would leave the app.
        var found = focus(seriesTab, pressing: .right, limit: 5)
        if !found {   // focus started in the content: move up to the tab bar first
            for _ in 0..<4 { remote.press(.up); usleep(400_000) }
            found = focus(seriesTab, pressing: .right, limit: 5)
        }
        XCTAssertTrue(found, "Series tab")
        sleep(2)

        // Column: country picker first, then Discover.
        let picker = app.buttons["country_picker"]
        let discover = app.buttons["category_discover"]
        XCTAssertTrue(discover.waitForExistence(timeout: 10), "category column")
        XCTAssertTrue(picker.exists, "country picker in the column")
        remote.press(.down)
        usleep(800_000)
        // Wherever the content focus landed (column or hero), ◀ reaches the column.
        let columnFocused = app.buttons.matching(NSPredicate(format: "hasFocus == true AND (identifier == 'category_discover' OR identifier == 'country_picker' OR identifier BEGINSWITH 'category_')")).firstMatch
        XCTAssertTrue(focus(columnFocused, pressing: .left, limit: 6), "column focusable")
        UITestSupport.snap("catnav-tvos-01-column", in: self)

        // English UI → the EN language group is preselected; switch to All with the country picker (first row).
        XCTAssertTrue(picker.label.contains("English"), "default group EN")
        XCTAssertTrue(focus(discover, pressing: .up, limit: 30), "Discover row")
        remote.press(.up)   // the country picker is the row above (its focus is reported on an inner element)
        usleep(600_000)
        remote.press(.select)
        // tvOS renders the menu out of the app's accessibility tree; its first entry "All (14)" has focus.
        sleep(1)
        UITestSupport.snap("catnav-tvos-00-country-menu", in: self)
        remote.press(.select)
        sleep(1)
        XCTAssertTrue(picker.label.contains("All"), "All selected")

        // Down the column to the last (Turkish) category.
        let turkish = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'category_row_' AND label CONTAINS 'Türk Dizileri'")).firstMatch
        XCTAssertTrue(focus(turkish, pressing: .down, limit: 24), "last category reachable")
        remote.press(.select)
        let poster = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'grid_' AND label CONTAINS 'Yalı Çapkını'")).firstMatch
        XCTAssertTrue(poster.waitForExistence(timeout: 10), "category grid on the right lists the Turkish series")
        XCTAssertTrue(turkish.hasFocus, "focus stays in the column after OK")
        UITestSupport.snap("catnav-tvos-02-grid", in: self)

        // ▶ into the grid, Menu back to the selected column row (not to the tab bar).
        remote.press(.right)
        usleep(800_000)
        XCTAssertFalse(turkish.hasFocus, "▶ moves focus into the grid")
        let focusedPoster = app.descendants(matching: .any)
            .matching(NSPredicate(format: "hasFocus == true AND label CONTAINS 'Kızılcık Şerbeti'")).firstMatch
        XCTAssertTrue(focusedPoster.exists, "first poster of the grid focused")
        UITestSupport.snap("catnav-tvos-03-grid-focus", in: self)
        remote.press(.menu)
        usleep(800_000)
        XCTAssertTrue(turkish.hasFocus, "Menu in the content returns focus to the column")
        XCTAssertTrue(seriesTab.exists && !seriesTab.hasFocus, "not to the tab bar")
    }
}
