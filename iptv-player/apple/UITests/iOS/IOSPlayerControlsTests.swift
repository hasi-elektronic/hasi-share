import XCTest

/// iPhone player controls (SCREENS §3.7): overlay buttons after auto-hide + re-show, VOD transport
/// row (⟲10 · play/pause · 10⟳), scrubber, resume with "Play from start".
final class IOSPlayerControlsTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    // MARK: Helpers

    /// "mm:ss" / "h:mm:ss" → seconds.
    static func seconds(_ clock: String) -> Double? {
        let parts = clock.split(separator: ":")
        let values = parts.compactMap { Double($0) }
        guard values.count >= 2, values.count == parts.count else { return nil }
        return values.reduce(0) { $0 * 60 + $1 }
    }

    /// Shows the overlay (tap on the picture) unless it is already shown.
    @MainActor
    static func showOverlay(_ app: XCUIApplication) {
        let playPause = app.buttons["player_play_pause"]
        if playPause.exists, playPause.isHittable { return }
        app.otherElements["video_surface"].tap()
        XCTAssertTrue(playPause.waitForExistence(timeout: 3), "overlay shown")
    }

    /// Overlay freshly shown (hide + show), so the 3 s auto-hide cannot remove it while we read it.
    @MainActor
    static func freshOverlay(_ app: XCUIApplication) {
        let playPause = app.buttons["player_play_pause"]
        let surface = app.otherElements["video_surface"]
        for _ in 0..<3 {
            if playPause.exists {
                surface.tap()
                _ = playPause.waitForNonExistence(timeout: 2)
            }
            if !playPause.exists {
                surface.tap()
                if playPause.waitForExistence(timeout: 2) { return }
            }
        }
        XCTFail("overlay could not be shown")
    }

    /// Time label (seconds) and play/pause state ("Playing"/"Paused") read from a fresh overlay.
    @MainActor
    static func state(_ app: XCUIApplication) -> (time: Double, value: String) {
        freshOverlay(app)
        let time = seconds(app.staticTexts["player_time"].label) ?? -1
        let value = app.buttons["player_play_pause"].value as? String ?? ""
        return (time, value)
    }

    @MainActor
    static func time(_ app: XCUIApplication) -> Double { state(app).time }

    @MainActor
    static func duration(_ app: XCUIApplication) -> Double {
        freshOverlay(app)
        return seconds(app.staticTexts["player_duration"].label) ?? 0
    }

    /// Waits until playback runs (play/pause says "Playing" and the time is past `after`).
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

    /// Launches on the movie detail of the given list's first movie (needs the Range media server).
    @MainActor
    static func launchMovie(_ m3u: String) throws -> XCUIApplication {
        try VLCTestSupport.requireServer()
        return UITestSupport.launch(["-uiScreen", "movieDetail", "-seedM3U", m3u, "-seedName", "Movies"], seed: false)
    }

    /// Movie detail (first movie of the seeded source) → Play.
    @MainActor
    static func playFromDetail(_ app: XCUIApplication) {
        let play = app.buttons["detail_play"]
        XCTAssertTrue(play.waitForExistence(timeout: 30), "movie detail")
        play.tap()
        XCTAssertTrue(app.otherElements["video_surface"].waitForExistence(timeout: 10))
    }

    // MARK: Overlay after auto-hide (TestFlight build 5)

    /// Live: after the 3 s auto-hide and a tap on the picture, `player_close` must close the player
    /// (before the fix the tap fell through to the overlay's background gesture).
    @MainActor
    func testLiveCloseWorksAfterAutoHide() throws {
        let app = UITestSupport.launch(["-uiScreen", "player"])
        let surface = app.otherElements["video_surface"]
        XCTAssertTrue(surface.waitForExistence(timeout: 30))
        let close = app.buttons["player_close"]
        let deadline = Date().addingTimeInterval(20)
        while close.exists, Date() < deadline { sleep(1) }   // first frame + 3 s auto-hide
        XCTAssertFalse(close.exists, "overlay hidden after 3 s")
        surface.tap()
        XCTAssertTrue(close.waitForExistence(timeout: 3), "overlay re-shown")
        close.tap()
        XCTAssertTrue(surface.waitForNonExistence(timeout: 5), "close works after re-show")
    }

    /// VOD: hide (4 s), re-show, then play/pause and close must react.
    @MainActor
    func testOverlayButtonsWorkAfterAutoHide() throws {
        let app = try Self.launchMovie(VLCTestSupport.mp4MovieM3U)
        Self.playFromDetail(app)
        XCTAssertTrue(Self.waitPlaying(app), "movie plays")
        let playPause = app.buttons["player_play_pause"]
        sleep(4)   // the overlay hides 3 s after the last interaction
        XCTAssertFalse(playPause.exists, "overlay hidden after 3 s")
        app.otherElements["video_surface"].tap()
        XCTAssertTrue(playPause.waitForExistence(timeout: 3), "overlay re-shown")
        playPause.tap()
        XCTAssertEqual(playPause.value as? String, "Paused", "play/pause works after re-show")
        sleep(4)
        XCTAssertTrue(playPause.exists, "overlay stays while paused")
        app.buttons["player_close"].tap()
        XCTAssertTrue(app.otherElements["video_surface"].waitForNonExistence(timeout: 5), "close works after re-show")
    }

    /// An open audio/aspect menu keeps the overlay (and thereby the menu) alive past 3 s.
    @MainActor
    func testMenuKeepsOverlayOpen() throws {
        let app = try Self.launchMovie(VLCTestSupport.mp4MovieM3U)
        Self.playFromDetail(app)
        XCTAssertTrue(Self.waitPlaying(app), "movie plays")
        app.buttons["Aspect ratio"].tap()
        let fill = app.buttons["Fill (crop)"]
        XCTAssertTrue(fill.waitForExistence(timeout: 3), "aspect menu open")
        sleep(5)
        XCTAssertTrue(fill.exists, "menu still open after the 3 s auto-hide window")
        UITestSupport.snap("controls-menu-open-after-5s", in: self)
        fill.tap()
        XCTAssertTrue(app.buttons["player_play_pause"].exists, "overlay still shown after the choice")
    }

    // MARK: VOD transport

    /// Progressive MP4 movie through AVPlayer (local Range server: the demo list's remote sample
    /// MP4s are no longer served).
    @MainActor
    func testVODControls() throws {
        try runVODControls(Self.launchMovie(VLCTestSupport.mp4MovieM3U), name: "avplayer")
    }

    /// MKV movie through VLCKit (needs the VLC test media server, skipped otherwise).
    @MainActor
    func testVODControlsMKV() throws {
        try runVODControls(Self.launchMovie(VLCTestSupport.movieM3U), name: "vlc")
    }

    /// Dragging the scrubber shows the target bubble ("Seek to 7:24, +6:50"); after release it stays a
    /// moment on the landing point (AVPlayer MP4: with a preview image).
    @MainActor
    func testScrubberShowsSeekBubble() throws {
        let app = try Self.launchMovie(VLCTestSupport.mp4MovieM3U)
        Self.playFromDetail(app)
        XCTAssertTrue(Self.waitPlaying(app), "plays")
        Self.showOverlay(app)
        let playPause = app.buttons["player_play_pause"]
        playPause.tap()
        XCTAssertEqual(playPause.value as? String, "Paused")
        let before = Self.time(app)
        let duration = Self.duration(app)
        XCTAssertGreaterThan(duration, 60)
        let scrubber = app.descendants(matching: .any)["player_scrubber"]
        XCTAssertTrue(scrubber.exists)
        // Hold at the end of the drag: the thumbnail for the target arrives meanwhile.
        scrubber.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.5))
            .press(forDuration: 0.1, thenDragTo: scrubber.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)),
                   withVelocity: .default, thenHoldForDuration: 1.5)
        let bubble = app.descendants(matching: .any)["player_seek_bubble"]
        XCTAssertTrue(bubble.waitForExistence(timeout: 1), "bubble after the drag")
        let label = bubble.label
        UITestSupport.snap("seek-ios-bubble", in: self)
        XCTAssertTrue(label.hasPrefix("Seek to "), label)
        XCTAssertTrue(label.contains(", +"), "forward jump in the bubble: \(label)")
        XCTAssertEqual(bubble.value as? String, "Preview image", "thumbnail on AVPlayer (local MP4)")
        XCTAssertTrue(bubble.waitForNonExistence(timeout: 4), "the bubble goes away")
        XCTAssertEqual(Self.time(app), duration / 2, accuracy: 2, "seeked on release (from \(before))")
    }

    /// IOS-01 (Build 16): the live overlay in iPhone portrait stays inside the screen – close, title, tools and
    /// the LIVE row – at the default text size and at an accessibility size.
    @MainActor
    func testLiveOverlayFitsPortraitScreen() throws {
        for extra in [[String](), ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXL"]] {
            let app = UITestSupport.launch(["-uiScreen", "player"] + extra)
            XCTAssertTrue(app.otherElements["video_surface"].waitForExistence(timeout: 30))
            Self.freshOverlay(app)
            let window = app.windows.firstMatch.frame
            let context = extra.isEmpty ? "default size" : "AX-XL"
            for id in ["player_close", "action_channel_list", "player_play_pause"] {
                let element = app.buttons[id].firstMatch
                XCTAssertTrue(element.exists, "\(context): \(id)")
                XCTAssertGreaterThanOrEqual(element.frame.minX, window.minX, "\(context): \(id) starts on screen (\(element.frame))")
                XCTAssertLessThanOrEqual(element.frame.maxX, window.maxX + 0.5, "\(context): \(id) ends on screen (\(element.frame))")
            }
            let title = app.staticTexts["player_title"].firstMatch
            XCTAssertTrue(title.exists, "\(context): channel title shown")
            XCTAssertGreaterThan(title.frame.width, 40, "\(context): title has room (\(title.frame))")
            XCTAssertGreaterThanOrEqual(title.frame.minX, window.minX)
            UITestSupport.snap("ios01-live-overlay-\(extra.isEmpty ? "default" : "axxl")", in: self)
            app.terminate()
        }
    }

    /// IOS-02 (Build 16). Root cause, reproduced here: the QA tour opened the subtitle menu while the 3-min MKV played;
    /// with VLCKit rendering XCUITest waits ~60 s for "idle" per step, so the movie simply reached its end. A scrub
    /// on the finished item then only moved the label – libVLC ignores `time` once the input ended – and the picture
    /// stayed on the last frame. Now the seek restarts the item at the target (`VLCPlaybackEngine`) and the controller
    /// plays on. The bubble's "−1:12" was correct: the jump from where the drag began (the end, IOS-15).
    @MainActor
    func testScrubWhilePlayingMKVKeepsPlaying() throws {
        let app = try Self.launchMovie(VLCTestSupport.movieM3U)
        Self.playFromDetail(app)
        XCTAssertTrue(Self.waitPlaying(app, after: 3), "MKV plays")
        let duration = Self.duration(app)
        XCTAssertGreaterThan(duration, 60, "duration known")
        // Let the movie end (as during the QA tour).
        Self.freshOverlay(app)
        let scrubber = app.descendants(matching: .any)["player_scrubber"]
        scrubber.coordinate(withNormalizedOffset: CGVector(dx: 0.985, dy: 0.5)).tap()
        let playPause = app.buttons["player_play_pause"]
        let deadline = Date().addingTimeInterval(20)
        var ended = false
        while Date() < deadline, !ended {
            sleep(1)
            let (time, value) = Self.state(app)
            ended = value == "Paused" && time >= duration - 2
        }
        XCTAssertTrue(ended, "the movie reached its end")
        UITestSupport.snap("scrub-mkv-ended", in: self)

        // Slow drag 10 % → 60 % with a hold (the QA gesture): one seek on release, playback restarts there.
        Self.freshOverlay(app)
        scrubber.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.5))
            .press(forDuration: 0.2, thenDragTo: scrubber.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.5)),
                   withVelocity: .slow, thenHoldForDuration: 1)
        let target = duration * 0.6
        let bubble = app.descendants(matching: .any)["player_seek_bubble"]
        if bubble.waitForExistence(timeout: 1) {
            XCTAssertTrue(bubble.label.contains(", \u{2212}1:1"), "jump from the drag start (the end): \(bubble.label)")
        }
        sleep(3)
        UITestSupport.snap("scrub-mkv-after-drag", in: self)
        let (time, value) = Self.state(app)
        XCTAssertEqual(value, "Playing", "plays again after the scrub (no frozen last frame)")
        XCTAssertEqual(time, target, accuracy: 6, "landed near the target")
        XCTAssertTrue(Self.waitPlaying(app, after: target + 2, timeout: 20), "playback continues past the target")
        _ = playPause
    }

    @MainActor
    private func runVODControls(_ app: XCUIApplication, name: String) throws {
        Self.playFromDetail(app)
        XCTAssertTrue(Self.waitPlaying(app), "\(name): plays")
        UITestSupport.snap("controls-\(name)-01-overlay", in: self)

        // Play/pause toggles.
        Self.showOverlay(app)
        let playPause = app.buttons["player_play_pause"]
        playPause.tap()
        XCTAssertEqual(playPause.value as? String, "Paused")
        UITestSupport.snap("controls-\(name)-02-paused", in: self)
        playPause.tap()
        XCTAssertEqual(playPause.value as? String, "Playing")

        // Measure the transport while paused, so playback does not blur the numbers (±2 s).
        playPause.tap()
        XCTAssertEqual(playPause.value as? String, "Paused")
        let before = Self.time(app)
        app.buttons["player_seek_forward"].tap()
        sleep(1)
        XCTAssertEqual(Self.time(app), before + 10, accuracy: 2, "\(name): +10 s")
        app.buttons["player_seek_back"].tap()
        sleep(1)
        XCTAssertEqual(Self.time(app), before, accuracy: 2, "\(name): −10 s")

        // Double tap on the right third: +10 s with a ripple, overlay not toggled.
        app.otherElements["video_surface"].coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.45)).doubleTap()
        UITestSupport.snap("controls-\(name)-02b-double-tap", in: self)
        sleep(1)
        XCTAssertEqual(Self.time(app), before + 10, accuracy: 2, "\(name): double tap +10 s")

        // Scrub to 50 %.
        let duration = Self.duration(app)
        XCTAssertGreaterThan(duration, 60, "\(name): duration known")
        let scrubber = app.descendants(matching: .any)["player_scrubber"]
        XCTAssertTrue(scrubber.exists)
        scrubber.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.5))
            .press(forDuration: 0.1, thenDragTo: scrubber.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)))
        sleep(1)
        let scrubbed = Self.time(app)
        XCTAssertEqual(scrubbed, duration / 2, accuracy: 2, "\(name): scrubbed to half")
        Self.showOverlay(app)
        playPause.tap()
        XCTAssertTrue(Self.waitPlaying(app, after: scrubbed - 1, timeout: 30), "\(name): plays on after the scrub")
        UITestSupport.snap("controls-\(name)-03-scrubbed", in: self)

        if name == "avplayer" {
            XCUIDevice.shared.orientation = .landscapeLeft
            sleep(1)
            Self.freshOverlay(app)
            UITestSupport.snap("controls-\(name)-03b-landscape", in: self)
            XCUIDevice.shared.orientation = .portrait
            sleep(1)
        }

        // Close (paused, exact position) → reopen: resumes there and offers "Play from start".
        Self.showOverlay(app)
        playPause.tap()
        XCTAssertEqual(playPause.value as? String, "Paused")
        let position = Self.time(app)
        app.buttons["player_close"].tap()
        XCTAssertTrue(app.otherElements["video_surface"].waitForNonExistence(timeout: 5))
        Self.playFromDetail(app)
        let chip = app.buttons["player_play_from_start"]
        XCTAssertTrue(chip.waitForExistence(timeout: 5), "\(name): 'Play from start' after resume")
        // The overlay is shown on open: read the label right away (≈ 1 s of playback after the resume).
        let label = app.staticTexts["player_time"]
        XCTAssertTrue(label.exists, "\(name): overlay shown on open")
        let resumedAt = Self.seconds(label.label) ?? -1
        UITestSupport.snap("controls-\(name)-04-resumed", in: self)
        XCTAssertEqual(resumedAt, position + 1, accuracy: 2, "\(name): resumed at \(position)")
        XCTAssertTrue(Self.waitPlaying(app, after: position - 2, timeout: 30), "\(name): plays after resume")
        app.buttons["player_close"].tap()
    }
}
