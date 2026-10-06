import XCTest

/// Apple TV flows driven with the Siri Remote (XCUIRemote): top tab bar, EPG list focus
/// navigation, player, Menu-button back rules, detail screen and the Xtream form.
final class TVFlowTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor private var remote: XCUIRemote { XCUIRemote.shared }

    /// Presses `direction` until `element` has focus (max `limit` presses).
    @MainActor
    private func focus(_ element: XCUIElement, pressing direction: XCUIRemote.Button, limit: Int = 12) -> Bool {
        for _ in 0..<limit {
            if element.exists && element.hasFocus { return true }
            remote.press(direction)
            usleep(500_000)
        }
        return element.exists && element.hasFocus
    }

    @MainActor
    func testWelcome() throws {
        let app = UITestSupport.launch(seed: false)
        XCTAssertTrue(app.buttons["add_add_source_m3u"].waitForExistence(timeout: 15))
        UITestSupport.snap("tvos-01-welcome", in: self)
    }

    @MainActor
    func testPairingQRCode() throws {
        let app = UITestSupport.launch(["-uiScreen", "pairing"], seed: false)
        XCTAssertTrue(app.staticTexts["pair_code"].waitForExistence(timeout: 20), "needs a reachable backend (DEV_BACKEND_URL)")
        sleep(1)
        UITestSupport.snap("tvos-10-pairing-qr", in: self)
    }

    @MainActor
    func testHomeTabsLiveAndPlayer() throws {
        let app = UITestSupport.launch(["-uiSeedLibrary"])
        let liveTab = app.tabBars.buttons["Live TV"]
        XCTAssertTrue(liveTab.waitForExistence(timeout: 30), "top tab bar")
        XCTAssertTrue(app.buttons["hero_play"].waitForExistence(timeout: 10), "home hero")
        sleep(3)
        UITestSupport.snap("tvos-02-home", in: self)
        remote.press(.down)
        sleep(1)
        remote.press(.down)
        sleep(1)
        UITestSupport.snap("tvos-02b-home-rows", in: self)

        // Back rule: Menu in content moves focus up to the tab bar.
        remote.press(.menu)
        sleep(1)
        XCTAssertTrue(app.tabBars.buttons["Home"].hasFocus, "focus should be on the Home tab")
        UITestSupport.snap("tvos-03-tab-bar-focused", in: self)

        // Home → Movies → Series → Live TV (selection follows focus), down into the channel list.
        XCTAssertTrue(focus(liveTab, pressing: .right, limit: 5))
        sleep(2)
        let firstCard = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'channel_'")).firstMatch
        XCTAssertTrue(firstCard.waitForExistence(timeout: 10))
        remote.press(.down)   // into the content (category column or list)
        sleep(1)
        let focusedRow = app.buttons.matching(NSPredicate(format: "(identifier BEGINSWITH 'channel_' OR identifier BEGINSWITH 'live_favorite_') AND hasFocus == true"))
        for _ in 0..<4 where focusedRow.count == 0 {
            remote.press(.right)   // category column → channel list
            sleep(1)
        }
        XCTAssertEqual(focusedRow.count, 1, "a channel row has the focus")
        UITestSupport.snap("tvos-04-live-list", in: self)
        remote.press(.down)
        sleep(1)
        UITestSupport.snap("tvos-05-live-focus-moved", in: self)

        remote.press(.select)
        XCTAssertTrue(app.otherElements["video_surface"].waitForExistence(timeout: 10))
        sleep(8)
        UITestSupport.snap("tvos-06-player", in: self)
        // Back rule 1: Menu hides the overlay, then leaves the player.
        remote.press(.menu)
        sleep(1)
        remote.press(.menu)
        sleep(2)
        XCTAssertFalse(app.otherElements["video_surface"].exists)
        UITestSupport.snap("tvos-07-back-to-list", in: self)

        // Back rules: content → tab bar; tab bar (not Home) → Home. (The overlay may already have
        // auto-hidden, so the second Menu above can have moved focus to the tab bar already.)
        if !liveTab.hasFocus {
            remote.press(.menu)
            sleep(1)
        }
        XCTAssertTrue(liveTab.hasFocus, "Menu in content → tab bar")
        remote.press(.menu)
        sleep(2)
        XCTAssertTrue(app.tabBars.buttons["Home"].hasFocus, "Menu on the tab bar → Home")
        XCTAssertTrue(app.buttons["hero_play"].waitForExistence(timeout: 5), "Home content shown")
    }

    /// Live player: ▲ shows the channel info card with ⭐ focused; OK adds the favorite (no dialog,
    /// undo toast); after Back the Live grid's first section has the channel (spec §2).
    @MainActor
    func testUpArrowInfoCardFavorite() throws {
        let app = UITestSupport.launch(["-uiScreen", "player"])
        let surface = app.otherElements["video_surface"]
        XCTAssertTrue(surface.waitForExistence(timeout: 30))
        // The overlay hides 3 s after playback starts; ▲ with the overlay shown moves its focus.
        if !app.buttons["player_play_pause"].waitForNonExistence(timeout: 20) {
            remote.press(.menu)
            sleep(1)
        }
        remote.press(.up)
        XCTAssertTrue(app.otherElements["player_info_card"].waitForExistence(timeout: 3), "▲ = channel info")
        let star = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'fav_'")).firstMatch
        XCTAssertTrue(star.waitForExistence(timeout: 2))
        sleep(1)
        XCTAssertTrue(star.hasFocus, "⭐ has the focus")
        XCTAssertEqual(star.label, "Add to favorites")
        let channelId = try XCTUnwrap(star.identifier.components(separatedBy: ":live:").last)
        UITestSupport.snap("fav-tvos-01-info-card", in: self)

        remote.press(.select)
        XCTAssertTrue(app.otherElements["undo_toast"].waitForExistence(timeout: 2), "undo toast")
        XCTAssertEqual(star.label, "Remove from favorites")
        UITestSupport.snap("fav-tvos-02-info-card-favorite", in: self)

        remote.press(.menu)   // closes the card
        sleep(1)
        XCTAssertFalse(app.otherElements["player_info_card"].exists)
        remote.press(.menu)   // leaves the player
        XCTAssertTrue(surface.waitForNonExistence(timeout: 5))
        let header = app.descendants(matching: .any)["live_section_favorites"]
        let favCard = app.buttons["live_favorite_\(channelId)"]
        XCTAssertTrue(header.waitForExistence(timeout: 5), "\"Favorites\" section")
        XCTAssertTrue(favCard.exists, "channel in the first section")
        XCTAssertLessThan(favCard.frame.minY, app.descendants(matching: .any)["live_section_all"].frame.minY)
        sleep(1)
        UITestSupport.snap("fav-tvos-03-live-favorites-first", in: self)
    }

    @MainActor
    func testGuideFocusAndPanel() throws {
        let app = UITestSupport.launch(["-uiScreen", "guide"])
        XCTAssertTrue(app.otherElements["guide_panel"].waitForExistence(timeout: 30) || app.scrollViews["guide_panel"].waitForExistence(timeout: 5),
                      "guide side panel")
        sleep(2)
        remote.press(.down)
        sleep(1)
        remote.press(.down)
        sleep(1)
        UITestSupport.snap("tvos-13-guide", in: self)
        remote.press(.down)
        sleep(1)
        remote.press(.right)
        sleep(2)
        UITestSupport.snap("tvos-14-guide-focus-moved", in: self)
    }

    @MainActor
    func testMovieDetail() throws {
        let app = UITestSupport.launch(["-uiScreen", "movieDetail", "-uiSeedLibrary"])
        XCTAssertTrue(app.buttons["detail_play"].waitForExistence(timeout: 30))
        sleep(3)
        UITestSupport.snap("tvos-11-movie-detail", in: self)
    }

    @MainActor
    func testPaywallAndSettings() throws {
        let app = UITestSupport.launch(["-uiScreen", "paywall"], trial: false)
        XCTAssertTrue(app.buttons["purchase_restore"].waitForExistence(timeout: 30))
        sleep(2)
        UITestSupport.snap("tvos-08-paywall", in: self)
        app.terminate()
        let settings = UITestSupport.launch(["-uiScreen", "settings"])
        XCTAssertTrue(settings.tabBars.buttons["Settings"].waitForExistence(timeout: 30))
        sleep(2)
        UITestSupport.snap("tvos-09-settings", in: self)
    }

    /// Regression (TestFlight): every Xtream field – incl. the password – must be focusable and
    /// editable with the remote (a Form row focuses only one control).
    @MainActor
    func testXtreamFormTyping() throws {
        let app = UITestSupport.launch(["-uiScreen", "addXtream"], seed: false)
        let server = app.textFields["field_server"]
        XCTAssertTrue(server.waitForExistence(timeout: 15))
        let fields: [(XCUIElement, String)] = [
            (server, "http://example.com:8080"),
            (app.textFields["field_username"], "demo"),
            (app.secureTextFields["field_password"], "secret"),
        ]
        for (field, text) in fields {
            XCTAssertTrue(focus(field, pressing: .down), "\(field.identifier) should get focus")
            remote.press(.select)
            sleep(2)
            app.typeText(text)
            sleep(1)
            remote.press(.menu)   // leave the keyboard, keep the text
            sleep(2)
        }
        XCTAssertEqual(server.value as? String, "http://example.com:8080")
        XCTAssertEqual(app.textFields["field_username"].value as? String, "demo")
        let password = app.secureTextFields["field_password"].value as? String ?? ""
        XCTAssertEqual(password.count, 6, "password typed (masked)")
        UITestSupport.snap("tvos-12-xtream-form", in: self)
    }
}
