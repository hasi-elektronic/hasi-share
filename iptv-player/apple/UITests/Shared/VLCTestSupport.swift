import Foundation
import XCTest

/// Dual-engine (AVPlayer + VLCKit) player checks. Needs a Range-capable HTTP server with
/// `vlc-live.m3u` (1: MKV without extension, 2: progressive MPEG-TS, 3: HLS) and
/// `vlc-movie.m3u` (MKV movie), `vod-movie.m3u` (the same film as progressive MP4 → AVPlayer) and
/// `vod-403.m3u` (a movie URL answering HTTP 403)
/// – see apple/README.md "VLCKit doğrulaması". Skipped when the
/// server is not reachable, so the normal UI test run does not depend on it.
enum VLCTestSupport {
    static var base: String {
        ProcessInfo.processInfo.environment["VLC_MEDIA_BASE"] ?? "http://localhost:8766"
    }

    static var liveM3U: String { "\(base)/vlc-live.m3u" }
    static var movieM3U: String { "\(base)/vlc-movie.m3u" }
    static var mp4MovieM3U: String { "\(base)/vod-movie.m3u" }
    /// One movie whose URL answers HTTP 403 (`/status/403/…` on the Range server).
    static var deniedMovieM3U: String { "\(base)/vod-403.m3u" }

    /// Throws `XCTSkip` when the media server is down.
    static func requireServer() throws {
        guard let url = URL(string: liveM3U) else { throw XCTSkip("bad VLC_MEDIA_BASE") }
        let done = DispatchSemaphore(value: 0)
        final class Box: @unchecked Sendable { var ok = false }
        let box = Box()
        var request = URLRequest(url: url)
        request.timeoutInterval = 3
        URLSession.shared.dataTask(with: request) { _, response, _ in
            box.ok = (response as? HTTPURLResponse)?.statusCode == 200
            done.signal()
        }.resume()
        _ = done.wait(timeout: .now() + 5)
        if !box.ok { throw XCTSkip("VLC test media server not reachable at \(base)") }
    }

    /// Error card titles that must not appear while a VLCKit-only format plays.
    static let errorTitles = ["This stream format is not supported", "Video/audio codec not supported"]

    @MainActor
    static func assertNoErrorCard(_ app: XCUIApplication, _ context: String) {
        for title in errorTitles {
            XCTAssertFalse(app.staticTexts[title].exists, "\(context): error card '\(title)'")
        }
    }
}
