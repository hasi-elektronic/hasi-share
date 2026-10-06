import XCTest

/// Live TV as a list (SCREENS §3.3): rows with now/next, chips with counts, long-press menu,
/// favorites section first, tap plays; landscape adds the info panel.
final class IOSLiveListTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }

    override func tearDown() {
        XCUIDevice.shared.orientation = .portrait
    }

    @MainActor
    private func firstRow(_ app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'channel_'")).firstMatch
    }

    @MainActor
    func testListRowsChipsMenuAndFavoritesFirst() throws {
        let app = UITestSupport.launch(["-uiScreen", "live"])
        let row = firstRow(app)
        XCTAssertTrue(row.waitForExistence(timeout: 30))
        sleep(2)   // logos
        UITestSupport.snap("live-list/ios-01-list-portrait", in: self)
        let channelId = String(row.identifier.dropFirst("channel_".count))
        XCTAssertTrue((60...110).contains(row.frame.height), "list row height \(row.frame.height)")
        XCTAssertTrue(row.label.contains("Next "), "row shows the next programme (\(row.label))")
        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'channel_'"))
        XCTAssertGreaterThanOrEqual(rows.count, 8, "a list shows many channels per screen")

        // Chips: ★ Favorites first, then All with its count; a category chip filters.
        let favChip = app.buttons["live_chip_0"]
        let allChip = app.buttons["live_chip_1"]
        XCTAssertTrue(favChip.label.contains("Favorites"))
        XCTAssertTrue(allChip.label.contains("All"))
        XCTAssertTrue(allChip.isSelected, "All selected by default")
        let category = app.buttons["live_chip_2"]
        category.tap()
        XCTAssertTrue(category.isSelected)
        XCTAssertFalse(allChip.isSelected)
        XCTAssertTrue(firstRow(app).waitForExistence(timeout: 5), "category rows")
        UITestSupport.snap("live-list/ios-02-category-chip", in: self)
        allChip.tap()
        XCTAssertTrue(allChip.isSelected)

        // Long press: favorite first, hide, guide; adding puts the channel into the first section.
        XCTAssertTrue(firstRow(app).waitForExistence(timeout: 5))
        app.buttons["channel_\(channelId)"].press(forDuration: 1.2)
        let add = app.buttons.matching(NSPredicate(format: "label == 'Add to favorites' AND NOT (identifier BEGINSWITH 'fav_')")).firstMatch
        XCTAssertTrue(add.waitForExistence(timeout: 3), "context menu")
        XCTAssertTrue(app.buttons["Hide channel"].exists)
        XCTAssertTrue(app.buttons["Show in TV guide"].exists)
        UITestSupport.snap("live-list/ios-03-long-press-menu", in: self)
        add.tap()
        let header = app.descendants(matching: .any)["live_section_favorites"]
        let favRow = app.buttons["live_favorite_\(channelId)"]
        XCTAssertTrue(favRow.waitForExistence(timeout: 3), "favorites section")
        XCTAssertTrue(header.exists)
        XCTAssertLessThan(favRow.frame.minY, app.descendants(matching: .any)["live_section_all"].frame.minY, "favorites first")
        XCTAssertTrue(favChip.label.contains("1"), "favorites chip count (\(favChip.label))")
        sleep(1)
        UITestSupport.snap("live-list/ios-04-favorites-first", in: self)

        // Tap plays.
        favRow.tap()
        XCTAssertTrue(app.otherElements["video_surface"].waitForExistence(timeout: 10), "tap plays")
    }

    @MainActor
    func testLandscapeShowsInfoPanel() throws {
        let app = UITestSupport.launch(["-uiScreen", "live"])
        XCTAssertTrue(firstRow(app).waitForExistence(timeout: 30))
        XCUIDevice.shared.orientation = .landscapeLeft
        let panel = app.descendants(matching: .any)["live_info_panel"]
        XCTAssertTrue(panel.waitForExistence(timeout: 5), "wide layout: info panel")
        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'channel_'"))
        let second = rows.element(boundBy: 1)
        let name = second.label.components(separatedBy: ",").first ?? ""
        second.tap()   // first tap selects
        XCTAssertTrue(second.isSelected, "row selected")
        XCTAssertTrue(panel.staticTexts[name].waitForExistence(timeout: 3), "panel shows \(name)")
        XCTAssertFalse(app.otherElements["video_surface"].exists, "first tap does not play")
        XCTAssertTrue(app.buttons["live_panel_play"].exists)
        sleep(1)
        UITestSupport.snap("live-list/ios-05-landscape-panel", in: self)
        second.tap()   // second tap plays
        XCTAssertTrue(app.otherElements["video_surface"].waitForExistence(timeout: 10), "tap on the selected row plays")
    }
}
