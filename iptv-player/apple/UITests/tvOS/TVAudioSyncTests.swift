import XCTest

/// Settings (top level) → "Calibrate audio sync" on tvOS (Build 16, SCREENS §3.9): the test clip plays in
/// VLCKit; the calibration is ONE focusable row, ◀▶ on the remote change it in 10 ms steps; Save persists it.
final class TVAudioSyncTests: XCTestCase {
    @MainActor private var remote: XCUIRemote { XCUIRemote.shared }

    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testCalibrationWithRemote() throws {
        let app = UITestSupport.launch(["-uiScreen", "settings"])
        XCTAssertTrue(app.tabBars.buttons["Settings"].waitForExistence(timeout: 30))
        XCTAssertTrue(focusCalibrationEntry(app), "calibration row focusable")
        press(.select)
        let row = app.descendants(matching: .any)["avsync_value"]
        XCTAssertTrue(row.waitForExistence(timeout: 10), "calibration screen")
        let engine = app.descendants(matching: .any)["avsync_engine"]
        XCTAssertEqual(engine.label, "VLCKit")
        expectation(for: NSPredicate(format: "value == 'playing'"), evaluatedWith: engine)
        waitForExpectations(timeout: 15)
        sleep(1)
        XCTAssertTrue(row.hasFocus, "the stepper has the focus")
        XCTAssertEqual(row.value as? String, "0 ms")
        press(.right, 2)
        sleep(1)
        XCTAssertEqual(row.value as? String, "+20 ms · audio later")
        XCTAssertTrue(row.hasFocus, "◀▶ change the value, focus stays on the row")
        press(.left, 3)
        sleep(1)
        XCTAssertEqual(row.value as? String, "-10 ms · audio earlier")
        UITestSupport.snap("tvos-avsync-calibration", in: self)
        let save = app.buttons["avsync_save"]
        XCTAssertTrue(focus(save, pressing: .down, limit: 4) || focus(save, pressing: .right, limit: 3), "▼ to the buttons, Save")
        press(.select)
        XCTAssertTrue(app.staticTexts["avsync_saved"].waitForExistence(timeout: 3), "saved")
        press(.menu)
        let entry = calibrationEntry(app)
        XCTAssertTrue(entry.waitForExistence(timeout: 5), "back in Settings, the row focused again")
        XCTAssertTrue(entry.label.contains("-10 ms"), "row shows the saved value: \(entry.label)")
    }

