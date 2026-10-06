import XCTest

/// iPhone header (SCREENS §2, Task 4e): every text tab, search and settings must react to ONE real
/// tap (coordinate tap at the visible label, no XCUITest auto-scroll) — from the top of Home, from a
/// scrolled Home, after the settings sheet, after the player, and in landscape.
final class IOSHeaderTests: XCTestCase {
    static let tabs = ["home", "movies", "series", "live", "guide"]

    override func setUp() {
        continueAfterFailure = false
    }

    override func tearDown() {
        XCUIDevice.shared.orientation = .portrait
    }

    // MARK: Helpers

    /// Taps the tab like a finger: at the centre of its on-screen frame, without letting XCUITest
    /// scroll it into view first. Fails when the label is not fully on screen.
    @MainActor
    static func fingerTap(_ id: String, in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let tab = app.buttons["tab_\(id)"]
        XCTAssertTrue(tab.waitForExistence(timeout: 10), "header tab \(id)", file: file, line: line)
        let window = app.windows.firstMatch.frame
        let f = tab.frame
        let search = app.buttons["open_search"].frame
        XCTAssertTrue(window.contains(f), "tab \(id) fully on screen without scrolling the strip (frame \(f), window \(window))", file: file, line: line)
        XCTAssertFalse(f.intersects(search) || f.intersects(app.buttons["open_settings"].frame),
                       "tab \(id) not hidden behind search/settings (frame \(f), search \(search))", file: file, line: line)
        XCTAssertGreaterThanOrEqual(f.height, 43.5, "tab \(id) touch target ≥ 44 pt high", file: file, line: line)
        tab.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    }

    /// Selected tab (isSelected trait) after a short settle.
    @MainActor
    static func assertSelected(_ id: String, in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let tab = app.buttons["tab_\(id)"]
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline, !tab.isSelected { usleep(100_000) }
        XCTAssertTrue(tab.isSelected, "tab \(id) selected after one tap", file: file, line: line)
        for other in tabs where other != id {
            XCTAssertFalse(app.buttons["tab_\(other)"].isSelected, "only \(id) selected (also: \(other))", file: file, line: line)
        }
    }

    /// Screen content of a section, so "selected" also means "the section is visible".
    @MainActor
    static func assertContent(_ id: String, in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let element: XCUIElement
        switch id {
        case "live": element = app.buttons["category_menu"]
        case "guide": element = app.buttons["guide_filter_0"]
        default: element = app.buttons["hero_play"]
        }
        XCTAssertTrue(element.waitForExistence(timeout: 5), "content of \(id)", file: file, line: line)
    }

    @MainActor
    static func cycleAllTabs(_ app: XCUIApplication, label: String, file: StaticString = #filePath, line: UInt = #line) {
        for id in tabs.dropFirst() + ["home"] {
            fingerTap(id, in: app, file: file, line: line)
            assertSelected(id, in: app, file: file, line: line)
            assertContent(id, in: app, file: file, line: line)
        }
    }

    @MainActor
    func launchHome() -> XCUIApplication {
        let app = UITestSupport.launch(["-uiSeedLibrary"])
        XCTAssertTrue(app.buttons["hero_play"].waitForExistence(timeout: 30), "home hero")
        XCTAssertTrue(app.buttons["tab_home"].isSelected)
        return app
    }

    // MARK: Tests

    @MainActor
    func testEveryTabFromHomeTopPortrait() {
        let app = launchHome()
        UITestSupport.snap("header-01-portrait-top", in: self)
        Self.cycleAllTabs(app, label: "top")
    }

    @MainActor
    func testTabsFromScrolledHome() {
        let app = launchHome()
        app.swipeUp()
        app.swipeUp()
        sleep(1)
        UITestSupport.snap("header-02-portrait-scrolled", in: self)
        Self.fingerTap("guide", in: app)
        Self.assertSelected("guide", in: app)
        Self.fingerTap("home", in: app)
        Self.assertSelected("home", in: app)
        app.swipeUp()
        sleep(1)
        Self.fingerTap("movies", in: app)
        Self.assertSelected("movies", in: app)
        Self.assertContent("movies", in: app)
    }

    @MainActor
    func testSearchAndSettingsAndTabsAfterSheet() {
        let app = launchHome()
        app.buttons["open_settings"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(app.buttons["settings_close"].waitForExistence(timeout: 5), "settings on first tap")
        app.buttons["settings_close"].tap()
        XCTAssertTrue(app.buttons["settings_close"].waitForNonExistence(timeout: 5))
        Self.cycleAllTabs(app, label: "after settings")

        app.buttons["open_search"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(app.searchFields.firstMatch.waitForExistence(timeout: 5), "search on first tap")
        UITestSupport.snap("header-07-search", in: self)
        let cancel = app.buttons["close"]   // iOS 26: active search (bottom field) hides the navigation bar
        if cancel.exists { cancel.tap() }
        let back = app.navigationBars.buttons.firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 3), "back button after closing the search field")
        back.tap()
        Self.fingerTap("series", in: app)
        Self.assertSelected("series", in: app)
    }

    @MainActor
    func testTabsAfterClosingPlayer() {
        let app = launchHome()
        let channel = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'channel_card_'")).firstMatch
        XCTAssertTrue(channel.waitForExistence(timeout: 10), "a live channel card on Home")
        channel.tap()
        let surface = app.otherElements["video_surface"]
        XCTAssertTrue(surface.waitForExistence(timeout: 10))
        let close = app.buttons["player_close"]
        for _ in 0..<4 where !close.exists {
            surface.tap()
            _ = close.waitForExistence(timeout: 2)
        }
        if !close.exists { UITestSupport.snap("header-debug-player", in: self) }
        XCTAssertTrue(close.exists, "player overlay")
        close.tap()
        XCTAssertTrue(app.buttons["tab_home"].waitForExistence(timeout: 10))
        Self.assertSelected("home", in: app)
        Self.cycleAllTabs(app, label: "after player")
    }

    /// Large Dynamic Type: the header grows, so screens without hero must start BELOW it (no fixed
    /// 50 pt offset) and every tab still fits.
    @MainActor
    func testLargeDynamicTypeHeaderDoesNotCoverContent() {
        let app = UITestSupport.launch(["-uiSeedLibrary", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityL"])
        XCTAssertTrue(app.buttons["tab_home"].waitForExistence(timeout: 30))
        UITestSupport.snap("header-05-large-type-home", in: self)
        Self.fingerTap("live", in: app)
        Self.assertSelected("live", in: app)
        let menu = app.buttons["category_menu"]
        XCTAssertTrue(menu.waitForExistence(timeout: 10))
        sleep(1)
        UITestSupport.snap("header-06-large-type-live", in: self)
        let headerBottom = Self.tabs.map { app.buttons["tab_\($0)"].frame.maxY }.max() ?? 0
        XCTAssertGreaterThanOrEqual(menu.frame.minY, headerBottom, "category menu below the header (menu \(menu.frame), header bottom \(headerBottom))")
        Self.fingerTap("guide", in: app)
        Self.assertSelected("guide", in: app)
    }

    @MainActor
    func testEveryTabLandscape() {
        let app = launchHome()
        XCUIDevice.shared.orientation = .landscapeLeft
        sleep(2)
        UITestSupport.snap("header-03-landscape-top", in: self)
        Self.cycleAllTabs(app, label: "landscape")
        app.swipeUp()
        sleep(1)
        UITestSupport.snap("header-04-landscape-scrolled", in: self)
        Self.fingerTap("series", in: app)
        Self.assertSelected("series", in: app)
    }
}
