import XCTest

/// Build 11 search on Apple TV (SCREENS §3.6): sections as shelves (one focus target per card), filter chips
/// as a focus row, description excerpt, "Did you mean", programme rows that play, recent searches.
final class TVProSearchTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor private var remote: XCUIRemote { XCUIRemote.shared }

    /// Presses `direction` until an element matching `predicate` has focus; returns it.
    @MainActor
    private func focus(_ query: XCUIElementQuery, _ predicate: String, pressing direction: XCUIRemote.Button,
                       limit: Int = 10) -> XCUIElement? {
        for _ in 0...limit {
            let focused = query.matching(NSPredicate(format: "(\(predicate)) AND hasFocus == true")).firstMatch
            if focused.exists { return focused }
            remote.press(direction)
            presses[direction, default: 0] += 1
            usleep(600_000)
        }
        return nil
    }

    /// Presses per direction since the keyboard had focus (to go back up to it).
    @MainActor private var presses: [XCUIRemote.Button: Int] = [:]

    /// Back to the search keyboard: as many ▲ as ▼ were pressed since typing.
    @MainActor
    private func backToKeyboard() {
        for _ in 0..<(presses[.down] ?? 0) {
            remote.press(.up)
            usleep(500_000)
        }
        presses = [:]
        sleep(1)
    }

    /// Search tab (`-uiScreen search`), keyboard focused, `text` typed.
    @MainActor
    private func openSearch(_ app: XCUIApplication, typing text: String) {
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 30), "tab bar")
        sleep(3)
        remote.press(.down)   // tab bar → keyboard
        sleep(2)
        presses = [:]
        app.typeText(text)
        sleep(3)
    }

    @MainActor
    private func clearText(_ app: XCUIApplication, count: Int = 12) {
        app.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: count))
        sleep(2)
    }

    @MainActor
    func testDescriptionDidYouMeanAndFilters() throws {
        let panel = "\(VLCTestSupport.base)"
        try UITestSupport.requireServed("\(panel)/player_api.php?username=demo&password=demo")
        let app = UITestSupport.launch(["-seedXtream", panel, "-seedName", "Panel", "-uiScreen", "search"], seed: false)
        openSearch(app, typing: "seyran")
        let description = focus(app.buttons, "identifier == 'search_description_series_903'", pressing: .down)
        XCTAssertNotNil(description, "description match focusable")
        XCTAssertTrue(description?.label.contains("Seyran") == true, description?.label ?? "")
        sleep(1)
        UITestSupport.snap("prosearch-tvos-description", in: self)

        backToKeyboard()
        clearText(app)
        app.typeText("konuşanlr")
        sleep(3)
        let chip = focus(app.buttons, "identifier == 'search_did_you_mean'", pressing: .down)
        XCTAssertNotNil(chip, "did-you-mean focusable")
        XCTAssertTrue(app.buttons["search_similar_series_901"].exists, "similar results")
        UITestSupport.snap("prosearch-tvos-didyoumean", in: self)
        remote.press(.select)
        sleep(3)
        XCTAssertTrue(app.buttons["search_series_901"].waitForExistence(timeout: 10), "corrected search runs")

        // Filter chips: a focus row; choosing Live shows the full list.
        backToKeyboard()
        clearText(app)
        app.typeText("disney")
        sleep(3)
        XCTAssertNotNil(focus(app.buttons, "identifier BEGINSWITH 'search_filter_'", pressing: .down), "filter chips focusable")
        XCTAssertNotNil(focus(app.buttons, "identifier == 'search_filter_live'", pressing: .right, limit: 4))
        remote.press(.select)
        sleep(2)
        XCTAssertTrue(app.buttons["search_list_live_102"].waitForExistence(timeout: 10), "full channel list")
        UITestSupport.snap("prosearch-tvos-filters", in: self)
    }

    /// Demo M3U + EPG: "derby" → On TV row, focus + OK plays the channel; the query becomes a recent search.
    @MainActor
    func testProgrammeRowPlaysAndRecentSearches() throws {
        let app = UITestSupport.launch(["-uiScreen", "search"])
        sleep(4)   // EPG loads in the background after the lists
        openSearch(app, typing: "derby")
        let programme = focus(app.buttons, "identifier BEGINSWITH 'search_programme_'", pressing: .down)
        XCTAssertNotNil(programme, "programme card focusable")
        sleep(1)
        UITestSupport.snap("prosearch-tvos-tv", in: self)
        remote.press(.select)
        XCTAssertTrue(app.otherElements["video_surface"].waitForExistence(timeout: 10), "plays the channel")
        sleep(3)
        remote.press(.menu)
        sleep(1)
        if app.otherElements["video_surface"].exists { remote.press(.menu) }
        XCTAssertTrue(app.otherElements["video_surface"].waitForNonExistence(timeout: 5))

        backToKeyboard()
        clearText(app)
        remote.press(.down)
        // The list cell takes the focus (the row's id sits on its button).
        XCTAssertTrue(app.descendants(matching: .any)["search_recent_0"].waitForExistence(timeout: 5), "recent search listed")
        XCTAssertTrue(app.descendants(matching: .any)["search_recent_0"].label.contains("derby"))
        let recent = focus(app.cells, "label CONTAINS 'derby'", pressing: .down, limit: 2)
            ?? focus(app.cells, "label CONTAINS 'derby'", pressing: .up, limit: 3)
        XCTAssertNotNil(recent, "recent search row focusable")
        sleep(1)
        UITestSupport.snap("prosearch-tvos-recent", in: self)
    }
}
