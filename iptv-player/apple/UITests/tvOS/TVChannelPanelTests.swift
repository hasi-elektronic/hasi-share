import XCTest

/// Apple TV in-player channel panel (SCREENS §3.7): OK on the live picture opens it on the playing
/// channel (focused), OK on another row zaps and closes it, Menu closes it; opened from the top row
/// the overlay does not stay pinned afterwards.
final class TVChannelPanelTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor private var remote: XCUIRemote { XCUIRemote.shared }

    @MainActor
    private func press(_ button: XCUIRemote.Button, _ times: Int = 1) {
        for _ in 0..<times {
            remote.press(button)
            usleep(500_000)
        }
    }

    /// Live player with the overlay hidden.
    @MainActor
    private func launchLivePlayer() -> XCUIApplication {
        let app = UITestSupport.launch(["-uiScreen", "player"])
        XCTAssertTrue(app.otherElements["video_surface"].waitForExistence(timeout: 30))
        if !app.buttons["player_play_pause"].waitForNonExistence(timeout: 20) { press(.menu) }
        sleep(1)
        return app
    }

    @MainActor
    func testChannelPanelOK() throws {
        let app = launchLivePlayer()
        let panel = app.descendants(matching: .any)["player_channel_panel"]
        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'panel_channel_'"))

        press(.select)   // overlay hidden: OK = channel panel
        XCTAssertTrue(panel.waitForExistence(timeout: 3), "OK opens the channel panel")
        sleep(1)
        let current = rows.matching(NSPredicate(format: "selected == true")).firstMatch
        XCTAssertTrue(current.exists, "playing channel marked")
        XCTAssertTrue(current.hasFocus, "focus on the playing channel")
        XCTAssertTrue(app.buttons["player_channel_category"].exists, "category picker on top")
        XCTAssertFalse(app.buttons["player_close"].exists, "no overlay under the panel")
        UITestSupport.snap("channel-panel/tvos-01-open", in: self)

        // ▲ from the first row reaches the category picker; OK lists the categories.
        press(.up)
        press(.select)
        let all = app.descendants(matching: .any).matching(NSPredicate(format: "label == 'All'")).firstMatch
        XCTAssertTrue(all.waitForExistence(timeout: 3), "category menu")
        UITestSupport.snap("channel-panel/tvos-01b-categories", in: self)
        press(.menu)   // closes the menu only
        XCTAssertTrue(all.waitForNonExistence(timeout: 3))
        XCTAssertTrue(panel.exists)
        sleep(1)
        UITestSupport.snap("channel-panel/tvos-01c-menu-closed", in: self)
        press(.down)   // back into the list

        // Menu closes only the panel.
        press(.menu)
        XCTAssertTrue(panel.waitForNonExistence(timeout: 3), "Menu closes the panel")
        XCTAssertTrue(app.otherElements["video_surface"].exists, "player stays")

        // OK again, ▼ to the next row, OK zaps: the panel closes, the player stays, the title changes.
        press(.select)
        XCTAssertTrue(panel.waitForExistence(timeout: 3))
        sleep(1)
        press(.down)
        let target = rows.matching(NSPredicate(format: "hasFocus == true")).firstMatch
        XCTAssertTrue(target.exists)
        XCTAssertFalse(target.isSelected, "▼ moved to another channel")
        var parts = target.label.components(separatedBy: ", ")   // "12, Name, Programme"
        if let first = parts.first, Int(first) != nil { parts.removeFirst() }
        let name = parts.first ?? ""
        press(.select)
        XCTAssertTrue(panel.waitForNonExistence(timeout: 3), "the choice closes the panel")
        XCTAssertTrue(app.otherElements["video_surface"].exists)
        sleep(2)
        press(.right)   // live: ▶ shows the overlay with the title
        XCTAssertTrue(app.buttons["player_close"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts[name].exists, "now playing \(name)")
        UITestSupport.snap("channel-panel/tvos-02-zapped", in: self)

        // From the top row: overlay → ▲ → ▶… to the channel list → OK → panel; Menu → nothing pinned.
        // (Top-row buttons do not report focus to XCUITest: walk to the end – "Previous channel",
        // present after the zap – and one step back.)
        press(.up)
        press(.right, 8)
        press(.left)
        XCTAssertTrue(app.buttons["player_close"].exists, "overlay (top row) still shown: OK goes to the list button")
        press(.select)
        XCTAssertTrue(panel.waitForExistence(timeout: 3), "panel from the top row")
        press(.menu)
        XCTAssertTrue(panel.waitForNonExistence(timeout: 3))
        sleep(5)
        XCTAssertFalse(app.buttons["player_close"].exists, "no overlay left pinned after the panel")
    }
}
