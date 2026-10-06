import XCTest

/// Apple TV VOD transport (SCREENS §3.7): ◀▶ ±10 s (held → 30 s steps), select = play/pause.
final class TVPlayerControlsTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    /// "mm:ss" / "h:mm:ss" → seconds.
    static func seconds(_ clock: String) -> Double? {
        let parts = clock.split(separator: ":")
        let values = parts.compactMap { Double($0) }
        guard values.count >= 2, values.count == parts.count else { return nil }
        return values.reduce(0) { $0 * 60 + $1 }
    }

    /// Time and play/pause state; ▲ shows the overlay on VOD without seeking.
    @MainActor
    static func state(_ app: XCUIApplication) -> (time: Double, value: String) {
        let label = app.staticTexts["player_time"]
        if !label.exists { XCUIRemote.shared.press(.up) }
        guard label.waitForExistence(timeout: 3) else { return (-1, "") }
        let value = app.buttons["player_play_pause"].value as? String ?? ""
        return (seconds(label.label) ?? -1, value)
    }

    @MainActor
    static func waitPlaying(_ app: XCUIApplication, after: Double = 0, timeout: TimeInterval = 40) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let (time, value) = state(app)
            if time > after + 1, value == "Playing" { return true }
            sleep(1)
        }
        return false
    }

    @MainActor
    func testVODRemoteSeekAndPlayPause() throws {
        try VLCTestSupport.requireServer()
        let remote = XCUIRemote.shared
        let app = UITestSupport.launch(["-uiScreen", "movieDetail", "-seedM3U", VLCTestSupport.mp4MovieM3U, "-seedName", "Movies"], seed: false)
        let play = app.buttons["detail_play"]
        XCTAssertTrue(play.waitForExistence(timeout: 30))
        sleep(2)
        for _ in 0..<6 where !play.hasFocus {
            remote.press(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'fav_'")).firstMatch.hasFocus ? .left : .down)
            sleep(1)
        }
        XCTAssertTrue(play.hasFocus, "Play focused on the detail")
        remote.press(.select)
        XCTAssertTrue(app.otherElements["video_surface"].waitForExistence(timeout: 10))
        XCTAssertTrue(Self.waitPlaying(app), "movie plays")
        UITestSupport.snap("tv-controls-01-overlay", in: self)

        // Select toggles play/pause (overlay shown: play/pause has the focus).
        let playPause = app.buttons["player_play_pause"]
        remote.press(.select)
        XCTAssertEqual(Self.state(app).value, "Paused", "select pauses")
        UITestSupport.snap("tv-controls-02-paused", in: self)
        remote.press(.select)
        XCTAssertEqual(Self.state(app).value, "Playing", "select resumes")

        // Select on the picture (overlay hidden) pauses too, like the TV app.
        sleep(5)
        XCTAssertFalse(playPause.exists, "overlay auto-hidden")
        remote.press(.select)
        XCTAssertEqual(Self.state(app).value, "Paused", "select (overlay hidden) pauses")

        // Seeking measured while paused (±2 s). ▶ with the overlay shown: focus stays on play/pause.
        let start = Self.state(app).time
        remote.press(.right)
        sleep(1)
        XCTAssertEqual(Self.state(app).time, start + 10, accuracy: 2, "▶ (overlay shown)")
        // ▶ with the overlay hidden (Menu hides it).
        remote.press(.menu)
        sleep(1)
        XCTAssertFalse(app.staticTexts["player_time"].exists, "overlay hidden")
        remote.press(.right)
        sleep(1)
        XCTAssertEqual(Self.state(app).time, start + 20, accuracy: 2, "▶ (overlay hidden)")
        remote.press(.left)
        sleep(1)
        XCTAssertEqual(Self.state(app).time, start + 10, accuracy: 2, "◀ −10 s")

        // Held ▶ 1.6 s: recognised after 0.4 s, then a step every 0.3 s – 10 s, 30 s once held
        // for 1 s (≈ 10+10+30+30+30); plain 10 s steps would give ≤ 50.
        let beforeHold = Self.state(app).time
        remote.press(.right, forDuration: 1.6)
        sleep(1)
        let held = Self.state(app).time - beforeHold
        XCTAssertGreaterThanOrEqual(held, 60, "held ▶ accelerates")
        XCTAssertLessThanOrEqual(held, 140, "held ▶ stops on release")

        // ▲ reaches the top row: OK on close leaves the player.
        remote.press(.up)
        sleep(1)
        UITestSupport.snap("tv-controls-03-top-row", in: self)
        remote.press(.select)
        XCTAssertTrue(app.otherElements["video_surface"].waitForNonExistence(timeout: 5), "▲ + OK → close")
    }
}
