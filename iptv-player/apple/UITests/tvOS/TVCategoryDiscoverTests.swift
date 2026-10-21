import XCTest

/// Build 13 owner report (Apple TV): Movies/Series → category column → OK on "Discover" while a category grid is
/// shown did nothing – the grid stayed on the right. OK on Discover must show the browse page again. (Not
/// reproducible in the simulator with these paths – kept as regression coverage of the previously untested path.)
final class TVCategoryDiscoverTests: XCTestCase {
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
    func testDiscoverShowsTheBrowsePageAgainInMovies() throws {
        try checkDiscover(tab: "Movies")
    }

    @MainActor
    func testDiscoverShowsTheBrowsePageAgainInSeries() throws {
        try checkDiscover(tab: "Series")
    }

    /// The owner's setup: an Xtream panel (local fixture).
    @MainActor
    func testDiscoverShowsTheBrowsePageAgainInXtreamMovies() throws {
        let panel = "\(VLCTestSupport.base)"
        try UITestSupport.requireServed("\(panel)/player_api.php?username=demo&password=demo")
        try checkDiscover(tab: "Movies", seed: ["-seedXtream", panel, "-seedName", "Panel"])
    }

    @MainActor
    private func checkDiscover(tab name: String, seed: [String]? = nil) throws {
        let app = seed.map { UITestSupport.launch($0, seed: false) } ?? UITestSupport.launch()
        let tab = app.tabBars.buttons[name]
        XCTAssertTrue(tab.waitForExistence(timeout: 30), "top tab bar")
        XCTAssertTrue(app.buttons["hero_play"].waitForExistence(timeout: 15))
        var found = focus(tab, pressing: .right, limit: 5)
        if !found {
            for _ in 0..<4 { remote.press(.up); usleep(400_000) }
            found = focus(tab, pressing: .right, limit: 5)
        }
        XCTAssertTrue(found, "\(name) tab")
        sleep(2)

        let discover = app.buttons["category_discover"]
        XCTAssertTrue(discover.waitForExistence(timeout: 10), "category column")
        remote.press(.down)
        usleep(800_000)
        let columnFocused = app.buttons.matching(NSPredicate(format: "hasFocus == true AND (identifier == 'country_picker' OR identifier BEGINSWITH 'category_')")).firstMatch
        XCTAssertTrue(focus(columnFocused, pressing: .left, limit: 6), "column focusable")

        // OK on a category → its grid; Discover → browse page. Three ways: directly from the column; after ▶ into
        // the grid and Menu back to the column (the usual remote path); after leaving to another tab and coming
        // back (the "Recently opened" section appears above the categories).
        for pass in 1...3 {
            let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'category_row_'")).firstMatch
            // Entering the column lands on the selected row (Discover, Build 16 B-13), the first category is below it;
            // later passes start on Discover too.
            let ok = focus(row, pressing: .down, limit: 3) || focus(row, pressing: .up, limit: 20)
            XCTAssertTrue(ok, "a category row (pass \(pass))")
            remote.press(.select)
            let gridPoster = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'grid_'")).firstMatch
            XCTAssertTrue(gridPoster.waitForExistence(timeout: 10), "category grid on the right (pass \(pass))")
            XCTAssertFalse(app.buttons["hero_play"].exists, "browse page replaced by the grid")
            UITestSupport.snap("catnav-discover-\(name)-\(pass)-01-grid", in: self)
            if pass == 2 {
                remote.press(.right)
                usleep(800_000)
                remote.press(.menu)
                usleep(800_000)
            }
            if pass == 3 {   // to another tab and back (the column's "Recently opened" snapshot refreshes)
                remote.press(.menu)
                usleep(800_000)
                XCTAssertTrue(tab.hasFocus, "Menu in the column → tab bar")
                remote.press(.right); sleep(2)
                remote.press(.left); sleep(2)
                XCTAssertTrue(tab.hasFocus)
                remote.press(.down)
                usleep(800_000)
                let column = app.buttons.matching(NSPredicate(format: "hasFocus == true AND (identifier == 'country_picker' OR identifier BEGINSWITH 'category_')")).firstMatch
                XCTAssertTrue(focus(column, pressing: .left, limit: 6), "back in the column")
                UITestSupport.snap("catnav-discover-\(name)-3-01b-back", in: self)
            }

            // Up to Discover, OK → the browse page again.
            XCTAssertTrue(focus(discover, pressing: .up, limit: 30), "Discover row")
            remote.press(.select)
            usleep(500_000)
            XCTAssertTrue(discover.hasFocus, "focus stays on Discover")
            XCTAssertTrue(app.buttons["hero_play"].waitForExistence(timeout: 5), "OK on Discover shows the browse page (pass \(pass))")
            XCTAssertTrue(gridPoster.waitForNonExistence(timeout: 3), "category grid closed")
            XCTAssertTrue(discover.isSelected, "Discover marked as selected")
            UITestSupport.snap("catnav-discover-\(name)-\(pass)-02-browse", in: self)
        }
    }
}
