import XCTest

/// Apple TV: MKV and MPEG-TS through VLCKit, HLS through AVPlayer, zapping with the remote.
final class TVVLCPlaybackTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testLiveMKVZapToTSAndHLS() throws {
        try VLCTestSupport.requireServer()
        let remote = XCUIRemote.shared
        let app = UITestSupport.launch(["-uiScreen", "player", "-seedM3U", VLCTestSupport.liveM3U, "-seedName", "VLC"], seed: false)
        XCTAssertTrue(app.otherElements["video_surface"].waitForExistence(timeout: 30))
        sleep(8)
        VLCTestSupport.assertNoErrorCard(app, "MKV")
        UITestSupport.snap("vlc-tvos-01-mkv-playing", in: self)

        remote.press(.select)   // overlay with the audio/subtitle/aspect tools
        sleep(1)
        UITestSupport.snap("vlc-tvos-02-mkv-overlay", in: self)
        XCTAssertTrue(app.buttons["Subtitles"].exists, "VLCKit subtitle tracks listed")
        // ▲ into the top row (close), ▶ Audio, OK: VLCKit's two audio tracks are rows of the menu.
        remote.press(.up)
        usleep(400_000)
        remote.press(.right)
        usleep(400_000)
        remote.press(.select)
        let turkish = app.descendants(matching: .any).matching(NSPredicate(format: "label == 'Turkish'")).firstMatch
        XCTAssertTrue(turkish.waitForExistence(timeout: 5), "VLCKit audio track rows in the Audio menu")
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label == 'English'")).firstMatch.exists)
        UITestSupport.snap("vlc-tvos-02b-audio-tracks", in: self)
        remote.press(.menu)     // close the menu
        sleep(1)
        remote.press(.menu)     // close overlay (back rule)
        sleep(4)

        remote.press(.down)     // CH+ → progressive MPEG-TS (VLCKit)
        sleep(10)
        VLCTestSupport.assertNoErrorCard(app, "MPEG-TS")
        UITestSupport.snap("vlc-tvos-03-ts-playing", in: self)

        remote.press(.down)     // CH+ → HLS (AVPlayer)
        sleep(10)
        VLCTestSupport.assertNoErrorCard(app, "HLS")
        UITestSupport.snap("vlc-tvos-04-hls-avplayer", in: self)

        remote.press(.up)       // ▲ = channel info card (spec §2) …
        sleep(1)
        remote.press(.up)       // … ▲ again = CH− back to VLCKit: engine switch in both directions
        sleep(8)
        VLCTestSupport.assertNoErrorCard(app, "MPEG-TS again")
        UITestSupport.snap("vlc-tvos-05-ts-again", in: self)
    }
}
