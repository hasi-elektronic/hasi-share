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
        XCTAssertEqual(row.value as? String, "+100 ms")
        XCTAssertTrue(row.hasFocus, "◀▶ change the value, focus stays on the row")
        for _ in 0..<3 { remote.press(.left) }
        sleep(1)
        XCTAssertEqual(row.value as? String, "-50 ms")
        UITestSupport.snap("tvos-audio-delay-settings", in: self)
    }
}
