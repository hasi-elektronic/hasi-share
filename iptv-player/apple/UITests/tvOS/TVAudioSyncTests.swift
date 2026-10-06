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

    /// Player → Audio → Sync on tvOS: the non-modal bottom panel holds the content row and the device
    /// (TV/soundbar) row, one focus each, ◀▶ adjust live, ▼ moves between them, Menu closes only the
    /// panel. (Opened with `-uiSyncPanel`: XCUITest arrow presses cannot walk the overlay's top row.)
    @MainActor
    func testSyncPanelInPlayer() throws {
        try VLCTestSupport.requireServer()
        let app = UITestSupport.launch(["-uiScreen", "player", "-uiSyncPanel", "-seedM3U", VLCTestSupport.liveM3U, "-seedName", "VLC"],
                                       seed: false)
        let surface = app.otherElements["video_surface"]
        XCTAssertTrue(surface.waitForExistence(timeout: 30))
        let content = app.descendants(matching: .any)["player_audio_sync_delay"]
        let device = app.descendants(matching: .any)["player_device_audio_delay"]
        XCTAssertTrue(content.waitForExistence(timeout: 10), "sync panel")
        XCTAssertTrue(device.exists, "device (TV/soundbar) row in the panel")
        sleep(6)   // MKV via VLCKit playing behind the panel
        remote.press(.right)
        usleep(600_000)
        remote.press(.right)
        sleep(1)
        XCTAssertEqual(content.value as? String, "+100 ms · audio later", "content row has the focus, ◀▶ adjust it")
        remote.press(.down)     // ▼ to the device row
        sleep(1)
        XCTAssertTrue(device.hasFocus, "▼ moves to the device row")
        remote.press(.left)
        usleep(600_000)
        remote.press(.left)
        sleep(1)
        XCTAssertEqual(device.value as? String, "-100 ms · audio earlier")
        XCTAssertEqual(content.value as? String, "+100 ms · audio later", "▼ moved the focus, the content row kept its value")
        XCTAssertTrue(surface.exists, "picture still there (non-modal)")
        UITestSupport.snap("tvos-player-sync-panel", in: self)
        remote.press(.right)
        usleep(600_000)
        remote.press(.right)   // device delay back to 0
        sleep(1)
        XCTAssertEqual(device.value as? String, "0 ms")
        remote.press(.up)
        sleep(1)
        XCTAssertTrue(content.hasFocus, "▲ back to the content row")
        remote.press(.menu)     // closes the panel, not the player
        XCTAssertTrue(content.waitForNonExistence(timeout: 3), "Menu closes the panel")
        XCTAssertTrue(surface.exists, "player stays open")
    }
}
