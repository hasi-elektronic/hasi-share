import XCTest

/// Apple TV Live list (SCREENS §3.3): categories | list | info panel; focus drives the panel, OK plays.
final class TVLiveListTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testFocusMovesThroughListPanelFollowsOKPlays() throws {
        let remote = XCUIRemote.shared
        let app = UITestSupport.launch(["-uiScreen", "live"])
        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'channel_'"))
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 30))
        XCTAssertTrue(app.descendants(matching: .any)["live_category_chips"].exists, "category column")
        let panel = app.descendants(matching: .any)["live_info_panel"]
        XCTAssertTrue(panel.exists, "info panel")

        // Into the content, then right until a channel row has the focus.
        let focusedRow = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'channel_' AND hasFocus == true"))
        remote.press(.down)
        sleep(1)
        for _ in 0..<4 where focusedRow.count == 0 {
            remote.press(.right)
            sleep(1)
        }
        XCTAssertEqual(focusedRow.count, 1, "a list row has the focus")
        let first = focusedRow.firstMatch.label.components(separatedBy: ",").first ?? ""
        XCTAssertTrue(panel.staticTexts[first].waitForExistence(timeout: 2), "panel shows the focused channel \(first)")
        UITestSupport.snap("live-list/tvos-01-list-focus", in: self)

        remote.press(.down)
        sleep(1)
        let second = focusedRow.firstMatch.label.components(separatedBy: ",").first ?? ""
        XCTAssertNotEqual(first, second, "▼ moves to the next row")
        XCTAssertTrue(panel.staticTexts[second].waitForExistence(timeout: 2), "panel follows the focus (\(second))")
        UITestSupport.snap("live-list/tvos-02-panel-follows", in: self)

        remote.press(.select)
        XCTAssertTrue(app.otherElements["video_surface"].waitForExistence(timeout: 10), "OK plays")
    }

    /// Presses `direction` until `element` has focus.
    @MainActor
    private func focus(_ element: XCUIElement, pressing direction: XCUIRemote.Button, limit: Int = 15) -> Bool {
        for _ in 0..<limit {
            if element.exists && element.hasFocus { return true }
            XCUIRemote.shared.press(direction)
            usleep(500_000)
        }
        return element.exists && element.hasFocus
    }

    /// Focuses the first channel row of the list and returns its id.
    @MainActor
    private func focusFirstRow(_ app: XCUIApplication) -> String? {
        let focusedRow = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'channel_' AND hasFocus == true"))
        XCUIRemote.shared.press(.down)
        sleep(1)
        for _ in 0..<4 where focusedRow.count == 0 {
            XCUIRemote.shared.press(.right)
            sleep(1)
        }
        return focusedRow.count == 1 ? focusedRow.firstMatch.identifier : nil
    }

    /// Long OK on a row, then `downs` × ▼ and OK. The tvOS context menu is not in the app's
    /// accessibility tree, so items are chosen by position: favorite · hide channel · hide category ·
    /// (archive) · show in TV guide (last; extra ▼ stop there).
    @MainActor
    private func chooseFromRowMenu(downs: Int, snap: String? = nil) {
        XCUIRemote.shared.press(.select, forDuration: 1.5)
        sleep(1)
        for _ in 0..<downs { XCUIRemote.shared.press(.down); usleep(400_000) }
        if let snap { UITestSupport.snap(snap, in: self) }
        XCUIRemote.shared.press(.select)
        sleep(1)
    }

    /// Long OK → hide channel; the category column's last row "Show hidden (n)" brings it back.
    @MainActor
    func testHideChannelAndShowHiddenAgain() throws {
        let app = UITestSupport.launch(["-uiScreen", "live"])
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'channel_'")).firstMatch.waitForExistence(timeout: 30))
        sleep(1)
        let id = try XCTUnwrap(focusFirstRow(app))
        chooseFromRowMenu(downs: 1, snap: "live-list/tvos-03a-row-menu")
        XCTAssertTrue(app.buttons[id].waitForNonExistence(timeout: 3), "row hidden")
        let showHidden = app.buttons["live_show_hidden"]
        XCTAssertTrue(showHidden.waitForExistence(timeout: 3), "Show hidden row in the category column")
        remote(.left)
        XCTAssertTrue(focus(showHidden, pressing: .down), "reachable with the remote")
        UITestSupport.snap("live-list/tvos-03-show-hidden", in: self)
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.buttons[id].waitForExistence(timeout: 3), "row restored")
        XCTAssertFalse(showHidden.exists)
    }

    /// Long OK → "Show in TV guide": the guide's panel shows that channel.
    @MainActor
    func testShowInGuideOpensThePanelOnTheChannel() throws {
        let app = UITestSupport.launch(["-uiScreen", "live"])
        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'channel_'"))
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 30))
        sleep(1)
        _ = try XCTUnwrap(focusFirstRow(app))
        for _ in 0..<3 { XCUIRemote.shared.press(.down); usleep(400_000) }
        sleep(1)
        let focused = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'channel_' AND hasFocus == true")).firstMatch
        let name = focused.label.components(separatedBy: ",").first ?? ""
        chooseFromRowMenu(downs: 6)
        let panel = app.descendants(matching: .any)["guide_panel"]
        XCTAssertTrue(panel.waitForExistence(timeout: 5), "guide")
        XCTAssertTrue(panel.staticTexts[name].waitForExistence(timeout: 3), "guide panel on \(name)")
        UITestSupport.snap("live-list/tvos-04-show-in-guide", in: self)
    }

    @MainActor
    private func remote(_ button: XCUIRemote.Button) {
        XCUIRemote.shared.press(button)
        sleep(1)
    }
}
