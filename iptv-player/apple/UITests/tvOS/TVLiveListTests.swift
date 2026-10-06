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
}
