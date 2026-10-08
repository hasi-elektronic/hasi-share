import XCTest

/// IOS-06 (Build 16): QuickStart relaunch → player surface and → first picture ("Playing"). Runner-side times are
/// measured from `XCUIApplication.launch()` (they include ~2 s of XCUITest launch overhead); the app's own
/// breakdown comes from the performance overlay ("Launch: pre … · env … · open … · task … · surface … · frame …",
/// ms since the app's init; pre = process start → init). Prints "QSPERF …" lines for the old path
/// (`-noEarlyQuickStart`: QuickStart from the root view's `.task`) and the Build 16 early QuickStart.
final class IOSQuickStartPerfTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    private static let sandbox = "quickStartPerfB"

    /// "frame 854" → 854.
    private static func phase(_ name: String, in summary: String) -> Int? {
        guard let range = summary.range(of: "\(name) ") else { return nil }
        return Int(summary[range.upperBound...].prefix { $0.isNumber })
    }

    @MainActor
    private func measure(_ mode: String, extra: [String]) -> (surface: Double, frame: Double) {
        var surfaceTimes: [Double] = []
        var frames: [Double] = []
        for round in 0..<3 {
            let again = XCUIApplication()
            again.launchArguments = ["-uiSandbox", Self.sandbox, "-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-uiTrial",
                                     "-perfOverlay"] + extra
            let start = Date()
            again.launch()
            let surface = again.otherElements["video_surface"]
            XCTAssertTrue(surface.waitForExistence(timeout: 10), "\(mode) round \(round): quick start opened the player")
            surfaceTimes.append(Date().timeIntervalSince(start))
            let overlay = again.descendants(matching: .any)["perf_overlay"]
            let deadline = Date().addingTimeInterval(15)
            var summary = ""
            while Date() < deadline {
                if overlay.exists, let range = overlay.label.range(of: "Launch: ") {
                    summary = String(overlay.label[range.upperBound...].prefix(200))
                    if Self.phase("frame", in: summary) != nil { break }
                }
                usleep(100_000)
            }
            if let pre = Self.phase("pre", in: summary), let frame = Self.phase("frame", in: summary) {
                frames.append(Double(pre + frame))
            }
            print(String(format: "QSPERF %@ round %d runner-surface %.2f s · app %@", mode, round, surfaceTimes.last!, summary))
            sleep(3)
            XCUIDevice.shared.press(.home)
            again.terminate()
        }
        let median: ([Double]) -> Double = { $0.isEmpty ? -1 : $0.sorted()[$0.count / 2] }
        print(String(format: "QSPERF %@ median runner-surface %.2f s · process start → first frame %.0f ms",
                     mode, median(surfaceTimes), median(frames)))
        return (median(surfaceTimes), median(frames))
    }

    @MainActor
    func testQuickStartRelaunchTiming() throws {
        let app = UITestSupport.launch(["-uiSandbox", Self.sandbox, "-uiScreen", "player", "-pref.quickStart", "YES"])
        XCTAssertTrue(app.otherElements["video_surface"].waitForExistence(timeout: 30))
        sleep(6)   // first frame → LastSession(endedInPlayer: true)
        XCUIDevice.shared.press(.home)
        app.terminate()

        let before = measure("task-path", extra: ["-noEarlyQuickStart"])
        let after = measure("early", extra: [])
        XCTAssertLessThan(after.surface, 4.5, "QuickStart surface within the (runner-inclusive) bound")
        XCTAssertGreaterThan(after.frame, 0, "app breakdown read")
        XCTAssertLessThanOrEqual(after.frame, before.frame + 150, "early QuickStart is not slower")
    }
}
