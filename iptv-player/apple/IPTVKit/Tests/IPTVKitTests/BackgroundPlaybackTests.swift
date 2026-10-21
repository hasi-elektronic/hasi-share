import Foundation
import IPTVCore
import XCTest
@testable import IPTVKit

/// Build 17 (C4 / IOS-10/11): background audio + Picture in Picture keep the player when the app leaves the screen;
/// everything else keeps the B4 release.
@MainActor
final class BackgroundPlaybackTests: XCTestCase {
    private var av: FakeEngine!
    private var vlc: FakeEngine!

    private func makeEnv(supported: Bool = true) throws -> AppEnvironment {
        let av = FakeEngine(kind: .avPlayer)
        let vlc = FakeEngine(kind: .vlcKit)
        self.av = av
        self.vlc = vlc
        let config = AppConfig(displayName: "Test", bundleId: "de.hasielektronik.novaplayer", appVersion: "1.0",
                               backendBaseURL: URL(string: "http://127.0.0.1:9")!, productIDs: ProductIDs(lifetime: "l", trial: "t"),
                               licenseKeysJSON: TestSigner().jwkSetJSON, platform: .ios, rawDeviceId: "device", deviceName: "Test")
        let env = try AppEnvironment(config: config, database: AppDatabase.inMemory(), secureStore: InMemorySecureStore(),
                                     kv: InMemoryKeyValueStore(), engines: PlaybackEngines(avPlayer: { av }, vlc: { vlc }))
        env.player.canPlay = { true }
        env.player.backgroundPlaybackSupported = supported
        return env
    }

    private func openAndPlay(_ player: PlayerController, _ url: String) async throws -> FakeEngine {
        player.open(PlaybackRequest(item: .url(url, title: "x"), source: nil))
        for _ in 0..<200 where av.loads.isEmpty && vlc.loads.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        let engine = try XCTUnwrap(player.engine as? FakeEngine)
        engine.isPlaying = true
        engine.emit(.playing)
        XCTAssertEqual(player.phase, .playing)
        return engine
    }

    func testDecisionMatrix() {
        let keep = BackgroundPlayback.Decision.keepPlaying, release = BackgroundPlayback.Decision.release
        for phase: PlayerPhase in [.playing, .buffering, .loading, .reconnecting(attempt: 1, max: 5)] {
            XCTAssertEqual(BackgroundPlayback.decision(supported: true, audioEnabled: true, pictureInPicture: false, phase: phase), keep, "\(phase)")
            XCTAssertEqual(BackgroundPlayback.decision(supported: true, audioEnabled: false, pictureInPicture: false, phase: phase), release, "\(phase)")
            XCTAssertEqual(BackgroundPlayback.decision(supported: false, audioEnabled: true, pictureInPicture: true, phase: phase), release, "tvOS \(phase)")
        }
        for phase: PlayerPhase in [.paused, .ended, .idle, .failed(.network(.timeout)), .locked] {
            XCTAssertEqual(BackgroundPlayback.decision(supported: true, audioEnabled: true, pictureInPicture: false, phase: phase), release, "\(phase)")
        }
        // PiP shows the item whatever its state (also a paused one), with or without background audio.
        XCTAssertEqual(BackgroundPlayback.decision(supported: true, audioEnabled: false, pictureInPicture: true, phase: .paused), keep)
        XCTAssertEqual(BackgroundPlayback.decision(supported: true, audioEnabled: false, pictureInPicture: true, phase: .playing), keep)
    }

    func testBackgroundAudioKeepsPlayingAndSuspendsVLCVideo() async throws {
        let env = try makeEnv()
        let engine = try await openAndPlay(env.player, "http://h.example.com/film.mkv")
        XCTAssertEqual(env.player.engineKind, .vlcKit)
        XCTAssertEqual(engine.backgroundAllowed.last, true, "the engine may play on in the background")
        env.scenePhaseChanged(.inactive)
        env.scenePhaseChanged(.background)
        XCTAssertEqual(engine.stops, 0, "not released")
        XCTAssertEqual(env.player.phase, .playing)
        XCTAssertTrue(env.player.isInBackground)
        XCTAssertEqual(engine.videoSuspensions.last, true, "VLCKit video track off in the background")
        env.scenePhaseChanged(.inactive)
        env.scenePhaseChanged(.active)
        XCTAssertEqual(engine.videoSuspensions.last, false, "picture back")
        XCTAssertEqual(engine.loads.count, 1, "nothing reopened")
        XCTAssertFalse(env.player.isInBackground)
    }

