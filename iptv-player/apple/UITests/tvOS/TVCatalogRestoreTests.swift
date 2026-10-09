import XCTest

/// Build 14 (owner report: "Apple TV deletes the whole Xtream code"): tvOS purges Application Support, i.e. the
/// catalog database – simulated with the DEBUG launch argument `-debugDeleteCatalogDB`. The relaunched app restores
/// the source from the durable mirror (UserDefaults + Keychain) without asking for credentials, reloads the
/// content and keeps the favorites. Runs in its own `-uiSandbox` (real SQLite file, Keychain, UserDefaults).
final class TVCatalogRestoreTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor private var remote: XCUIRemote { XCUIRemote.shared }

    @MainActor
    func testSourceAndFavoritesSurviveAPurgedDatabase() throws {
        let sandbox = ["-uiSandbox", "restore-tvos"]
        let app = UITestSupport.launch(sandbox + ["-uiSeedLibrary", "-pref.quickStart", "NO"])
        XCTAssertTrue(app.tabBars.buttons["Live TV"].waitForExistence(timeout: 30), "seeded source loaded")
        sleep(4)   // the mirror writes at most every 3 s
        remote.press(.home)   // background: final mirror flush
        sleep(2)
        app.terminate()

        let relaunched = XCUIApplication()
        relaunched.launchArguments = sandbox + ["-debugDeleteCatalogDB", "-uiTrial", "-pref.quickStart", "NO",
                                                "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        relaunched.launch()
        let liveTab = relaunched.tabBars.buttons["Live TV"]
        XCTAssertTrue(liveTab.waitForExistence(timeout: 15), "source restored: tab bar, not the welcome screen")
        XCTAssertFalse(relaunched.buttons["add_add_source_m3u"].exists, "no credentials asked again")
        UITestSupport.snap("restore-tvos-01-relaunched", in: self)

        // Into the tab bar, then right to Live TV (selection follows focus).
        for _ in 0..<3 { remote.press(.up); usleep(400_000) }
        for _ in 0..<6 where !liveTab.hasFocus { remote.press(.right); usleep(500_000) }
        XCTAssertTrue(liveTab.hasFocus, "Live TV tab focused")
        let favorites = relaunched.descendants(matching: .any)["live_section_favorites"]
        XCTAssertTrue(favorites.waitForExistence(timeout: 30), "content back after the refresh, favorites survived")
        XCTAssertEqual(relaunched.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'live_favorite_'")).count, 2,
                       "both seeded favorite channels")
        UITestSupport.snap("restore-tvos-02-live-favorites", in: self)
        relaunched.terminate()
    }
}
