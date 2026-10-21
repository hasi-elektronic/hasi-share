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
        XCTAssertTrue(app.buttons["settings_sources"].waitForExistence(timeout: 30), "Settings open")
        // Build 17: the iCloud section pushes About below the fold (lazy list rows exist once scrolled to).
        for _ in 0..<4 where !(about.exists && about.isHittable) { app.swipeUp() }
        XCTAssertTrue(about.waitForExistence(timeout: 5), "About row in Settings")
        about.tap()
        XCTAssertTrue(app.staticTexts["Hamdi Güncavdı"].waitForExistence(timeout: 5), "maker name")
        let version = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Version ' AND label CONTAINS '(Build '")).firstMatch
        XCTAssertTrue(version.exists, "version + build")
        XCTAssertTrue(app.images["about_logo"].exists || app.otherElements["about_logo"].exists || app.images["Hasi Elektronic"].exists, "logo")
        XCTAssertTrue(app.staticTexts["Hasi Elektronic"].exists)
        XCTAssertTrue(app.buttons["about_website"].exists, "website link")
        XCTAssertTrue(app.staticTexts["about_privacy_icloud"].exists || app.descendants(matching: .any)["about_privacy_icloud"].exists,
                      "privacy note (Build 17)")
        // The privacy note (Build 17) pushes the licences row below the fold.
        for _ in 0..<3 where !app.buttons["about_licenses"].exists { app.swipeUp() }
        XCTAssertTrue(app.buttons["about_licenses"].exists, "licences row")
        sleep(1)
        UITestSupport.snap("about-ios", in: self)
    }
}
