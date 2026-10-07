import XCTest

/// 3-tap rule (SCREENS §2) and the in-player channel panel (SCREENS §3.7).
final class IOSThreeTapTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }

    override func tearDown() {
        XCUIDevice.shared.orientation = .portrait
    }

    /// From Home: (a) a live channel plays, (b) the app language is chosen, (c) the add-source form
    /// opens – each in ≤ 3 taps.
    @MainActor
    func testThreeTapPaths() throws {
        let app = UITestSupport.launch()
        let liveTab = app.buttons["tab_live"]
        XCTAssertTrue(liveTab.waitForExistence(timeout: 30), "Home with the header tabs")

        // (a) Live tab → channel row: playing after 2 taps.
        var taps = 0
        liveTab.tap(); taps += 1
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'channel_'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap(); taps += 1
        XCTAssertTrue(app.otherElements["video_surface"].waitForExistence(timeout: 10), "a live channel plays")
        XCTAssertLessThanOrEqual(taps, 3)
        UITestSupport.snap("three-tap/ios-a-live-playing", in: self)
        let close = app.buttons["player_close"]
        if !close.exists { app.otherElements["video_surface"].tap() }
        XCTAssertTrue(close.waitForExistence(timeout: 3))
        close.tap()
        XCTAssertTrue(app.buttons["tab_home"].waitForExistence(timeout: 5))
        app.buttons["tab_home"].tap()

        // (b) ⚙️ → App language → Deutsch: 3 taps.
        taps = 0
        app.buttons["open_settings"].tap(); taps += 1
        let language = app.buttons["settings_app_language"]
        XCTAssertTrue(language.waitForExistence(timeout: 5), "language on the settings top level")
        XCTAssertTrue(language.isHittable, "no scrolling needed")
        language.tap(); taps += 1
        let deutsch = app.buttons["Deutsch"]
        XCTAssertTrue(deutsch.waitForExistence(timeout: 3), "language menu")
        deutsch.tap(); taps += 1
        XCTAssertTrue(app.navigationBars["Einstellungen"].waitForExistence(timeout: 5), "UI switched to German")
        XCTAssertLessThanOrEqual(taps, 3)
        UITestSupport.snap("three-tap/ios-b-language", in: self)

        // (c) ⚙️ → Sources → + M3U: the add form after 3 taps (settings still open: 2 more here).
        taps = 1   // ⚙️ (already open)
        let sources = app.buttons["settings_sources"]
        XCTAssertTrue(sources.isHittable, "Sources on the settings top level")
        sources.tap(); taps += 1
        let add = app.buttons["settings_add_m3u"]
        XCTAssertTrue(add.waitForExistence(timeout: 5), "+ M3U on the sources screen")
        add.tap(); taps += 1
        XCTAssertTrue(app.textFields["field_name"].waitForExistence(timeout: 5) || app.textFields.firstMatch.waitForExistence(timeout: 2),
                      "add-source form")
        XCTAssertLessThanOrEqual(taps, 3)
        UITestSupport.snap("three-tap/ios-c-add-source", in: self)
    }

    /// Settings: languages, quick start and the TV delay on top; the rest (licenses…) under Advanced.
    @MainActor
    func testSettingsTopLevelAndAdvanced() throws {
        let app = UITestSupport.launch(["-uiScreen", "settings"])
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 30))
        for id in ["settings_sources", "settings_app_language", "settings_audio_language", "settings_subtitle_language", "settings_quick_start"] {
            XCTAssertTrue(app.descendants(matching: .any)[id].exists, "\(id) on the top level")
        }
        XCTAssertTrue(app.descendants(matching: .any)["settings_device_audio_delay"].exists, "TV/soundbar delay on the top level")
        XCTAssertFalse(app.buttons["settings_licenses"].exists, "licenses moved to Advanced")
        UITestSupport.snap("three-tap/ios-settings-top", in: self)
        app.buttons["settings_advanced"].tap()
        let licenses = app.buttons["settings_licenses"]
        for _ in 0..<6 where !(licenses.exists && licenses.isHittable) { app.swipeUp() }
        XCTAssertTrue(licenses.isHittable, "licenses under Advanced")
        XCTAssertTrue(app.switches["settings_perf_overlay"].exists || app.descendants(matching: .any)["settings_perf_overlay"].exists)
        UITestSupport.snap("three-tap/ios-settings-advanced", in: self)
    }

    /// Opens a live channel from the Live list; returns its name.
    @MainActor
    private func playFirstChannel(_ app: XCUIApplication) -> String {
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'channel_'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 30))
        let name = row.label.components(separatedBy: ",").first ?? ""
        row.tap()
        XCTAssertTrue(app.otherElements["video_surface"].waitForExistence(timeout: 10))
        return name
    }

    /// Overlay freshly shown (hide + show): its 3 s auto-hide cannot remove a control we tap next.
    @MainActor
    private func freshOverlay(_ app: XCUIApplication) {
        let close = app.buttons["player_close"]
        let surface = app.otherElements["video_surface"]
        if close.exists {
            surface.tap()
            _ = close.waitForNonExistence(timeout: 2)
        }
        surface.tap()
        XCTAssertTrue(close.waitForExistence(timeout: 3), "overlay shown")
    }

    /// Channel name of a panel row ("12, Name, Programme" / "Name, Programme").
    private func panelName(_ label: String) -> String {
        var parts = label.components(separatedBy: ", ")
        if let first = parts.first, Int(first) != nil { parts.removeFirst() }
        return parts.first ?? ""
    }

    /// Title of the playing channel, read from a freshly shown overlay.
    @MainActor
    private func playingTitle(_ app: XCUIApplication, is name: String) -> Bool {
        let surface = app.otherElements["video_surface"]
        let close = app.buttons["player_close"]
        for _ in 0..<3 {
            if !close.exists { surface.tap() }
            if close.waitForExistence(timeout: 2), app.staticTexts[name].exists { return true }
            sleep(1)
        }
        return app.staticTexts[name].exists
    }

    @MainActor
    func testInPlayerChannelPanel() throws {
        let app = UITestSupport.launch(["-uiScreen", "live"])
        let first = playFirstChannel(app)
        let surface = app.otherElements["video_surface"]
        let panel = app.descendants(matching: .any)["player_channel_panel"]

        // List button in the overlay opens the panel on the channel's category, overlay gone.
        let listButton = app.buttons["action_channel_list"]
        freshOverlay(app)
        listButton.tap()
        XCTAssertTrue(panel.waitForExistence(timeout: 3), "channel panel")
        XCTAssertFalse(app.buttons["player_close"].exists, "the overlay closes under the panel")
        let category = app.buttons["player_channel_category"]
        XCTAssertTrue(category.exists, "category picker on top")
        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'panel_channel_'"))
        XCTAssertGreaterThanOrEqual(rows.count, 2)
        let current = rows.matching(NSPredicate(format: "selected == true")).firstMatch
        XCTAssertTrue(current.exists, "the playing channel is marked")
        XCTAssertEqual(panelName(current.label), first)
        sleep(1)
        UITestSupport.snap("channel-panel/ios-01-portrait", in: self)

        // Another channel: zaps, the player stays.
        let other = rows.matching(NSPredicate(format: "selected == false")).firstMatch
        let otherName = panelName(other.label)
        other.tap()
        XCTAssertTrue(panel.waitForNonExistence(timeout: 3), "panel closes after the choice")
        XCTAssertTrue(surface.exists, "video_surface still present")
        XCTAssertTrue(playingTitle(app, is: otherName), "title changed to \(otherName)")

        // Left-edge swipe opens it again; category "All" lists more channels.
        if app.buttons["player_close"].exists { surface.tap(); _ = app.buttons["player_close"].waitForNonExistence(timeout: 2) }
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.5))
            .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.5)))
        XCTAssertTrue(panel.waitForExistence(timeout: 3), "left-edge swipe opens the panel")
        let before = rows.count
        category.tap()
        let all = app.buttons["All"]
        XCTAssertTrue(all.waitForExistence(timeout: 3), "category menu")
        all.tap()
        sleep(1)
        XCTAssertGreaterThan(rows.count, before, "All lists more channels than one category")
        UITestSupport.snap("channel-panel/ios-02-all", in: self)

        // Landscape: the panel takes ~40 % on the leading side, the picture stays beside it.
        XCUIDevice.shared.orientation = .landscapeLeft
        sleep(2)
        let window = app.windows.firstMatch.frame
        let row = rows.firstMatch.frame
        XCTAssertLessThan(row.maxX, window.width * 0.5, "panel on the leading side (row ends at \(row.maxX) of \(window.width))")
        UITestSupport.snap("channel-panel/ios-03-landscape", in: self)
        // A tap on the picture beside the panel closes it.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5)).tap()
        XCTAssertTrue(panel.waitForNonExistence(timeout: 3), "tap beside the panel closes it")
        XCTAssertTrue(surface.exists)
    }

    /// iOS double tap in the middle while the sync panel is open closes it (no overlay over it).
    @MainActor
    func testDoubleTapClosesSyncPanel() throws {
        let app = UITestSupport.launch(["-uiScreen", "live"])
        _ = playFirstChannel(app)
        let surface = app.otherElements["video_surface"]
        let audio = app.buttons["Audio"]
        freshOverlay(app)
        audio.tap()
        let syncRow = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Audio sync")).firstMatch
        XCTAssertTrue(syncRow.waitForExistence(timeout: 3))
        syncRow.tap()
        let plus = app.buttons["player_audio_sync_delay_plus"]
        XCTAssertTrue(plus.waitForExistence(timeout: 5), "sync panel")
        surface.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)).doubleTap()
        XCTAssertTrue(plus.waitForNonExistence(timeout: 3), "double tap closes the sync panel")
        XCTAssertFalse(app.buttons["player_close"].exists, "no overlay on top of it")
    }
}
