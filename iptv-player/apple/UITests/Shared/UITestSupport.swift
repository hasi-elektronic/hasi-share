import XCTest

/// Helpers shared by the iOS and tvOS UI tests.
enum UITestSupport {
    /// Test M3U served on the Mac (`python3 -m http.server`); override with TEST_RUNNER_SEED_M3U.
    static var seedM3U: String {
        ProcessInfo.processInfo.environment["SEED_M3U"] ?? "http://localhost:8765/test.m3u"
    }

    /// Launches the app with an in-memory database and the given debug hooks.
    @MainActor
    static func launch(_ extra: [String] = [], seed: Bool = true, trial: Bool = true) -> XCUIApplication {
        let app = XCUIApplication()
        var args = ["-uiTestReset", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        if seed { args += ["-seedM3U", seedM3U, "-seedName", "Demo TV"] }
        if trial { args.append("-uiTrial") }
        // Optional local dev backend (wrangler dev with a dev signing key) + its public key set.
        let env = ProcessInfo.processInfo.environment
        if let backend = env["DEV_BACKEND_URL"], !backend.isEmpty { args += ["-backendURL", backend] }
        if let keys = env["DEV_LICENSE_KEYS"], !keys.isEmpty { args += ["-debugLicenseKeys", keys] }
        app.launchArguments = args + extra
        app.launch()
        return app
    }

    /// Saves a screenshot as attachment and – when TEST_RUNNER_SCREENSHOT_DIR is set – as PNG file.
    @MainActor
    static func snap(_ name: String, in test: XCTestCase) {
        let shot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        test.add(attachment)
        if let dir = ProcessInfo.processInfo.environment["SCREENSHOT_DIR"], !dir.isEmpty {
            let url = URL(fileURLWithPath: dir).appendingPathComponent("\(name).png")
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? shot.pngRepresentation.write(to: url)
        }
    }
}
