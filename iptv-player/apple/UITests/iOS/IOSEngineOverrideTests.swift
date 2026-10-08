import XCTest

/// Settings → Advanced → Player engine (CONTRACT §6.1 rule −1) and "Reset sync" (SCREENS §3.7/§3.9):
/// A/V sync A/B tests. Engine and delays read from the performance overlay.
final class IOSEngineOverrideTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
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

    @MainActor
    private func playFirstChannel(_ app: XCUIApplication) {
        let card = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'channel_'")).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 30))
        card.tap()
        XCTAssertTrue(app.otherElements["video_surface"].waitForExistence(timeout: 10))
    }

    /// Overlay freshly shown → Audio → "Audio sync".
    @MainActor
    private func openSyncPanel(_ app: XCUIApplication) {
        let close = app.buttons["player_close"]
        let surface = app.otherElements["video_surface"]
        if close.exists {
            surface.tap()
            _ = close.waitForNonExistence(timeout: 2)
        }
        surface.tap()
        XCTAssertTrue(close.waitForExistence(timeout: 3), "overlay shown")
        app.buttons["Audio"].tap()
        let syncRow = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Audio sync")).firstMatch
        XCTAssertTrue(syncRow.waitForExistence(timeout: 3), "Sync row in the audio menu")
        syncRow.tap()
        XCTAssertTrue(app.otherElements["audio_sync_panel"].waitForExistence(timeout: 5), "sync panel")
    }

    /// Apple override: the HLS demo channel plays on AVPlayer; the Sync panel says the delay is off.
    @MainActor
    func testAppleOverridePlaysHLSOnAVPlayer() throws {
        let app = UITestSupport.launch(["-uiScreen", "live", "-perfOverlay", "-playerEngine", "apple"])
        playFirstChannel(app)
        XCTAssertTrue(waitPerf(app, contains: ["Engine: AVPlayer", "forced", "Buffer: ok"], timeout: 40),
                      "AVPlayer forced: \(perf(app))")
        XCTAssertTrue(perf(app).contains("Audio delay: 0 ms (device 0 ms, channel 0 ms)"), perf(app))
        openSyncPanel(app)
        XCTAssertTrue(app.staticTexts["audio_sync_apple_engine"].exists, "one line instead of steppers")
        XCTAssertFalse(app.buttons["player_audio_sync_delay_plus"].exists, "no steppers on the Apple engine")
        XCTAssertTrue(app.buttons["audio_sync_reset"].exists)
        UITestSupport.snap("engine-override/ios-apple-sync-panel", in: self)
    }

    /// Apple override + MKV movie → error card with the "needs the VLC engine" hint.
    @MainActor
    func testAppleOverrideMKVShowsVLCHint() throws {
        try VLCTestSupport.requireServer()
        let app = UITestSupport.launch(["-uiScreen", "movieDetail", "-seedM3U", VLCTestSupport.movieM3U, "-seedName", "Movies",
                                        "-playerEngine", "apple"], seed: false)
        let play = app.buttons.matching(NSPredicate(format: "identifier == 'detail_play' OR label == 'Play'")).firstMatch
        XCTAssertTrue(play.waitForExistence(timeout: 30))
        play.tap()
        let hint = app.staticTexts["error_hint"]
        XCTAssertTrue(hint.waitForExistence(timeout: 15), "error card with hint")
        XCTAssertTrue(hint.label.contains("needs the VLC engine"), hint.label)
        XCTAssertTrue(hint.label.contains("Automatic"), hint.label)
        XCTAssertTrue(app.staticTexts["This stream format is not supported"].exists)
        UITestSupport.snap("engine-override/ios-apple-mkv-error", in: self)
    }

    /// VLC override: the HLS demo channel plays on VLCKit.
    @MainActor
    func testVLCOverridePlaysHLSOnVLC() throws {
        let app = UITestSupport.launch(["-uiScreen", "live", "-perfOverlay", "-playerEngine", "vlc"])
        playFirstChannel(app)
        XCTAssertTrue(waitPerf(app, contains: ["Engine: VLCKit", "forced", "Buffer: ok"], timeout: 40), "VLCKit forced: \(perf(app))")
        VLCTestSupport.assertNoErrorCard(app, "HLS on VLC")
        UITestSupport.snap("engine-override/ios-vlc-hls", in: self)
    }

    /// Automatic: a delay routes HLS to VLCKit; "Reset sync" in the panel sets every delay to 0.
    @MainActor
    func testResetSyncInPanel() throws {
        let app = UITestSupport.launch(["-uiScreen", "live", "-perfOverlay"])
        playFirstChannel(app)
        XCTAssertTrue(waitPerf(app, contains: ["AVPlayer", "Buffer: ok"], timeout: 40), perf(app))
        openSyncPanel(app)
        let plus = app.buttons["player_audio_sync_delay_plus"]
        plus.tap()
        plus.tap()
        app.buttons["player_vlc_calibration_minus"].tap()
        XCTAssertEqual(app.staticTexts["player_audio_sync_delay_value"].label, "+100 ms · audio later")
        XCTAssertTrue(waitPerf(app, contains: ["VLCKit", "Audio delay: +90 ms (device -10 ms, channel +100 ms)"], timeout: 30),
                      "delay on VLCKit: \(perf(app))")
        app.buttons["audio_sync_reset"].tap()
        XCTAssertTrue(app.staticTexts["audio_sync_reset_done"].waitForExistence(timeout: 2), "confirmation")
        XCTAssertEqual(app.staticTexts["player_audio_sync_delay_value"].label, "0 ms")
        // Build 16: the per-device VLC calibration is not part of "Reset sync".
        XCTAssertEqual(app.staticTexts["player_vlc_calibration_value"].label, "-10 ms · audio earlier")
        XCTAssertTrue(waitPerf(app, contains: ["Audio delay: -10 ms (device -10 ms, channel 0 ms)"], timeout: 5), perf(app))
        app.buttons["player_vlc_calibration_plus"].tap()
        UITestSupport.snap("engine-override/ios-reset-sync", in: self)
        XCTAssertTrue(app.staticTexts["audio_sync_reset_done"].waitForNonExistence(timeout: 5), "toast goes away")
    }

    /// Settings → Advanced: the engine picker and "Reset sync" with its confirmation.
    @MainActor
    func testSettingsEngineAndResetSync() throws {
        let app = UITestSupport.launch(["-uiScreen", "settings"])
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 30))
        app.buttons["settings_advanced"].tap()
        let engine = app.descendants(matching: .any)["settings_player_engine"]
        for _ in 0..<6 where !(engine.exists && engine.isHittable) { app.swipeUp() }
        XCTAssertTrue(engine.exists, "Player engine picker")
        engine.tap()
        let apple = app.buttons["Apple (AVPlayer)"].firstMatch
        XCTAssertTrue(apple.waitForExistence(timeout: 3), "engine choices")
        XCTAssertTrue(app.buttons["VLC"].firstMatch.exists)
        apple.tap()
        sleep(1)
        XCTAssertTrue(engine.label.contains("Apple") || (engine.value as? String ?? "").contains("Apple"),
                      "picker shows Apple: \(engine.label) / \(String(describing: engine.value))")
        let reset = app.buttons["settings_reset_sync"]
        for _ in 0..<4 where !(reset.exists && reset.isHittable) { app.swipeUp() }
        reset.tap()
        let done = NSPredicate(format: "label CONTAINS %@", "All audio delays set to 0")
        XCTAssertTrue(XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: done, object: reset)], timeout: 2) == .completed,
                      "confirmation in the row: \(reset.label)")
        UITestSupport.snap("engine-override/ios-settings-advanced", in: self)
    }
}
