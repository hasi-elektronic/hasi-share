import XCTest

/// Build 16 – Settings → "Calibrate audio sync": the bundled test clip plays through VLCKit, the value
/// changes live (10 ms steps), "Save" persists it across launches, and the player's performance overlay shows
/// it ("VLC calibration: +30 ms") while an HLS channel stays on AVPlayer (the calibration never routes).
final class IOSAVSyncCalibrationTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    private static let sandbox = "avsyncB"

    @MainActor
    func testCalibrationPlaysPersistsAndShowsInOverlay() throws {
        let app = UITestSupport.launch(["-uiSandbox", Self.sandbox, "-uiScreen", "settings", "-pref.quickStart", "NO"])
        let row = app.buttons["settings_avsync_calibration"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 30), "calibration row in Settings")
        row.tap()

        let engine = app.descendants(matching: .any)["avsync_engine"]
        XCTAssertTrue(engine.waitForExistence(timeout: 10), "calibration screen")
        XCTAssertEqual(engine.label, "VLCKit")
        let playing = NSPredicate(format: "value == 'playing'")
        expectation(for: playing, evaluatedWith: engine)
        waitForExpectations(timeout: 15)
        UITestSupport.snap("avsync-01-vlc-playing", in: self)

        let plus = app.buttons["avsync_value_plus"]
        for _ in 0..<3 { plus.tap() }
        XCTAssertEqual(app.staticTexts["avsync_value_value"].label, "+30 ms · audio later")

        // Reference: the same clip through AVPlayer, then back to VLCKit.
        app.buttons["avsync_reference"].tap()
        XCTAssertEqual(engine.label, "AVPlayer")
        expectation(for: playing, evaluatedWith: engine)
        waitForExpectations(timeout: 15)
        UITestSupport.snap("avsync-02-apple-reference", in: self)
        app.buttons["avsync_reference"].tap()
        XCTAssertEqual(engine.label, "VLCKit")

        app.buttons["avsync_save"].tap()
        XCTAssertTrue(app.staticTexts["avsync_saved"].waitForExistence(timeout: 3), "saved confirmation")
        UITestSupport.snap("avsync-03-saved", in: self)
        app.terminate()

        // Relaunch the same sandbox (no reset): the value is kept and shown by the perf overlay.
        let again = XCUIApplication()
        again.launchArguments = ["-uiSandbox", Self.sandbox, "-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-uiTrial",
                                 "-perfOverlay", "-uiScreen", "player", "-pref.quickStart", "NO"]
        again.launch()
        let overlay = again.descendants(matching: .any)["perf_overlay"]
        XCTAssertTrue(overlay.waitForExistence(timeout: 30), "player with perf overlay")
        let shows = NSPredicate(format: "label CONTAINS 'VLC calibration: +30 ms'")
        expectation(for: shows, evaluatedWith: overlay)
        waitForExpectations(timeout: 10)
        let onAVPlayer = NSPredicate(format: "label CONTAINS 'Engine: AVPlayer'")
        expectation(for: onAVPlayer, evaluatedWith: overlay)
        waitForExpectations(timeout: 20)
        UITestSupport.snap("avsync-04-overlay", in: self)
    }
}
