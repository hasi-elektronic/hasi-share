import XCTest

/// iPhone flows + screenshots: welcome → add M3U source → live list → player; paywall; settings.
final class IOSFlowTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testOnboardingAddSourceLiveAndPlayer() throws {
        let app = UITestSupport.launch(seed: false)
        XCTAssertTrue(app.buttons["add_add_source_m3u"].waitForExistence(timeout: 15))
        UITestSupport.snap("ios-01-welcome", in: self)

        app.buttons["add_add_source_m3u"].tap()
        let url = app.textFields["field_m3u_url"]
        XCTAssertTrue(url.waitForExistence(timeout: 5))
        UITestSupport.snap("ios-02-add-source-form", in: self)
        app.textFields["field_name"].tap()
        app.textFields["field_name"].typeText("Demo TV")
        url.tap()
        url.typeText(UITestSupport.seedM3U)
        UITestSupport.snap("ios-03-add-source-filled", in: self)
        app.buttons["action_connect"].tap()

        let done = app.buttons["add_source_continue"]
        XCTAssertTrue(done.waitForExistence(timeout: 30), "source should load")
        UITestSupport.snap("ios-04-source-added", in: self)
        done.tap()

        let liveTab = app.tabBars.buttons["Live TV"]
        XCTAssertTrue(liveTab.waitForExistence(timeout: 10))
        UITestSupport.snap("ios-05-home", in: self)
        liveTab.tap()
        let firstChannel = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'channel_'")).firstMatch
        XCTAssertTrue(firstChannel.waitForExistence(timeout: 10))
        UITestSupport.snap("ios-06-live-channels", in: self)

        firstChannel.tap()
        XCTAssertTrue(app.otherElements["video_surface"].waitForExistence(timeout: 10))
        sleep(8)   // let HLS start
        app.otherElements["video_surface"].tap()
        UITestSupport.snap("ios-07-player-playing", in: self)
        XCUIDevice.shared.orientation = .landscapeLeft
        sleep(2)
        UITestSupport.snap("ios-08-player-landscape", in: self)
        XCUIDevice.shared.orientation = .portrait
    }

    @MainActor
    func testPaywall() throws {
        let app = UITestSupport.launch(["-uiScreen", "paywall"], trial: false)
        XCTAssertTrue(app.buttons["purchase_restore"].waitForExistence(timeout: 15))
        sleep(2)
        UITestSupport.snap("ios-09-paywall", in: self)
    }

    @MainActor
    func testSettings() throws {
        let app = UITestSupport.launch(["-uiScreen", "settings"])
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 30))
        sleep(1)
        UITestSupport.snap("ios-10-settings", in: self)
    }

    @MainActor
    func testLockedPlaybackOpensPaywall() throws {
        let app = UITestSupport.launch(["-uiScreen", "live"], trial: false)
        let firstChannel = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'channel_'")).firstMatch
        XCTAssertTrue(firstChannel.waitForExistence(timeout: 30))
        firstChannel.tap()
        XCTAssertTrue(app.buttons["purchase_restore"].waitForExistence(timeout: 10), "locked → paywall")
        UITestSupport.snap("ios-11-locked-paywall", in: self)
    }
}
