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

    /// iPhone landscape: list + info panel, but a tap plays at once (select-first is iPad only).
    @MainActor
    func testIPhoneLandscapePanelAndTapPlays() throws {
        let app = UITestSupport.launch(["-uiScreen", "live"])
        XCTAssertTrue(firstRow(app).waitForExistence(timeout: 30))
        XCUIDevice.shared.orientation = .landscapeLeft
        let panel = app.descendants(matching: .any)["live_info_panel"]
        XCTAssertTrue(panel.waitForExistence(timeout: 5), "wide layout: info panel")
        sleep(1)
        UITestSupport.snap("live-list/ios-05-landscape-panel", in: self)
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'channel_'")).element(boundBy: 1).tap()
        XCTAssertTrue(app.otherElements["video_surface"].waitForExistence(timeout: 10), "iPhone landscape: the first tap plays")
    }

    /// The last played channel is marked "● Watching" after the player is closed.
    @MainActor
    func testLastPlayedChannelMarkedWatching() throws {
        let app = UITestSupport.launch(["-uiScreen", "live"])
        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'channel_'"))
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 30))
        let row = rows.element(boundBy: 2)
        let id = row.identifier
        XCTAssertFalse(row.label.contains("Watching"))
        row.tap()
        let surface = app.otherElements["video_surface"]
        XCTAssertTrue(surface.waitForExistence(timeout: 10))
        let close = app.buttons["player_close"]
        _ = close.waitForNonExistence(timeout: 8)
        surface.tap()
        XCTAssertTrue(close.waitForExistence(timeout: 3))
        close.tap()
        XCTAssertTrue(surface.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.buttons[id].label.contains("Watching"), "last played row: \(app.buttons[id].label)")
        UITestSupport.snap("live-list/ios-06-watching", in: self)
    }

    /// Long press → "Show in TV guide": guide on the channel's category, the row on screen.
    @MainActor
    func testShowInGuideFocusesTheChannel() throws {
        let app = UITestSupport.launch(["-uiScreen", "live"])
        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'channel_'"))
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 30))
        app.swipeUp()
        sleep(1)
        let row = rows.allElementsBoundByIndex.last { $0.isHittable }!
        let id = row.identifier
        let name = row.label.components(separatedBy: ",").first ?? ""
        row.press(forDuration: 1.2)
        let guide = app.buttons["Show in TV guide"]
        XCTAssertTrue(guide.waitForExistence(timeout: 3))
        guide.tap()
        XCTAssertTrue(app.buttons["tab_guide"].waitForExistence(timeout: 5))
        let epgRow = app.buttons[id]
        XCTAssertTrue(epgRow.waitForExistence(timeout: 5), "guide row of \(name)")
        XCTAssertTrue(epgRow.isHittable, "scrolled into view")
        let selectedChip = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'guide_filter_' AND selected == true")).firstMatch
        XCTAssertTrue(selectedChip.exists)
        XCTAssertFalse(selectedChip.identifier == "guide_filter_0", "the channel's category, not All (\(selectedChip.label))")
        UITestSupport.snap("live-list/ios-07-show-in-guide", in: self)
    }
}
