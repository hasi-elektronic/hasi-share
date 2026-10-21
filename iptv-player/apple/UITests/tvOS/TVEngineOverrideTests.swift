import XCTest

/// Apple TV: Settings → Player engine (CONTRACT §6.1 rule −1) and "Reset sync" in the player's Sync panel,
/// remote only. Engine and delays read from the performance overlay.
final class TVEngineOverrideTests: XCTestCase {
    @MainActor private var remote: XCUIRemote { XCUIRemote.shared }

    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    private func press(_ button: XCUIRemote.Button, _ times: Int = 1) {
        for _ in 0..<times {
            remote.press(button)
            usleep(400_000)
        }
    }

    @MainActor
    private func perf(_ app: XCUIApplication) -> String {
        let overlay = app.descendants(matching: .any)["perf_overlay"]
        return overlay.exists ? overlay.label : ""
    }

    @MainActor
    private func waitPerf(_ app: XCUIApplication, contains parts: [String], timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if parts.allSatisfy(perf(app).contains) { return true }
            usleep(250_000)
        }
        return false
    }

    /// Live player: ▶ shows the overlay, ▲ top row (close), ▶ Audio, OK, ▼ to the last row (Sync), OK.
    @MainActor
    private func openSyncPanel(_ app: XCUIApplication) {
        // The player opens with the overlay, which auto-hides after 3 s: wait for that, then ▶ shows it fresh
        // (play/pause focused) so it cannot hide under the next presses.
        _ = app.buttons["player_close"].waitForNonExistence(timeout: 8)
        press(.right)
        XCTAssertTrue(app.buttons["player_close"].waitForExistence(timeout: 3), "overlay shown")
        press(.up)
        press(.right)
        press(.select)
        let syncRow = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'Audio sync'")).firstMatch
        XCTAssertTrue(syncRow.waitForExistence(timeout: 5), "Sync row in the Audio menu")
        press(.down, 6)   // the last row is Sync
        press(.select)
        XCTAssertTrue(app.descendants(matching: .any)["audio_sync_panel"].waitForExistence(timeout: 5), "sync panel")
    }

    @MainActor
    func testAppleOverridePlaysHLSOnAVPlayer() throws {
        let app = UITestSupport.launch(["-uiScreen", "player", "-perfOverlay", "-playerEngine", "apple"])
        XCTAssertTrue(app.otherElements["video_surface"].waitForExistence(timeout: 30))
        XCTAssertTrue(waitPerf(app, contains: ["Engine: AVPlayer", "forced", "Buffer: ok"], timeout: 40),
                      "AVPlayer forced: \(perf(app))")
        openSyncPanel(app)
        XCTAssertTrue(app.staticTexts["audio_sync_apple_engine"].exists, "one line instead of steppers")
        XCTAssertFalse(app.descendants(matching: .any)["player_audio_sync_delay"].exists, "no steppers on the Apple engine")
        let reset = app.buttons["audio_sync_reset"]
        XCTAssertTrue(reset.waitForExistence(timeout: 3))
        sleep(1)
        XCTAssertTrue(reset.hasFocus, "Reset sync focused")
        UITestSupport.snap("engine-override/tvos-apple-sync-panel", in: self)
    }

    @MainActor
    func testAppleOverrideMKVShowsVLCHint() throws {
        try VLCTestSupport.requireServer()
        let app = UITestSupport.launch(["-uiScreen", "movieDetail", "-seedM3U", VLCTestSupport.movieM3U, "-seedName", "Movies",
                                        "-playerEngine", "apple"], seed: false)
        let play = app.buttons["detail_play"]
        XCTAssertTrue(play.waitForExistence(timeout: 30))
        sleep(2)
        for _ in 0..<6 where !play.hasFocus {
            remote.press(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'fav_'")).firstMatch.hasFocus ? .left : .down)
            sleep(1)
        }
        remote.press(.select)
        let hint = app.staticTexts["error_hint"]
        XCTAssertTrue(hint.waitForExistence(timeout: 15), "error card with hint")
        XCTAssertTrue(hint.label.contains("needs the VLC engine"), hint.label)
        XCTAssertTrue(hint.label.contains("Automatic"), hint.label)
        UITestSupport.snap("engine-override/tvos-apple-mkv-error", in: self)
    }

    @MainActor
    func testVLCOverridePlaysHLSOnVLC() throws {
        let app = UITestSupport.launch(["-uiScreen", "player", "-perfOverlay", "-playerEngine", "vlc"])
        XCTAssertTrue(app.otherElements["video_surface"].waitForExistence(timeout: 30))
        XCTAssertTrue(waitPerf(app, contains: ["Engine: VLCKit", "forced", "Buffer: ok"], timeout: 40), "VLCKit forced: \(perf(app))")
        VLCTestSupport.assertNoErrorCard(app, "HLS on VLC")
        UITestSupport.snap("engine-override/tvos-vlc-hls", in: self)
    }

    /// Automatic: ◀▶ set a channel delay (HLS moves to VLCKit) + the VLC calibration, ▼ to "Reset sync", OK →
    /// channel delays 0, the calibration stays (Build 16).
    @MainActor
    func testResetSyncInPanel() throws {
        let app = UITestSupport.launch(["-uiScreen", "player", "-perfOverlay"])
        XCTAssertTrue(app.otherElements["video_surface"].waitForExistence(timeout: 30))
        XCTAssertTrue(waitPerf(app, contains: ["AVPlayer", "Buffer: ok"], timeout: 40), perf(app))
        openSyncPanel(app)
        let content = app.descendants(matching: .any)["player_audio_sync_delay"]
        let device = app.descendants(matching: .any)["player_vlc_calibration"]
        XCTAssertTrue(content.waitForExistence(timeout: 5))
        XCTAssertTrue(content.hasFocus, "content row focused")
        press(.right, 2)
        sleep(1)
        XCTAssertEqual(content.value as? String, "+100 ms · audio later")
        press(.down)
        XCTAssertTrue(device.hasFocus, "▼ calibration row")
        press(.left)
        XCTAssertEqual(device.value as? String, "-10 ms · audio earlier")
        XCTAssertTrue(waitPerf(app, contains: ["VLCKit", "Audio delay: +90 ms (device -10 ms, channel +100 ms)"], timeout: 30),
                      "delay on VLCKit: \(perf(app))")
        press(.down)
        let reset = app.buttons["audio_sync_reset"]
        XCTAssertTrue(reset.hasFocus, "▼ Reset sync")
        press(.select)
        XCTAssertTrue(app.staticTexts["audio_sync_reset_done"].waitForExistence(timeout: 2), "confirmation")
        XCTAssertEqual(content.value as? String, "0 ms")
        XCTAssertEqual(device.value as? String, "-10 ms · audio earlier", "calibration kept")
        XCTAssertTrue(waitPerf(app, contains: ["Audio delay: -10 ms (device -10 ms, channel 0 ms)"], timeout: 5), perf(app))
        UITestSupport.snap("engine-override/tvos-reset-sync", in: self)
        press(.up)
        XCTAssertTrue(device.hasFocus, "▲ back to the calibration row")
        press(.menu)
        XCTAssertTrue(content.waitForNonExistence(timeout: 3), "Menu closes the panel")
    }
}
