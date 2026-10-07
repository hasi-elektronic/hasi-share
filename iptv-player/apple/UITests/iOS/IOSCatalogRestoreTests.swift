import XCTest

/// Build 14: the system deleted the catalog database (tvOS purgeable storage; simulated with the DEBUG launch
/// argument `-debugDeleteCatalogDB`). The relaunched app restores the source from the durable mirror without
/// asking for credentials, reloads its content and keeps the favorites. Runs in its own `-uiSandbox` (real SQLite
/// file, Keychain and UserDefaults under test-only names).
final class IOSCatalogRestoreTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testSourceAndFavoritesSurviveAPurgedDatabase() throws {
        let sandbox = ["-uiSandbox", "restore-ios"]
        let app = UITestSupport.launch(sandbox + ["-uiSeedLibrary", "-pref.quickStart", "NO"])
        XCTAssertTrue(app.buttons["tab_home"].waitForExistence(timeout: 30), "seeded source loaded")
        sleep(4)   // the mirror writes at most every 3 s
        XCUIDevice.shared.press(.home)   // background: final mirror flush
        sleep(2)
        app.terminate()

        let relaunched = XCUIApplication()
        relaunched.launchArguments = sandbox + ["-debugDeleteCatalogDB", "-uiTrial", "-pref.quickStart", "NO",
                                                "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        relaunched.launch()
        XCTAssertTrue(relaunched.buttons["tab_home"].waitForExistence(timeout: 15), "source restored: home, not the welcome screen")
        XCTAssertFalse(relaunched.buttons["add_add_source_m3u"].exists, "no credentials asked again")
        UITestSupport.snap("restore-ios-01-relaunched", in: self)

        IOSFlowTests.openSection("live", in: relaunched)
        let channel = relaunched.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'channel_'")).firstMatch
        XCTAssertTrue(channel.waitForExistence(timeout: 30), "content back after the background refresh")
        let favorites = relaunched.descendants(matching: .any)["live_section_favorites"]
        XCTAssertTrue(favorites.waitForExistence(timeout: 10), "favorites survived the purge")
        XCTAssertEqual(relaunched.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'live_favorite_'")).count, 2,
                       "both seeded favorite channels")
        UITestSupport.snap("restore-ios-02-live-favorites", in: self)
        relaunched.terminate()
    }
}
