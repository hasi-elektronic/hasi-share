import XCTest

/// Apple TV flows driven with the Siri Remote (XCUIRemote): side menu, live layout, focus
/// navigation, player and Menu-button back rules.
final class TVFlowTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor private var remote: XCUIRemote { XCUIRemote.shared }

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
    func testHomeMenuLiveAndPlayer() throws {
        let app = UITestSupport.launch()
        XCTAssertTrue(app.buttons["menu_live"].waitForExistence(timeout: 30))
        sleep(2)
        UITestSupport.snap("tvos-02-home", in: self)

        // Back rule 3: Menu in content moves focus to the side menu (expands it).
        remote.press(.menu)
        sleep(1)
        UITestSupport.snap("tvos-03-side-menu-focused", in: self)

        // Down to "Live TV" and open it.
        remote.press(.down)
        sleep(1)
        remote.press(.select)
        sleep(2)
        remote.press(.right)
        sleep(1)
        UITestSupport.snap("tvos-04-live-layout", in: self)

        // Focus navigation inside the channel list (preview panel follows focus).
        remote.press(.right)
        sleep(1)
        remote.press(.down)
        sleep(1)
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
    }

    @MainActor
    func testPaywallAndSettings() throws {
        let app = UITestSupport.launch(["-uiScreen", "paywall"], trial: false)
        XCTAssertTrue(app.buttons["purchase_restore"].waitForExistence(timeout: 30))
        sleep(2)
        UITestSupport.snap("tvos-08-paywall", in: self)
        app.terminate()
        let settings = UITestSupport.launch(["-uiScreen", "settings"])
        XCTAssertTrue(settings.buttons["menu_settings"].waitForExistence(timeout: 30))
        sleep(2)
        UITestSupport.snap("tvos-09-settings", in: self)
    }
}
