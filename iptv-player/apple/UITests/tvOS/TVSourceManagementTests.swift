import XCTest

/// Build 16 (team A1) on Apple TV: accounts / QR pairing hidden (Welcome focuses "Add source"), source detail
/// with Edit + EPG URL, privacy policy as QR code + URL.
final class TVSourceManagementTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor private var remote: XCUIRemote { XCUIRemote.shared }

    /// tvOS reports the focus on the list cell (its label), not on the identified control inside it.
    @MainActor
    private func focused(_ app: XCUIApplication, _ label: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "hasFocus == true AND label BEGINSWITH %@", label)).firstMatch
    }

    @MainActor
    private func moveFocus(_ app: XCUIApplication, to label: String, pressing direction: XCUIRemote.Button = .down, limit: Int = 15) -> Bool {
        for _ in 0..<limit where !focused(app, label).exists {
            remote.press(direction)
            usleep(450_000)
        }
        return focused(app, label).exists
    }

    @MainActor
    func testWelcomeHasNoQRPairingAndFocusesAddSource() throws {
        let app = UITestSupport.launch(["-uiScreen", "pairing"], seed: false)
        let m3u = app.buttons["add_add_source_m3u"]
        XCTAssertTrue(m3u.waitForExistence(timeout: 20))
        sleep(1)
        XCTAssertFalse(app.buttons["add_add_source_qr"].exists, "QR pairing hidden (ACCOUNTS_ENABLED = NO)")
        XCTAssertFalse(app.staticTexts["pair_code"].exists, "the pairing debug route is ignored without accounts")
        XCTAssertTrue(m3u.hasFocus, "focus starts on the first add-source option")
        UITestSupport.snap("a1-tv-welcome", in: self)
    }

    @MainActor
    func testSourceDetailHasEditAndEpgUrl() throws {
        try UITestSupport.requireServed(UITestSupport.seedM3U)
        let app = UITestSupport.launch(["-uiScreen", "settings"])
        XCTAssertTrue(app.buttons["settings_sources"].waitForExistence(timeout: 30))
        sleep(1)
        XCTAssertTrue(moveFocus(app, to: "Sources"), "Sources row")
        remote.press(.select)
        XCTAssertTrue(app.buttons["settings_source_Demo TV"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["Add with phone (QR)"].exists, "no QR row in the sources list")
        sleep(1)
        XCTAssertTrue(moveFocus(app, to: "Demo TV", pressing: .up), "source row")
        remote.press(.select)
        XCTAssertTrue(app.buttons["source_edit"].waitForExistence(timeout: 10), "Edit row")
        XCTAssertTrue(app.buttons["source_epg_url"].exists, "EPG URL row")
        XCTAssertTrue(moveFocus(app, to: "Edit"), "Edit is focusable")
        UITestSupport.snap("a1-tv-source-detail", in: self)
        remote.press(.select)
        XCTAssertTrue(app.textFields["field_m3u_url"].waitForExistence(timeout: 10), "prefilled edit form")
        XCTAssertEqual(app.textFields["field_m3u_url"].value as? String, UITestSupport.seedM3U)
        XCTAssertTrue(app.buttons["action_connect"].exists)
        UITestSupport.snap("a1-tv-source-edit", in: self)
    }

    @MainActor
    func testPrivacyPolicyAsQRCode() throws {
        let app = UITestSupport.launch(["-uiScreen", "settings"])
        XCTAssertTrue(app.buttons["settings_advanced"].waitForExistence(timeout: 30))
        sleep(1)
        XCTAssertTrue(moveFocus(app, to: "Advanced"), "Advanced row")
        remote.press(.select)
        XCTAssertTrue(app.buttons["legal_privacy"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["Sign in with your phone"].exists, "no phone sign-in without accounts")
        XCTAssertTrue(moveFocus(app, to: "Privacy policy", limit: 30), "privacy row focusable")
        remote.press(.select)
        let url = app.staticTexts["legal_url"]
        XCTAssertTrue(url.waitForExistence(timeout: 5))
        XCTAssertTrue(url.label.contains("https://hasi-elektronic.de/datenschutz"), url.label)
        UITestSupport.snap("a1-tv-privacy-qr", in: self)
    }
}
