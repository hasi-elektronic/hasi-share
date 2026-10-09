import XCTest

/// Settings → About (Build 14) on Apple TV: last Settings row, version/build and maker; rows scroll with focus.
final class TVAboutTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor private var remote: XCUIRemote { XCUIRemote.shared }

    /// tvOS reports the focus on the list cell (label of the row), not on the identified button inside it.
    @MainActor
    private func focusedRow(_ app: XCUIApplication, _ label: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "hasFocus == true AND label BEGINSWITH %@", label)).firstMatch
    }

    @MainActor
    func testAboutShowsVersionAndMaker() throws {
        let app = UITestSupport.launch(["-uiScreen", "settings"])
        XCTAssertTrue(app.buttons["settings_about"].waitForExistence(timeout: 30), "About row in Settings")
        sleep(1)
        for _ in 0..<15 where !focusedRow(app, "About").exists { remote.press(.down); usleep(500_000) }
        XCTAssertTrue(focusedRow(app, "About").exists, "About reachable (last row)")
        remote.press(.select)
        XCTAssertTrue(app.staticTexts["Hamdi Güncavdı"].waitForExistence(timeout: 5), "maker name")
        let version = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Version ' AND label CONTAINS '(Build '")).firstMatch
        XCTAssertTrue(version.exists, "version + build")
        sleep(1)
        UITestSupport.snap("about-tvos", in: self)
        // One focusable control per row; the page scrolls with the focus down to the licences row.
        for _ in 0..<8 where !focusedRow(app, "Open-source licenses").exists { remote.press(.down); usleep(500_000) }
        XCTAssertTrue(focusedRow(app, "Open-source licenses").exists, "licences row focusable")
        UITestSupport.snap("about-tvos-licences-row", in: self)
    }
}
