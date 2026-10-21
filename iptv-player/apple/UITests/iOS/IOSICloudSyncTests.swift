import XCTest

/// Build 17: Settings → iCloud – "Sync with iCloud" switch + status row, and a source from another device that waits
/// for its iCloud Keychain secrets (never an error). UI tests use an in-memory iCloud store (`-uiCloudAccount`).
final class IOSICloudSyncTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    private func scrollTo(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<6 where !(element.exists && element.isHittable) { app.swipeUp() }
    }

    /// Taps the switch knob (the right end of the row).
    @MainActor
    private func flip(_ toggle: XCUIElement) {
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
    }

    @MainActor
    func testToggleAndStatusRow() throws {
        let app = UITestSupport.launch(["-uiScreen", "settings", "-uiCloudAccount", "yes"])
        let toggle = app.switches["settings_icloud_sync"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 30), "iCloud switch in Settings")
        scrollTo(toggle, in: app)
        XCTAssertEqual(toggle.value as? String, "1", "on by default when an iCloud account is signed in")
        let status = app.staticTexts["settings_icloud_status"]
        XCTAssertTrue(status.waitForExistence(timeout: 5))
        let synced = NSPredicate(format: "label BEGINSWITH 'Up to date' OR label BEGINSWITH 'On –'")
        expectation(for: synced, evaluatedWith: status)
        waitForExpectations(timeout: 10)
        UITestSupport.snap("icloud-on-ios", in: self)

        flip(toggle)
        XCTAssertEqual(toggle.value as? String, "0")
        XCTAssertTrue(status.label.hasPrefix("Off –"), "status: \(status.label)")
        UITestSupport.snap("icloud-off-ios", in: self)

        flip(toggle)
        XCTAssertEqual(toggle.value as? String, "1")
        expectation(for: synced, evaluatedWith: status)
        waitForExpectations(timeout: 10)
    }

    @MainActor
    func testNoAccountStatus() throws {
        let app = UITestSupport.launch(["-uiScreen", "settings"])
        let toggle = app.switches["settings_icloud_sync"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 30))
        scrollTo(toggle, in: app)
        XCTAssertEqual(toggle.value as? String, "0", "off without an iCloud account")
        XCTAssertTrue(app.staticTexts["settings_icloud_status"].label.hasPrefix("Off –"))
        flip(toggle)
        XCTAssertEqual(toggle.value as? String, "1", "can be switched on in advance")
        XCTAssertTrue(app.staticTexts["settings_icloud_status"].label.hasPrefix("No iCloud account"))
    }

    @MainActor
    func testSourceFromAnotherDeviceWaitsForICloudKeychain() throws {
        let app = UITestSupport.launch(["-uiCloudAccount", "yes", "-uiCloudSeedSource", "Wohnzimmer"])
        let gear = app.buttons["open_settings"]
        XCTAssertTrue(gear.waitForExistence(timeout: 30))
        gear.tap()
        let sources = app.buttons["settings_sources"]
        XCTAssertTrue(sources.waitForExistence(timeout: 10))
        sources.tap()
        let row = app.buttons["settings_source_Wohnzimmer"]
        XCTAssertTrue(row.waitForExistence(timeout: 10), "source from the other device listed")
        let waiting = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'Waiting for iCloud Keychain'")).firstMatch
        XCTAssertTrue(waiting.waitForExistence(timeout: 5), "waiting state, not an error")
        UITestSupport.snap("icloud-waiting-keychain-ios", in: self)
        row.tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'This source was added on another device'")).firstMatch
            .waitForExistence(timeout: 5), "explanation in the source detail")
    }
}
