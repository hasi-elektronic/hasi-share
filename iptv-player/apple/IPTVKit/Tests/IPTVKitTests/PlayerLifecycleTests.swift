import Foundation
import IPTVCore
import XCTest
@testable import IPTVKit

/// Build 16: B2 (screen stays on while any engine plays) and B4 (only `.background` releases the player).
@MainActor
final class PlayerLifecycleTests: XCTestCase {
    private var av: FakeEngine!
    private var vlc: FakeEngine!

    private func makeEnv() throws -> AppEnvironment {
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

    func testInactiveKeepsPlayingOnlyBackgroundReleases() async throws {
        let env = try makeEnv()
        let engine = try await openAndPlay(env.player, "http://h.example.com/live/1.m3u8")
        env.scenePhaseChanged(.inactive)   // Control Center, notification shade, call banner
        XCTAssertEqual(engine.stops, 0, "not released on .inactive")
        XCTAssertEqual(env.player.phase, .playing)
        env.scenePhaseChanged(.active)
        XCTAssertEqual(engine.loads.count, 1, "nothing reopened after a mere .inactive")
        env.scenePhaseChanged(.inactive)
        env.scenePhaseChanged(.background)
        XCTAssertEqual(engine.stops, 1, "released in the background")
        XCTAssertEqual(env.player.phase, .idle)
        env.scenePhaseChanged(.inactive)
        env.scenePhaseChanged(.active)
        for _ in 0..<200 where engine.loads.count < 2 { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(engine.loads.count, 2, "reopened when active again")
    }

    func testDisplayStaysAwakeOnlyWhilePlaying() async throws {
        let env = try makeEnv()
        var calls: [Bool] = []
        env.player.keepDisplayAwake = { calls.append($0) }
        let engine = try await openAndPlay(env.player, "http://h.example.com/film.mkv")
        XCTAssertEqual(env.player.engineKind, .vlcKit, "VLCKit (libVLC never disables the idle timer itself)")
        XCTAssertEqual(calls, [true], "loading → playing: one switch on")
        env.player.togglePlayPause()
        XCTAssertEqual(calls.last, false, "paused: auto-lock allowed")
        env.player.togglePlayPause()
        engine.emit(.playing)
        XCTAssertEqual(calls.last, true)
        engine.emit(.buffering)
        XCTAssertEqual(calls.count, 3, "buffering keeps it on (no extra call)")
        engine.emit(.ended)
        XCTAssertEqual(calls.last, false, "ended")
        env.player.close()
        XCTAssertEqual(calls.last, false)
        for phase: PlayerPhase in [.playing, .buffering, .loading, .reconnecting(attempt: 1, max: 5)] {
            XCTAssertTrue(PlayerController.keepsDisplayAwake(phase), "\(phase)")
        }
        for phase: PlayerPhase in [.idle, .paused, .ended, .locked, .failed(.network(.timeout))] {
            XCTAssertFalse(PlayerController.keepsDisplayAwake(phase), "\(phase)")
        }
    }
}