    /// Settings row "Calibrate audio sync": tvOS reports the focus on the list cell (the row's label), not on the
    /// identified link inside it – this is the focused cell (exists only while focused).
    @MainActor
    private func calibrationEntry(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "hasFocus == true AND label BEGINSWITH 'Calibrate audio sync'")).firstMatch
    }

    /// ▼ until the calibration row has the focus.
    @MainActor
    private func focusCalibrationEntry(_ app: XCUIApplication) -> Bool {
        XCTAssertTrue(app.buttons["settings_avsync_calibration"].firstMatch.waitForExistence(timeout: 30))
        sleep(1)
        for _ in 0..<20 where !calibrationEntry(app).exists { remote.press(.down); usleep(500_000) }
        return calibrationEntry(app).exists
    }

    /// "+1300 ms · audio later" → 1300.
    private static func ms(_ value: Any?) -> Int {
        let text = (value as? String) ?? ""
        return Int(text.split(separator: " ").first.map { $0.replacingOccurrences(of: "+", with: "") } ?? "") ?? 0
    }

    @MainActor
    private func focus(_ element: XCUIElement, pressing direction: XCUIRemote.Button, limit: Int = 12) -> Bool {
        for _ in 0..<limit {
            if element.exists && element.hasFocus { return true }
            remote.press(direction)
            usleep(500_000)
        }
        return element.exists && element.hasFocus
    }

    /// Quick repeated ◀▶ accelerate (50 → 100 → 250 ms).
    @MainActor
    func testStepperAccelerates() throws {
        let app = UITestSupport.launch(["-uiScreen", "settings"])
        XCTAssertTrue(app.tabBars.buttons["Settings"].waitForExistence(timeout: 30))
        XCTAssertTrue(focusCalibrationEntry(app), "calibration row focusable")
        press(.select)
        let row = app.descendants(matching: .any)["avsync_value"]
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        XCTAssertTrue(focus(row, pressing: .up, limit: 3), "stepper focused")
        for _ in 0..<12 { remote.press(.right) }
        sleep(1)
        let quick = Self.ms(row.value)
        print("ACCEL quick 12 presses → \(quick) ms")
        XCTAssertGreaterThan(quick, 12 * 10, "12 quick presses accelerate past 120 ms (got \(quick))")
        // (A held ◀▶ repeats via TVHoldSeek; `XCUIRemote.press(_:forDuration:)` does not trigger the
        // long-press recognizers in the simulator, so it is not asserted here.)
        for _ in 0..<12 { remote.press(.left) }
        sleep(1)
        XCTAssertLessThan(Self.ms(row.value), quick - 12 * 10, "quick ◀ presses accelerate too")
    }

    // MARK: Player, remote only

    /// tvOS menu rows are not exposed as buttons: match any element by label.
    @MainActor
    private func menuItem(_ app: XCUIApplication, _ label: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", label)).firstMatch
    }

    /// Overlay shown with play/pause focused (the player opens with it; OK would pause then).
    @MainActor
    private func ensureOverlay(_ app: XCUIApplication, showWith button: XCUIRemote.Button) {
        if !app.buttons["player_close"].exists { press(button) }
        XCTAssertTrue(app.buttons["player_close"].waitForExistence(timeout: 3), "overlay shown")
    }

    @MainActor
    private func press(_ button: XCUIRemote.Button, _ times: Int = 1) {
        for _ in 0..<times {
            remote.press(button)
            usleep(400_000)
        }
    }

    /// Top row (focus on close) → ▶ Audio → OK → the menu lists VLCKit's tracks and Sync → Sync →
    /// panel: ▼ VLC calibration row, ◀◀ −20 ms, ▶▶ back to 0, Menu closes only the panel.
    @MainActor
    private func audioMenuToSyncPanel(_ app: XCUIApplication, expectTracks: Bool, context: String) {
        press(.right)   // close → Audio
        press(.select)
        if expectTracks {
            XCTAssertTrue(menuItem(app, "Turkish").waitForExistence(timeout: 5), "\(context): VLCKit audio track rows in the Audio menu")
            XCTAssertTrue(menuItem(app, "English").exists, "\(context): second VLCKit audio track")
        }
        let syncRow = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'Audio sync'")).firstMatch
        XCTAssertTrue(syncRow.waitForExistence(timeout: 5), "\(context): Sync row in the Audio menu")
        UITestSupport.snap("tvos-\(context)-audio-menu", in: self)
        sleep(4)
        XCTAssertTrue(syncRow.exists, "\(context): the open menu keeps the overlay (no 3 s auto-hide)")
        press(.down, 4)   // the last row is Sync
        press(.select)

        let content = app.descendants(matching: .any)["player_audio_sync_delay"]
        let device = app.descendants(matching: .any)["player_vlc_calibration"]
        XCTAssertTrue(content.waitForExistence(timeout: 5), "\(context): sync panel")
        XCTAssertTrue(content.hasFocus, "\(context): content row focused")
        press(.down)
        XCTAssertTrue(device.hasFocus, "\(context): ▼ to the calibration row")
        press(.left, 2)
        XCTAssertEqual(device.value as? String, "-20 ms · audio earlier", "\(context)")
        UITestSupport.snap("tvos-\(context)-sync-panel", in: self)
        press(.right, 2)
        XCTAssertEqual(device.value as? String, "0 ms", "\(context)")
        // Play/Pause under the panel toggles playback but never puts the overlay over it.
        press(.playPause)
        XCTAssertFalse(app.buttons["player_close"].exists, "\(context): no overlay over the sync panel")
        XCTAssertTrue(device.exists, "\(context): panel stays")
        press(.playPause)
        XCTAssertFalse(app.buttons["player_close"].exists, "\(context): still no overlay")
        press(.menu)
        XCTAssertTrue(content.waitForNonExistence(timeout: 3), "\(context): Menu closes the panel")
        XCTAssertTrue(app.otherElements["video_surface"].exists, "\(context): player stays open")
    }

    /// From the top row's close: ▶ × `toResync` → "Fix sync" → OK; then ◀ + OK opens the aspect menu,
    /// which proves the focus walked the row to the resync button (the one right of aspect).
    @MainActor
    private func fixSyncFromTopRow(_ app: XCUIApplication, toResync: Int, context: String) {
        press(.right, toResync)
        press(.select)   // Fix sync
        sleep(2)
        VLCTestSupport.assertNoErrorCard(app, "\(context) after Fix sync")
        XCTAssertFalse(menuItem(app, "Fill (crop)").exists, "\(context): OK on Fix sync opened no menu")
        press(.left)
        press(.select)
        XCTAssertTrue(menuItem(app, "Fill (crop)").waitForExistence(timeout: 5), "\(context): ◀ from Fix sync is the aspect menu")
        press(.menu)    // close the menu
        XCTAssertTrue(app.otherElements["video_surface"].exists)
    }

    /// Live (VLCKit MKV channel with 2 audio + 2 subtitle tracks): ▶ shows the overlay (OK opens the
    /// channel panel), ▲ enters the top row, ◀▶ walk it.
    @MainActor
    func testLiveTopRowAudioSyncAndFixSyncWithRemote() throws {
        try VLCTestSupport.requireServer()
        let app = UITestSupport.launch(["-uiScreen", "player", "-seedM3U", VLCTestSupport.liveM3U, "-seedName", "VLC"], seed: false)
        XCTAssertTrue(app.otherElements["video_surface"].waitForExistence(timeout: 30))
        sleep(8)   // tracks reported
        ensureOverlay(app, showWith: .right)   // play/pause focused
        press(.up)       // top row: close
        audioMenuToSyncPanel(app, expectTracks: true, context: "live")
        ensureOverlay(app, showWith: .right)
        press(.up)
        fixSyncFromTopRow(app, toResync: 4, context: "live")   // close → Audio → Subtitles → Aspect → Fix sync
    }

    /// VOD (MKV movie via VLCKit): ▲ shows the overlay, ▲ again enters the top row (◀▶ on the transport
    /// row still seek), ◀▶ walk it.
    @MainActor
    func testVODTopRowAudioSyncAndFixSyncWithRemote() throws {
        try VLCTestSupport.requireServer()
        let app = UITestSupport.launch(["-uiScreen", "movieDetail", "-seedM3U", VLCTestSupport.movieM3U, "-seedName", "Movies"], seed: false)
        let play = app.buttons["detail_play"]
        XCTAssertTrue(play.waitForExistence(timeout: 30))
        sleep(2)
        for _ in 0..<6 where !play.hasFocus {
            remote.press(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'fav_'")).firstMatch.hasFocus ? .left : .down)
            sleep(1)
        }
        remote.press(.select)
        XCTAssertTrue(app.otherElements["video_surface"].waitForExistence(timeout: 10))
        sleep(8)
        ensureOverlay(app, showWith: .up)
        press(.up)   // top row: close
        audioMenuToSyncPanel(app, expectTracks: false, context: "vod")
        ensureOverlay(app, showWith: .up)
        press(.up)
        let subtitles = app.buttons["Subtitles"].exists
        fixSyncFromTopRow(app, toResync: subtitles ? 4 : 3, context: "vod")
    }
}
