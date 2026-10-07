import XCTest

/// Settings → About (Build 14): app name + version/build from the bundle, the maker (Hasi Elektronic).
final class IOSAboutTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testAboutShowsVersionAndMaker() throws {
        let app = UITestSupport.launch(["-uiScreen", "settings"])
        let about = app.buttons["settings_about"]
        XCTAssertTrue(about.waitForExistence(timeout: 30), "About row in Settings")
        if !about.isHittable { app.swipeUp() }
        about.tap()
        XCTAssertTrue(app.staticTexts["Hamdi Güncavdı"].waitForExistence(timeout: 5), "maker name")
        let version = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Version ' AND label CONTAINS '(Build '")).firstMatch
        XCTAssertTrue(version.exists, "version + build")
        XCTAssertTrue(app.images["about_logo"].exists || app.otherElements["about_logo"].exists || app.images["Hasi Elektronic"].exists, "logo")
        XCTAssertTrue(app.staticTexts["Hasi Elektronic"].exists)
        XCTAssertTrue(app.buttons["about_website"].exists, "website link")
        XCTAssertTrue(app.buttons["about_licenses"].exists, "licences row")
        sleep(1)
        UITestSupport.snap("about-ios", in: self)
    }
}
