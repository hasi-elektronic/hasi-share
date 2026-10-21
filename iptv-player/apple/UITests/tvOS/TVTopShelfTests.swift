import XCTest

/// Build 17 (F-01): Top Shelf deep links – `novaplayer://play/…` opens the item directly in the player.
/// (The in-memory UI-test source has a random id: "uitest-current" names it, DEBUG + `-uiTestReset` only.)
final class TVTopShelfTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testDeepLinkOpensChannelInPlayer() throws {
        let app = UITestSupport.launch(["-uiScreen", "live"])
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'channel_' AND label CONTAINS 'Bosphorus'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 30), "Bosphorus TV in the live list")
        let channelId = String(row.identifier.dropFirst("channel_".count))

        app.open(URL(string: "novaplayer://play/channel?source=uitest-current&id=\(channelId)")!)
        let title = app.staticTexts["player_title"]
        XCTAssertTrue(app.otherElements["video_surface"].waitForExistence(timeout: 15), "the link opens the player")
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        XCTAssertTrue(title.label.contains("Bosphorus"), "the linked channel plays: \(title.label)")
        UITestSupport.snap("topshelf/tvos-01-deeplink-channel", in: self)

        // The zapping list is the channel's category (TR | Ulusal: Bosphorus → Anka), like QuickStart.
        XCUIRemote.shared.press(.menu)   // overlay closed
        XCTAssertTrue(title.waitForNonExistence(timeout: 3))
        XCUIRemote.shared.press(.down)   // next channel
        sleep(3)
        XCUIRemote.shared.press(.right)  // overlay again
        XCTAssertTrue(title.waitForExistence(timeout: 3))
        XCTAssertTrue(title.label.contains("Anka"), "zapped within the category: \(title.label)")
    }

    @MainActor
    func testUnknownDeepLinkOpensNothing() throws {
        let app = UITestSupport.launch(["-uiScreen", "live"])
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'channel_'")).firstMatch.waitForExistence(timeout: 30))
        app.open(URL(string: "novaplayer://play/channel?source=uitest-current&id=does-not-exist")!)
        XCTAssertFalse(app.otherElements["video_surface"].waitForExistence(timeout: 5), "gone item: nothing opens")
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'channel_'")).firstMatch.exists, "still on the list")
    }

    /// Manual evidence (opt-in: TEST_RUNNER_TOPSHELF_HOME=1 – it moves the focus on the simulator's home screen): after a
    /// channel was watched the Top Shelf of the focused app icon shows "Recently watched". The app must sit in the top
    /// row (simulator default) – `TEST_RUNNER_TOPSHELF_RIGHT` = presses from the first icon (default 1).
    @MainActor
    func testTopShelfShowsRecentlyWatchedOnHomeScreen() throws {
        let env = ProcessInfo.processInfo.environment
        guard env["TOPSHELF_HOME"] == "1" else { throw XCTSkip("opt-in: TEST_RUNNER_TOPSHELF_HOME=1") }
        let app = UITestSupport.launch(["-uiScreen", "live"])
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'channel_' AND label CONTAINS 'Bosphorus'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 30))
        let channelId = String(row.identifier.dropFirst("channel_".count))
        app.open(URL(string: "novaplayer://play/channel?source=uitest-current&id=\(channelId)")!)
        XCTAssertTrue(app.otherElements["video_surface"].waitForExistence(timeout: 15))
        sleep(8)   // first frame → recently watched; the snapshot is written (5 s debounce, again on background)
        XCUIRemote.shared.press(.home)
        sleep(3)
        for _ in 0..<6 { XCUIRemote.shared.press(.left); usleep(300_000) }
        let right = Int(env["TOPSHELF_RIGHT"] ?? "1") ?? 1
        for _ in 0..<right { XCUIRemote.shared.press(.right); usleep(500_000) }
        sleep(8)
        // Away and back: the shelf is fetched again (right after an install the extension may not be registered yet).
        XCUIRemote.shared.press(.left)
        sleep(2)
        XCUIRemote.shared.press(.right)
        sleep(10)
        UITestSupport.snap("topshelf/tvos-02-home-shelf", in: self)
    }
}
