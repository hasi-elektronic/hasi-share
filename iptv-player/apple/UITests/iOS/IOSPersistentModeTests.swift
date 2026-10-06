import XCTest

/// Runs the app WITHOUT `-uiTestReset`: real SQLite file, real Keychain, real UserDefaults –
/// the state a user (or a manual simulator run) sees. Guards against flows that only work
/// with the in-memory test stores.
///
/// The persisted state survives between runs (only `xcrun simctl erase`/uninstall clears it), so
/// the test handles both states a user can be in:
/// - fresh install (no source): Welcome → M3U → summary → home; the source stays, so the next run
///   starts non-fresh;
/// - existing source(s): home → Settings → "M3U link" → summary → back in Settings, then the
///   added source is deleted again (Keychain + DB) so repeated runs don't pile up sources.
final class IOSPersistentModeTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testAddSourceInPersistentMode() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTrial", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()

        let welcomeM3U = app.buttons["add_add_source_m3u"]
        let gear = app.buttons["open_settings"]
        let start = Date()
        while !welcomeM3U.exists && !gear.exists && Date().timeIntervalSince(start) < 15 {
            _ = welcomeM3U.waitForExistence(timeout: 0.5)
        }
        UITestSupport.snap("persist-01-start", in: self)

        if welcomeM3U.exists {
            // Fresh install: onboarding.
            XCTAssertTrue(welcomeM3U.isHittable, "M3U button should be tappable")
            welcomeM3U.tap()
            try addM3U(app, name: "Persist TV")
            XCTAssertTrue(app.buttons["tab_home"].waitForExistence(timeout: 10), "home with the header tabs")
        } else {
            // Existing source from an earlier run / real use: add another one from Settings.
            XCTAssertTrue(gear.exists, "neither welcome nor home appeared")
            XCTAssertTrue(app.buttons["tab_home"].exists, "home with the header tabs")
            gear.tap()
            let addM3ULink = app.buttons["settings_add_m3u"]
            XCTAssertTrue(addM3ULink.waitForExistence(timeout: 10), "settings should list 'M3U link'")
            addM3ULink.tap()
            let name = "Persist TV 2"
            try addM3U(app, name: name) {
                // Adding a further source must not swap the screen behind the settings sheet to
                // the welcome/onboarding screen (only the first source is an onboarding flow).
                XCTAssertFalse(app.buttons["add_add_source_m3u"].exists, "welcome screen must not replace home behind settings")
            }

            // Back in Settings: the new source is listed; delete it again (bounded state).
            let rows = app.buttons.matching(identifier: "settings_source_\(name)")
            let row = rows.firstMatch
            XCTAssertTrue(row.waitForExistence(timeout: 10), "added source should be listed in settings")
            let before = rows.count
            row.tap()
            let delete = app.buttons["source_delete"]
            XCTAssertTrue(delete.waitForExistence(timeout: 5))
            delete.tap()
            let confirm = app.buttons.matching(identifier: "source_delete_confirm").firstMatch
            XCTAssertTrue(confirm.waitForExistence(timeout: 5), "delete confirmation")
            confirm.tap()
            let gone = NSPredicate(format: "count == %d", before - 1)
            let removed = XCTNSPredicateExpectation(predicate: gone, object: rows)
            XCTAssertEqual(XCTWaiter.wait(for: [removed], timeout: 10), .completed, "deleted source should disappear from settings")
            app.buttons["settings_close"].tap()
            XCTAssertTrue(app.buttons["tab_home"].waitForExistence(timeout: 10), "home with the header tabs")
        }
    }

    /// Fills the M3U form (already on screen), connects, runs `atSummary` and confirms the summary.
    @MainActor
    private func addM3U(_ app: XCUIApplication, name: String, atSummary: () -> Void = {}) throws {
        let url = app.textFields["field_m3u_url"]
        XCTAssertTrue(url.waitForExistence(timeout: 5), "tapping M3U should open the form")
        app.textFields["field_name"].tap()
        app.textFields["field_name"].typeText(name)
        url.tap()
        url.typeText(UITestSupport.seedM3U)
        app.buttons["action_connect"].tap()

        let done = app.buttons["add_source_continue"]
        let ok = done.waitForExistence(timeout: 30)
        UITestSupport.snap("persist-02-after-connect", in: self)
        XCTAssertTrue(ok, "source should load in persistent mode")
        atSummary()
        done.tap()
    }
}
