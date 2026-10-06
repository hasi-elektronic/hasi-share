import XCTest

/// Task 7c on Apple TV: the Series tab's category chips are focusable and reach the last (Turkish)
/// category of `series-cats.m3u`; selecting a chip opens that category's grid.
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
    func testSeriesCategoryChipsReachTurkishCategory() throws {
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
        let chips = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'category_chip_'"))
        XCTAssertTrue(chips.firstMatch.waitForExistence(timeout: 10), "category chips")
        let focusedChip = chips.matching(NSPredicate(format: "hasFocus == true")).firstMatch
        XCTAssertTrue(focus(focusedChip, pressing: .down, limit: 6), "chip row focusable")
        let turkish = chips.matching(NSPredicate(format: "label CONTAINS 'Türk Dizileri'")).firstMatch
        XCTAssertTrue(focus(turkish, pressing: .right, limit: 16), "last chip reachable")
        UITestSupport.snap("tvos-series-categories-chip", in: self)
        remote.press(.select)
        let poster = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'grid_' AND label CONTAINS 'Yalı Çapkını'")).firstMatch
        XCTAssertTrue(poster.waitForExistence(timeout: 10), "category grid lists the Turkish series")
        UITestSupport.snap("tvos-series-categories-grid", in: self)
    }
}
