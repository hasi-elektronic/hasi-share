import XCTest

/// Build 17 on Apple TV: Settings → iCloud – one focusable row (the switch) with the status below it, and a source
/// from the iPhone that waits for its iCloud Keychain secrets.
final class TVICloudSyncTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor private var remote: XCUIRemote { XCUIRemote.shared }

    @MainActor
    private func focused(_ app: XCUIApplication, _ label: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "hasFocus == true AND label BEGINSWITH %@", label)).firstMatch
    }

    @MainActor
    func testToggleAndStatusRow() throws {
        let app = UITestSupport.launch(["-uiScreen", "settings", "-uiCloudAccount", "yes"])
        XCTAssertTrue(app.buttons["settings_sources"].waitForExistence(timeout: 30))
        sleep(1)
        for _ in 0..<12 where !focused(app, "Sync with iCloud").exists { remote.press(.down); usleep(500_000) }
        XCTAssertTrue(focused(app, "Sync with iCloud").exists, "the switch is one focusable row")
        let toggle = app.switches["settings_icloud_sync"]
        XCTAssertEqual(toggle.value as? String, "1", "on by default with an iCloud account")
        let status = app.staticTexts["settings_icloud_status"]
        let synced = NSPredicate(format: "label BEGINSWITH 'Up to date' OR label BEGINSWITH 'On –'")
        expectation(for: synced, evaluatedWith: status)
        waitForExpectations(timeout: 10)
        UITestSupport.snap("icloud-on-tvos", in: self)

        remote.press(.select)
        expectation(for: NSPredicate(format: "value == '0'"), evaluatedWith: toggle)
        waitForExpectations(timeout: 5)
        XCTAssertTrue(status.label.hasPrefix("Off –"), "status: \(status.label)")
        UITestSupport.snap("icloud-off-tvos", in: self)
        remote.press(.select)
        expectation(for: NSPredicate(format: "value == '1'"), evaluatedWith: toggle)
        waitForExpectations(timeout: 5)
    }

    @MainActor
    func testSourceFromAnotherDeviceWaitsForICloudKeychain() throws {
        let app = UITestSupport.launch(["-uiScreen", "settings", "-uiCloudAccount", "yes", "-uiCloudSeedSource", "Wohnzimmer"])
        XCTAssertTrue(app.buttons["settings_sources"].waitForExistence(timeout: 30))
        sleep(1)
        for _ in 0..<15 where !focused(app, "Sources").exists { remote.press(.down); usleep(450_000) }
        XCTAssertTrue(focused(app, "Sources").exists, "Sources row")
        remote.press(.select)
        XCTAssertTrue(app.buttons["settings_source_Wohnzimmer"].waitForExistence(timeout: 10), "source from the iPhone listed")
        let waiting = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'Waiting for iCloud Keychain'")).firstMatch
        XCTAssertTrue(waiting.waitForExistence(timeout: 5), "waiting state, not an error")
        UITestSupport.snap("icloud-waiting-keychain-tvos", in: self)
    }
}
