import XCTest

/// Audio sync (SCREENS §3.7, CONTRACT §6.1): a delay on an HLS channel moves it from AVPlayer to
/// VLCKit; "Fix sync" reopens it and it keeps playing. Engine read from the performance overlay.
final class IOSAudioSyncTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    /// Performance overlay text ("Engine: AVPlayer, …, Buffer: ok, …, Audio delay: +200 ms").
    @MainActor
    private func perf(_ app: XCUIApplication) -> String {
        let overlay = app.descendants(matching: .any)["perf_overlay"]
        return overlay.exists ? overlay.label : ""
    }

    @MainActor
    private func waitPerf(_ app: XCUIApplication, contains parts: [String], timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let text = perf(app)
            if parts.allSatisfy(text.contains) { return true }
            usleep(250_000)
        }
        return false
    }

    /// Overlay freshly shown (hide + show), so its 3 s auto-hide cannot close a menu we open.
    @MainActor
    private func showOverlay(_ app: XCUIApplication) {
        let close = app.buttons["player_close"]
        let surface = app.otherElements["video_surface"]
        if close.exists {
            surface.tap()
            _ = close.waitForNonExistence(timeout: 2)
        }
        surface.tap()
        XCTAssertTrue(close.waitForExistence(timeout: 3), "overlay shown")
    }

    @MainActor
    func testAudioSyncRoutesToVLC() throws {
        // Opened from the Live TV grid like a user does.
        let app = UITestSupport.launch(["-uiScreen", "live", "-perfOverlay"])
        let card = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'channel_'")).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 30))
        card.tap()
        XCTAssertTrue(app.otherElements["video_surface"].waitForExistence(timeout: 10))
        XCTAssertTrue(waitPerf(app, contains: ["AVPlayer", "Buffer: ok"], timeout: 40), "HLS plays via AVPlayer: \(perf(app))")

        showOverlay(app)
        app.buttons["Audio"].tap()
        // Menu items expose their label (SwiftUI drops the identifier inside a Menu).
        let syncRow = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Audio sync")).firstMatch
        XCTAssertTrue(syncRow.waitForExistence(timeout: 3), "Sync row in the audio menu")
        syncRow.tap()

        let plus = app.buttons["player_audio_sync_delay_plus"]
        XCTAssertTrue(plus.waitForExistence(timeout: 5), "sync panel")
        XCTAssertTrue(app.staticTexts["audio_sync_vlc_note"].exists, "AVPlayer note")
        XCTAssertTrue(app.buttons["player_device_audio_delay_plus"].exists, "device (TV/soundbar) row in the panel")
        XCTAssertTrue(app.otherElements["video_surface"].exists, "non-modal: the picture stays")
        for _ in 0..<4 { plus.tap() }
        XCTAssertEqual(app.staticTexts["player_audio_sync_delay_value"].label, "+200 ms · audio later")
        XCTAssertTrue(waitPerf(app, contains: ["VLCKit"], timeout: 5), "switched to VLCKit within 5 s: \(perf(app))")
        XCTAssertTrue(waitPerf(app, contains: ["VLCKit", "Buffer: ok", "Audio delay: +200 ms"], timeout: 30),
                      "VLCKit plays with the delay applied: \(perf(app))")
        // Device delay from the same panel adds live: 200 + (−100) applied by libVLC.
        app.buttons["player_device_audio_delay_minus"].tap()
        app.buttons["player_device_audio_delay_minus"].tap()
        XCTAssertEqual(app.staticTexts["player_device_audio_delay_value"].label, "-100 ms · audio earlier")
        XCTAssertTrue(waitPerf(app, contains: ["Audio delay: +100 ms"], timeout: 5), "content + device: \(perf(app))")
        UITestSupport.snap("ios-portrait-sync-panel", in: self)

        // iPhone landscape: the panel stays low – most of the picture remains visible.
        XCUIDevice.shared.orientation = .landscapeLeft
        sleep(2)
        let panel = app.otherElements["audio_sync_panel"]
        XCTAssertTrue(panel.waitForExistence(timeout: 3))
        let window = app.windows.firstMatch.frame
        XCTAssertGreaterThan(window.width, window.height, "landscape")
        XCTAssertLessThan(panel.frame.height, window.height * 0.6, "panel covers \(panel.frame.height) of \(window.height) pt")
        UITestSupport.snap("ios-landscape-sync-panel", in: self)
        XCUIDevice.shared.orientation = .portrait
        sleep(2)
        app.buttons["player_device_audio_delay_plus"].tap()
        app.buttons["player_device_audio_delay_plus"].tap()   // device delay back to 0 for the next checks
        app.buttons["audio_sync_close"].tap()
        XCTAssertTrue(plus.waitForNonExistence(timeout: 3), "panel closed")

        showOverlay(app)
        app.buttons["action_resync"].tap()
        XCTAssertTrue(waitPerf(app, contains: ["VLCKit", "Buffer: ok", "Audio delay: +200 ms"], timeout: 30),
                      "still playing after Fix sync: \(perf(app))")
        VLCTestSupport.assertNoErrorCard(app, "after resync")
        UITestSupport.snap("audio-sync-03-resynced", in: self)
    }
}
