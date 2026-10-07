import XCTest

/// Apple TV VOD transport (SCREENS §3.7): ◀▶ move a seek target ±10 s (held → 30/60/120 s steps), one
/// seek on commit (OK / idle / Play/Pause, Menu cancels), select = play/pause.
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
        // for 1 s (≈ 10+10+30+30+30); plain 10 s steps would give ≤ 50. Committed 0.8 s after release.
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

    // MARK: Seek preview (Build 14)

    /// Movie detail of the seeded list → Play → playing.
    @MainActor
    static func playMovie(_ m3u: String) -> XCUIApplication {
        let remote = XCUIRemote.shared
        let app = UITestSupport.launch(["-uiScreen", "movieDetail", "-seedM3U", m3u, "-seedName", "Movies",
                                        "-perfOverlay", "-seekCommitMs", "3000"], seed: false)
        let play = app.buttons["detail_play"]
        XCTAssertTrue(play.waitForExistence(timeout: 30))
        sleep(2)
        for _ in 0..<6 where !play.hasFocus {
            remote.press(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'fav_'")).firstMatch.hasFocus ? .left : .down)
            sleep(1)
        }
        remote.press(.select)
        XCTAssertTrue(app.otherElements["video_surface"].waitForExistence(timeout: 10))
        XCTAssertTrue(waitPlaying(app), "movie plays")
        return app
    }

    /// Pauses with OK (a press racing the overlay's auto-hide may be lost: retried).
    @MainActor
    static func pause(_ app: XCUIApplication) -> Bool {
        for _ in 0..<3 {
            if state(app).value == "Paused" { return true }
            XCUIRemote.shared.press(.select)
            sleep(1)
        }
        return state(app).value == "Paused"
    }

    /// "Seeks: n" of the performance overlay (engine seeks since launch).
    @MainActor
    static func seekCount(_ app: XCUIApplication) -> Int {
        let label = app.descendants(matching: .any)["perf_overlay"].label
        guard let range = label.range(of: #"Seeks: (\d+)"#, options: .regularExpression) else { return -1 }
        return Int(label[range].dropFirst("Seeks: ".count)) ?? -1
    }

    /// Bubble label "Seek to 0:42, +0:30" → the jump ("+0:30").
    @MainActor
    static func bubbleJump(_ app: XCUIApplication) -> String? {
        let bubble = app.descendants(matching: .any)["player_seek_bubble"]
        guard bubble.exists, let comma = bubble.label.lastIndex(of: ",") else { return nil }
        return bubble.label[bubble.label.index(after: comma)...].trimmingCharacters(in: .whitespaces)
    }

    /// ◀▶ move a target (bubble with time + jump) without seeking; it commits once – after the idle
    /// time (lengthened to 3 s here so the bubble can be read), on OK, never after Menu; held ▶ accelerates.
    @MainActor
    func testSeekPreviewCommitsOnce() throws {
        try VLCTestSupport.requireServer()
        let remote = XCUIRemote.shared
        let app = Self.playMovie(VLCTestSupport.mp4MovieM3U)
        XCTAssertTrue(app.descendants(matching: .any)["perf_overlay"].label.contains("AVPlayer"), "progressive MP4 on AVPlayer")

        // Paused (overlay shown, play/pause focused), so time labels are exact.
        XCTAssertTrue(Self.pause(app), "paused")
        let start = Self.state(app).time
        let seeks = Self.seekCount(app)
        XCTAssertGreaterThanOrEqual(seeks, 0, "perf overlay shows the seek count")

        // ▶ ×3: the target moves 30 s, nothing seeks yet.
        remote.press(.right)
        remote.press(.right)
        remote.press(.right)
        let bubble = app.descendants(matching: .any)["player_seek_bubble"]
        XCTAssertTrue(bubble.waitForExistence(timeout: 2), "bubble while seeking")
        XCTAssertEqual(Self.bubbleJump(app), "+0:30", "bubble shows the jump: \(bubble.label)")
        XCTAssertEqual(Self.seconds(app.staticTexts["player_time"].label) ?? -1, start + 30, accuracy: 1.5, "elapsed label follows the target")
        XCTAssertTrue(app.staticTexts["player_duration"].label.hasPrefix("\u{2212}"), "remaining time from the target")
        XCTAssertEqual(Self.seekCount(app), seeks, "no seek while previewing")
        sleep(1)   // thumbnail (AVPlayer, local non-Xtream MP4)
        XCTAssertEqual(bubble.value as? String, "Preview image", "thumbnail on AVPlayer")
        UITestSupport.snap("seek-tv-bubble-thumbnail", in: self)
        // Idle → exactly one seek to the target.
        XCTAssertTrue(bubble.waitForNonExistence(timeout: 6), "committed after the idle time")
        sleep(1)
        XCTAssertEqual(Self.seekCount(app), seeks + 1, "one seek for three presses")
        XCTAssertEqual(Self.state(app).time, start + 30, accuracy: 2, "landed on the target")

        // Menu cancels: no seek, the time snaps back.
        remote.press(.right)
        remote.press(.right)
        XCTAssertTrue(bubble.waitForExistence(timeout: 2))
        XCTAssertEqual(Self.bubbleJump(app), "+0:20")
        remote.press(.menu)
        XCTAssertTrue(bubble.waitForNonExistence(timeout: 2), "Menu removes the bubble")
        XCTAssertTrue(app.buttons["player_play_pause"].exists, "Menu only cancelled (overlay stays)")
        sleep(4)
        XCTAssertEqual(Self.seekCount(app), seeks + 1, "cancelled: no seek")
        XCTAssertEqual(Self.state(app).time, start + 30, accuracy: 2, "position unchanged")

        // OK commits right away (and does not toggle play/pause).
        remote.press(.left)
        XCTAssertTrue(bubble.waitForExistence(timeout: 2))
        XCTAssertEqual(Self.bubbleJump(app), "\u{2212}0:10")
        remote.press(.select)
        XCTAssertTrue(bubble.waitForNonExistence(timeout: 2), "OK commits")
        XCTAssertEqual(Self.seekCount(app), seeks + 2)
        let afterOK = Self.state(app)
        XCTAssertEqual(afterOK.time, start + 20, accuracy: 2, "OK: −10 s")
        XCTAssertEqual(afterOK.value, "Paused", "OK while seeking does not resume")

        // Held ▶ 2.6 s: 10, 10, then 30 s steps – far more than 10 s steps (≤ 90) could reach; still one seek.
        remote.press(.right, forDuration: 2.6)
        XCTAssertTrue(bubble.waitForExistence(timeout: 2))
        let target = Self.seconds(app.staticTexts["player_time"].label) ?? -1
        XCTAssertGreaterThanOrEqual(target - (start + 20), 110, "held ▶ accelerates: \(bubble.label)")
        XCTAssertLessThanOrEqual(target - (start + 20), 260, "held ▶ stops on release")
        XCTAssertTrue(bubble.waitForNonExistence(timeout: 6))
        sleep(1)
        XCTAssertEqual(Self.seekCount(app), seeks + 3, "one seek for the whole hold")
        XCTAssertEqual(Self.state(app).time, target, accuracy: 2)

        // Play/Pause while seeking: jumps to the target and resumes (it was paused).
        remote.press(.left)
        XCTAssertTrue(bubble.waitForExistence(timeout: 2))
        remote.press(.playPause)
        XCTAssertTrue(bubble.waitForNonExistence(timeout: 2))
        XCTAssertEqual(Self.seekCount(app), seeks + 4)
        XCTAssertTrue(Self.waitPlaying(app, after: target - 12, timeout: 20), "Play/Pause: seek + play")
    }

    /// VLCKit item (MKV): the bubble is time-only (no second connection for thumbnails).
    @MainActor
    func testSeekPreviewWithoutThumbnailOnVLC() throws {
        try VLCTestSupport.requireServer()
        let remote = XCUIRemote.shared
        let app = Self.playMovie(VLCTestSupport.movieM3U)
        XCTAssertTrue(app.descendants(matching: .any)["perf_overlay"].label.contains("VLCKit"), "MKV on VLCKit")
        XCTAssertTrue(Self.pause(app), "paused")
        remote.press(.right)
        remote.press(.right)
        let bubble = app.descendants(matching: .any)["player_seek_bubble"]
        XCTAssertTrue(bubble.waitForExistence(timeout: 2))
        sleep(1)
        XCTAssertEqual(bubble.value as? String ?? "", "", "no preview image on VLCKit")
        UITestSupport.snap("seek-tv-bubble-time-only", in: self)
        remote.press(.menu)
        XCTAssertTrue(bubble.waitForNonExistence(timeout: 2))
    }
}
