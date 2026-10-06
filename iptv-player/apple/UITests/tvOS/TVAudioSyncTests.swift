import XCTest

/// Settings → Playback → device/soundbar delay on tvOS (SCREENS §3.7/§3.9): ONE focusable row,
/// ◀▶ on the remote change the value in 50 ms steps.
final class TVAudioSyncTests: XCTestCase {
    @MainActor private var remote: XCUIRemote { XCUIRemote.shared }

    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testDeviceDelayStepperWithRemote() throws {
        let app = UITestSupport.launch(["-uiScreen", "settings"])
        XCTAssertTrue(app.tabBars.buttons["Settings"].waitForExistence(timeout: 30))
        let row = app.descendants(matching: .any)["settings_device_audio_delay"]
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        var focused = false
        for _ in 0..<20 {
            if row.hasFocus { focused = true; break }
            remote.press(.down)
            usleep(500_000)
        }
        XCTAssertTrue(focused, "device delay row focusable")
        XCTAssertEqual(row.value as? String, "0 ms")
        remote.press(.right)
        remote.press(.right)
        sleep(1)
        XCTAssertEqual(row.value as? String, "+100 ms · audio later")
        XCTAssertTrue(row.hasFocus, "◀▶ change the value, focus stays on the row")
        for _ in 0..<3 { remote.press(.left) }
        sleep(1)
        XCTAssertEqual(row.value as? String, "-50 ms · audio earlier")
        remote.press(.down)
        sleep(1)
        XCTAssertFalse(row.hasFocus, "▼ leaves the row (no focus trap)")
        remote.press(.up)
        sleep(1)
        XCTAssertTrue(row.hasFocus, "▲ comes back")
        UITestSupport.snap("tvos-audio-delay-settings", in: self)
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
        let row = app.descendants(matching: .any)["settings_device_audio_delay"]
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        XCTAssertTrue(focus(row, pressing: .down, limit: 20), "device delay row focusable")
        for _ in 0..<12 { remote.press(.right) }
        sleep(1)
        let quick = Self.ms(row.value)
        print("ACCEL quick 12 presses → \(quick) ms")
        XCTAssertGreaterThan(quick, 12 * 50, "12 quick presses accelerate past 600 ms (got \(quick))")
        // (A held ◀▶ repeats via TVHoldSeek; `XCUIRemote.press(_:forDuration:)` does not trigger the
        // long-press recognizers in the simulator, so it is not asserted here.)
        for _ in 0..<12 { remote.press(.left) }
        sleep(1)
        XCTAssertLessThan(Self.ms(row.value), quick - 12 * 50, "quick ◀ presses accelerate too")
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
    /// panel: ▼ device row, ◀◀ −100 ms, ▶▶ back to 0, Menu closes only the panel.
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
        let device = app.descendants(matching: .any)["player_device_audio_delay"]
        XCTAssertTrue(content.waitForExistence(timeout: 5), "\(context): sync panel")
        XCTAssertTrue(content.hasFocus, "\(context): content row focused")
        press(.down)
        XCTAssertTrue(device.hasFocus, "\(context): ▼ to the device row")
        press(.left, 2)
        XCTAssertEqual(device.value as? String, "-100 ms · audio earlier", "\(context)")
        UITestSupport.snap("tvos-\(context)-sync-panel", in: self)
        press(.right, 2)
        XCTAssertEqual(device.value as? String, "0 ms", "\(context)")
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

    /// Live (VLCKit MKV channel with 2 audio + 2 subtitle tracks): OK shows the overlay, ▲ enters the
    /// top row, ◀▶ walk it.
    @MainActor
    func testLiveTopRowAudioSyncAndFixSyncWithRemote() throws {
        try VLCTestSupport.requireServer()
        let app = UITestSupport.launch(["-uiScreen", "player", "-seedM3U", VLCTestSupport.liveM3U, "-seedName", "VLC"], seed: false)
        XCTAssertTrue(app.otherElements["video_surface"].waitForExistence(timeout: 30))
        sleep(8)   // tracks reported
        ensureOverlay(app, showWith: .select)   // play/pause focused
        press(.up)       // top row: close
        audioMenuToSyncPanel(app, expectTracks: true, context: "live")
        ensureOverlay(app, showWith: .select)
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