    func testSettingOffReleasesAsBefore() async throws {
        let env = try makeEnv()
        env.player.preferences?.backgroundAudio = false
        env.player.refreshBackgroundPlayback()
        let engine = try await openAndPlay(env.player, "http://h.example.com/live/1.m3u8")
        XCTAssertEqual(engine.backgroundAllowed.last, false)
        env.scenePhaseChanged(.background)
        XCTAssertEqual(engine.stops, 1, "released")
        XCTAssertEqual(env.player.phase, .idle)
        env.scenePhaseChanged(.active)
        for _ in 0..<200 where engine.loads.count < 2 { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(engine.loads.count, 2, "reopened on return (B4)")
    }

    func testPlatformWithoutBackgroundAudioReleases() async throws {
        let env = try makeEnv(supported: false)   // tvOS
        let engine = try await openAndPlay(env.player, "http://h.example.com/live/1.m3u8")
        XCTAssertEqual(engine.backgroundAllowed.last, false)
        env.scenePhaseChanged(.background)
        XCTAssertEqual(engine.stops, 1)
    }

    func testPausedPlayerIsReleasedInTheBackground() async throws {
        let env = try makeEnv()
        let engine = try await openAndPlay(env.player, "http://h.example.com/film.mp4")
        env.player.togglePlayPause()
        XCTAssertEqual(env.player.phase, .paused)
        env.scenePhaseChanged(.background)
        XCTAssertEqual(engine.stops, 1, "paused: connection freed")
        env.scenePhaseChanged(.active)
        XCTAssertEqual(env.player.phase, .paused, "the pause survives the scene cycle")
        XCTAssertEqual(engine.loads.count, 1)
    }

    func testPictureInPictureKeepsAPausedItemAndItsEndReleases() async throws {
        let env = try makeEnv()
        env.player.preferences?.backgroundAudio = false
        let engine = try await openAndPlay(env.player, "http://h.example.com/film.mp4")
        env.player.setPictureInPictureActive(true)
        env.scenePhaseChanged(.background)
        XCTAssertEqual(engine.stops, 0, "PiP keeps the player even without background audio")
        XCTAssertNotEqual(engine.videoSuspensions.last, true, "PiP shows the picture")
        engine.isPlaying = false
        engine.emit(.paused)   // the PiP window's pause
        XCTAssertEqual(env.player.phase, .paused)
        XCTAssertEqual(engine.stops, 0, "a paused PiP stays")
        env.player.setPictureInPictureActive(false)   // PiP closed in the background
        XCTAssertEqual(engine.stops, 1, "released once PiP is gone")
        env.scenePhaseChanged(.active)
        XCTAssertEqual(env.player.phase, .paused)
        XCTAssertEqual(engine.loads.count, 1, "no reopen")
    }

    func testPictureInPictureEndingWhilePlayingFallsBackToBackgroundAudio() async throws {
        let env = try makeEnv()
        let engine = try await openAndPlay(env.player, "http://h.example.com/live/1.m3u8")
        env.player.setPictureInPictureActive(true)
        env.scenePhaseChanged(.background)
        env.player.setPictureInPictureActive(false)
        XCTAssertEqual(engine.stops, 0, "background audio continues")
        XCTAssertEqual(env.player.phase, .playing)
    }

    func testSleepTimerInTheBackgroundReleases() async throws {
        let env = try makeEnv()
        env.player.sleepTimerMinuteMs = 30
        env.player.sleepFadeMs = 10
        let engine = try await openAndPlay(env.player, "http://h.example.com/film.mp4")
        env.player.setSleepTimer(.minutes(1))
        env.scenePhaseChanged(.background)
        XCTAssertEqual(engine.stops, 0)
        for _ in 0..<400 where engine.stops == 0 { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(engine.stops, 1, "sleep timer in the background frees the connection")
        XCTAssertEqual(env.player.sleepTimerFiredCount, 1)
        env.scenePhaseChanged(.active)
        XCTAssertEqual(env.player.phase, .paused, "back on screen: paused, nothing restarts")
        XCTAssertEqual(engine.loads.count, 1)
    }

    func testBackgroundZapStaysSoundOnly() async throws {
        let env = try makeEnv()
        let engine = try await openAndPlay(env.player, "http://h.example.com/a.mkv")
        env.scenePhaseChanged(.background)
        XCTAssertEqual(engine.videoSuspensions.last, true)
        env.player.resync()   // a reload (reconnect, zap) while in the background
        XCTAssertEqual(engine.loads.count, 2)
        XCTAssertEqual(engine.videoSuspensions.last, true, "the new item starts without video")
    }
}
