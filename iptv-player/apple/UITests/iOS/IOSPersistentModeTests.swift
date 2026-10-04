import XCTest

/// Runs the app WITHOUT `-uiTestReset`: real SQLite file, real Keychain, real UserDefaults –
/// the state a user (or a manual simulator run) sees. Guards against flows that only work
/// with the in-memory test stores.
final class IOSPersistentModeTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testAddSourceInPersistentMode() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTrial", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()

        let m3u = app.buttons["add_add_source_m3u"]
        XCTAssertTrue(m3u.waitForExistence(timeout: 15), "welcome screen should show the add-source buttons")
        UITestSupport.snap("persist-01-welcome", in: self)
        XCTAssertTrue(m3u.isHittable, "M3U button should be tappable")
        m3u.tap()

        let url = app.textFields["field_m3u_url"]
        XCTAssertTrue(url.waitForExistence(timeout: 5), "tapping M3U should open the form")
        app.textFields["field_name"].tap()
        app.textFields["field_name"].typeText("Persist TV")
        url.tap()
        url.typeText(UITestSupport.seedM3U)
        app.buttons["action_connect"].tap()

        let done = app.buttons["add_source_continue"]
        let ok = done.waitForExistence(timeout: 30)
        UITestSupport.snap("persist-02-after-connect", in: self)
        XCTAssertTrue(ok, "source should load in persistent mode")
        done.tap()
        XCTAssertTrue(app.tabBars.buttons["Live TV"].waitForExistence(timeout: 10))
    }
}
