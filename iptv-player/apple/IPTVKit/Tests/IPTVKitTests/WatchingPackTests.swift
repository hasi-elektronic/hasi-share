import Foundation
import IPTVCore
import XCTest
@testable import IPTVKit

/// Build 16 "watching pack": next-episode resolution + autoplay card, sleep timer, subtitle style / delay.
final class NextEpisodeResolutionTests: XCTestCase {
    private func ep(_ season: Int, _ number: Int, id: String? = nil) -> Episode {
        Episode(sourceId: "s", id: id ?? "e\(season)x\(number)", seriesId: "100", season: season, number: number, title: "T\(season).\(number)")
    }

    func testSameSeasonSeasonBoundaryGapsAndLast() {
        let list = [ep(2, 1), ep(1, 2), ep(1, 1), ep(1, 4), ep(4, 1), ep(4, 2)]   // unsorted, S3 missing, S1E3 missing
        XCTAssertEqual(NextEpisode.after(ep(1, 1), in: list)?.id, "e1x2", "same season")
        XCTAssertEqual(NextEpisode.after(ep(1, 2), in: list)?.id, "e1x4", "number gap skipped")
        XCTAssertEqual(NextEpisode.after(ep(1, 4), in: list)?.id, "e2x1", "season boundary → next season's first")
        XCTAssertEqual(NextEpisode.after(ep(2, 1), in: list)?.id, "e4x1", "missing season skipped")
        XCTAssertNil(NextEpisode.after(ep(4, 2), in: list), "last episode")
        XCTAssertNil(NextEpisode.after(ep(1, 1), in: []), "empty (lazily loaded) list")
        XCTAssertNil(NextEpisode.after(ep(9, 9), in: list), "not in the list")
        XCTAssertEqual(NextEpisode.after(ep(1, 4, id: "old-id"), in: list)?.id, "e2x1", "found by season/number after a re-fetch")
    }
}

@MainActor
final class NextEpisodeProviderTests: XCTestCase {
    private func makeEnv() throws -> AppEnvironment {
        let config = AppConfig(displayName: "Test", bundleId: "de.hasielektronik.novaplayer", appVersion: "1.0",
                               backendBaseURL: URL(string: "http://127.0.0.1:9")!, productIDs: ProductIDs(lifetime: "l", trial: "t"),
                               licenseKeysJSON: TestSigner().jwkSetJSON, platform: .ios, rawDeviceId: "device", deviceName: "Test")
        return try AppEnvironment(config: config, database: AppDatabase.inMemory(), secureStore: InMemorySecureStore(),
                                  kv: InMemoryKeyValueStore(), engines: PlaybackEngines(avPlayer: { FakeEngine(kind: .avPlayer) }, vlc: nil))
    }

    private actor Calls { var n = 0; func add() { n += 1 } }

    /// Xtream episodes are loaded lazily (`get_series_info`): an empty stored list asks the panel, stores the
    /// answer, and the next lookup is served from the database.
    func testLazilyLoadedXtreamEpisodes() async throws {
        let env = try makeEnv()
        let secrets = SourceSecrets.xtream(XtreamSecrets(serverUrl: "http://panel.example.com", username: "u", password: "p"))
        let source = Source.make(name: "Panel", secrets: secrets, id: "s")
        try env.sourceRepository.save(source, secrets: secrets)
        env.reloadSources()
        let calls = Calls()
        let remote = [
            Episode(sourceId: "s", id: "101", seriesId: "100", season: 1, number: 1, title: "A"),
            Episode(sourceId: "s", id: "102", seriesId: "100", season: 1, number: 2, title: "B"),
            Episode(sourceId: "s", id: "201", seriesId: "100", season: 2, number: 1, title: "C"),
        ]
        let loader: SeriesInfoLoader = { sourceId, seriesId, _ in
            await calls.add()
            XCTAssertEqual(sourceId, "s")
            XCTAssertEqual(seriesId, "100")
            return remote
        }
        let next = await env.nextEpisode(after: remote[1], loadSeriesInfo: loader)
        XCTAssertEqual(next?.id, "201", "season boundary from the lazily loaded list")
        let calledOnce = await calls.n
        XCTAssertEqual(calledOnce, 1)
        XCTAssertEqual(try env.catalog.episodes(sourceId: "s", seriesId: "100").count, 3, "stored for the next lookup")
        let again = await env.nextEpisode(after: remote[0], loadSeriesInfo: loader)
        XCTAssertEqual(again?.id, "102")
        let stillOnce = await calls.n
        XCTAssertEqual(stillOnce, 1, "served from the database")
        // The last stored episode asks the panel again (a new episode may have been published).
        let none = await env.nextEpisode(after: remote[2], loadSeriesInfo: loader)
        XCTAssertNil(none)
        let twice = await calls.n
        XCTAssertEqual(twice, 2)
    }

    func testM3USeriesNeverCallsThePanel() async throws {
        let env = try makeEnv()
        let e = Episode(sourceId: "m3u", id: "1", seriesId: "x", season: 1, number: 1, title: "A")
        let next = await env.nextEpisode(after: e, loadSeriesInfo: { _, _, _ in XCTFail("no panel for M3U"); return [] })
        XCTAssertNil(next)
    }
}

@MainActor
final class UpNextControllerTests: XCTestCase {
    private var av: FakeEngine!
    private var library: LibraryRepository!

    private func episode(_ n: Int, season: Int = 1) -> Episode {
        Episode(sourceId: "s", id: "e\(season)-\(n)", seriesId: "100", season: season, number: n, title: "Ep \(n)",
                url: "http://h.example.com/s\(season)e\(n).mp4")
    }

    private func controller(next: Episode?, autoplay: Bool = true) throws -> PlayerController {
        let av = FakeEngine(kind: .avPlayer)
        self.av = av
        library = LibraryRepository(database: try AppDatabase.inMemory())
        let c = PlayerController(resolver: StreamResolver(secrets: { _ in nil }, sniffer: nil, vlcAvailable: false),
                                 library: library, engines: PlaybackEngines(avPlayer: { av }, vlc: nil))
        let prefs = PlayerPreferences(kv: InMemoryKeyValueStore())
        prefs.autoplayNextEpisode = autoplay
        c.preferences = prefs
        c.nextEpisodeProvider = { _ in next }
        c.upNextCountdownSeconds = 1
        return c
    }

    private func open(_ c: PlayerController, _ e: Episode) async throws {
        var r = PlaybackRequest(item: .episode(e, seriesTitle: "Show"), source: nil)
        r.sourceFingerprint = "fp"
        let before = av.loads.count
        c.open(r)
        for _ in 0..<200 where av.loads.count == before { try await Task.sleep(for: .milliseconds(5)) }
        av.isPlaying = true
        av.emit(.playing)
        av.emit(.ready(duration: 600))
    }

    private func settle() async throws { for _ in 0..<5 { try await Task.sleep(for: .milliseconds(10)) } }

    func testCardInTheCreditsCountsDownAndPlaysTheNextEpisode() async throws {
        let next = episode(1, season: 2)
        let c = try controller(next: next)
        try await open(c, episode(8))
        av.emit(.time(400))
        try await settle()
        XCTAssertNil(c.upNext, "not before the end")
        av.emit(.time(520))   // 80 s left: lookup
        try await settle()
        XCTAssertNil(c.upNext)
        av.emit(.time(575))   // 25 s left: credits
        let card = try XCTUnwrap(c.upNext)
        XCTAssertEqual(card.episode, next)
        XCTAssertNotNil(card.deadlineMs, "counting down")
        for _ in 0..<200 where av.loads.count < 2 { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(av.loads.last?.url.absoluteString, "http://h.example.com/s2e1.mp4", "next season's first episode plays")
        XCTAssertNil(c.upNext)
        let watched = try XCTUnwrap(try library.progress(contentKey: ContentKey.make(fingerprint: "fp", kind: .episode, itemId: "e1-8")))
        XCTAssertEqual(watched.data.positionMs, 600_000, "the finished episode counts as watched")
    }

    func testCancelKeepsTheEpisodeAndSeekBackHidesTheCard() async throws {
        let c = try controller(next: episode(2))
        try await open(c, episode(1))
        av.emit(.time(520))
        try await settle()
        av.emit(.time(580))
        XCTAssertNotNil(c.upNext)
        av.emit(.time(300))   // the user seeks back out of the credits
        XCTAssertNil(c.upNext, "hidden again")
        av.emit(.time(585))
        XCTAssertNotNil(c.upNext, "shown again in the credits")
        c.dismissUpNext()
        XCTAssertNil(c.upNext)
        av.emit(.time(590))
        av.isPlaying = false
        av.emit(.ended)
        try await settle()
        XCTAssertNil(c.upNext, "cancelled for this episode – not even at the end")
        try await Task.sleep(for: .milliseconds(1200))
        XCTAssertEqual(av.loads.count, 1, "nothing autoplayed")
    }

    func testAtTheEndWithoutDurationAndAutoplayOff() async throws {
        let c = try controller(next: episode(2), autoplay: false)
        var r = PlaybackRequest(item: .episode(episode(1), seriesTitle: "Show"), source: nil)
        r.sourceFingerprint = "fp"
        c.open(r)
        for _ in 0..<200 where av.loads.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        av.emit(.playing)
        av.emit(.time(42))   // unknown duration: no credits window
        av.emit(.ended)
        for _ in 0..<100 where c.upNext == nil { try await Task.sleep(for: .milliseconds(5)) }
        let card = try XCTUnwrap(c.upNext, "card at the end")
        XCTAssertNil(card.deadlineMs, "autoplay off: no countdown")
        try await Task.sleep(for: .milliseconds(1200))
        XCTAssertEqual(av.loads.count, 1)
        c.playNextEpisode()
        for _ in 0..<200 where av.loads.count < 2 { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(av.loads.last?.url.absoluteString, "http://h.example.com/s1e2.mp4")
    }

    func testPauseStopsTheCountdownAndLastEpisodeHasNoCard() async throws {
        let c = try controller(next: episode(2))
        try await open(c, episode(1))
        av.emit(.time(520))
        try await settle()
        av.emit(.time(580))
        XCTAssertNotNil(c.upNext?.deadlineMs)
        c.togglePlayPause()
        XCTAssertNotNil(c.upNext)
        XCTAssertNil(c.upNext?.deadlineMs, "paused countdown")
        try await Task.sleep(for: .milliseconds(1200))
        XCTAssertEqual(av.loads.count, 1)

        let last = try controller(next: nil)
        try await open(last, episode(9))
        av.emit(.time(520))
        try await settle()
        av.emit(.time(590))
        XCTAssertNil(last.upNext, "no next episode → no card")
    }
}

@MainActor
final class SleepTimerTests: XCTestCase {
    private func controller(_ engine: FakeEngine) -> PlayerController {
        let c = PlayerController(resolver: StreamResolver(secrets: { _ in nil }, sniffer: nil, vlcAvailable: true),
                                 library: nil, engines: PlaybackEngines(avPlayer: { engine }, vlc: { engine }))
        c.sleepTimerMinuteMs = 40
        c.sleepFadeMs = 20
        return c
    }

    private func play(_ c: PlayerController, _ engine: FakeEngine, _ item: PlaybackRequest.Item) async throws {
        c.open(PlaybackRequest(item: item, source: nil))
        for _ in 0..<200 where engine.loads.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        engine.isPlaying = true
        engine.emit(.playing)
    }

    func testVODFadesThenPauses() async throws {
        let engine = FakeEngine(kind: .avPlayer)
        let c = controller(engine)
        var awake: [Bool] = []
        c.keepDisplayAwake = { awake.append($0) }
        try await play(c, engine, .url("http://h.example.com/film.mp4", title: "F"))
        c.setSleepTimer(.minutes(15))
        XCTAssertEqual(c.sleepTimer?.mode, .minutes(15))
        XCTAssertNotNil(c.sleepTimer?.deadlineMs)
        for _ in 0..<300 where c.phase != .paused { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(c.phase, .paused, "paused at expiry")
        XCTAssertFalse(engine.isPlaying)
        XCTAssertNil(c.sleepTimer)
        XCTAssertEqual(c.sleepTimerFiredCount, 1)
        let fade = engine.volumes.filter { $0 < 1 }
        XCTAssertEqual(fade.first ?? -1, 0.9, accuracy: 0.001)
        XCTAssertEqual(fade.last ?? -1, 0, accuracy: 0.001, "faded to silence")
        XCTAssertEqual(engine.volumes.last, 1, "volume back for the next play")
        XCTAssertEqual(awake.last, false, "the device may sleep again")
    }

    func testLiveStopsAndPlayReopens() async throws {
        let engine = FakeEngine(kind: .avPlayer)
        let c = controller(engine)
        let channel = Channel(sourceId: "s", id: "1", name: "C", url: "http://h.example.com/live/1.m3u8")
        try await play(c, engine, .channel(channel))
        c.setSleepTimer(.endOfItem)
        XCTAssertNil(c.sleepTimer, "no 'end of episode' on live")
        c.setSleepTimer(.minutes(1))
        for _ in 0..<300 where c.phase != .paused { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(c.phase, .paused)
        XCTAssertGreaterThanOrEqual(engine.stops, 1, "live is stopped, not paused")
        c.togglePlayPause()
        for _ in 0..<200 where engine.loads.count < 2 { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(engine.loads.count, 2, "play opens the channel again")
    }

    func testEndOfItemStopsAtTheEndAndOffCancels() async throws {
        let engine = FakeEngine(kind: .avPlayer)
        let c = controller(engine)
        try await play(c, engine, .url("http://h.example.com/film.mp4", title: "F"))
        c.setSleepTimer(.endOfItem)
        XCTAssertEqual(c.sleepTimer, SleepTimerState(mode: .endOfItem, deadlineMs: nil))
        engine.emit(.ended)
        XCTAssertNil(c.sleepTimer)
        XCTAssertEqual(c.sleepTimerFiredCount, 1)
        c.setSleepTimer(.minutes(1))
        c.setSleepTimer(nil)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(c.sleepTimerFiredCount, 1, "off cancels")
    }
}

@MainActor
final class SubtitleStyleTests: XCTestCase {
    func testMappingToBothEngines() {
        XCTAssertEqual(SubtitleStyleMapping.relativeFontSizePercent(.small), 75)
        XCTAssertEqual(SubtitleStyleMapping.relativeFontSizePercent(.extraLarge), 165)
        XCTAssertEqual(SubtitleStyleMapping.foregroundARGB(.yellow), [1, 1, 0.92, 0.23])
        XCTAssertNil(SubtitleStyleMapping.backgroundARGB(.none))
        XCTAssertEqual(SubtitleStyleMapping.backgroundARGB(.solid), [1, 0, 0, 0])
        XCTAssertEqual(SubtitleStyleMapping.vlcOptions(SubtitleStyle(size: .large, color: .yellow, background: .semi)),
                       [":freetype-rel-fontsize=12", ":freetype-color=16771899", ":freetype-background-opacity=140",
                        ":freetype-background-color=0"])
        XCTAssertEqual(SubtitleStyleMapping.vlcOptions(SubtitleStyle()).first, ":freetype-rel-fontsize=16")
        XCTAssertTrue(SubtitleStyle().isDefault)
        #if canImport(AVFoundation)
        XCTAssertNil(AVPlayerEngine.textStyleRules(SubtitleStyle()), "default: no rules (the system style applies)")
        XCTAssertEqual(AVPlayerEngine.textStyleRules(SubtitleStyle(size: .large))?.count, 1)
        #endif
    }

    func testPreferencesPersist() {
        let kv = InMemoryKeyValueStore()
        let prefs = PlayerPreferences(kv: kv)
        XCTAssertTrue(prefs.autoplayNextEpisode, "default on")
        prefs.autoplayNextEpisode = false
        prefs.subtitleStyle = SubtitleStyle(size: .extraLarge, color: .yellow, background: .solid)
        let again = PlayerPreferences(kv: kv)
        XCTAssertFalse(again.autoplayNextEpisode)
        XCTAssertEqual(again.subtitleStyle, SubtitleStyle(size: .extraLarge, color: .yellow, background: .solid))
    }

    func testStyleAndDelayReachTheEngines() async throws {
        let av = FakeEngine(kind: .avPlayer)
        let vlc = FakeEngine(kind: .vlcKit)
        let c = PlayerController(resolver: StreamResolver(secrets: { _ in nil }, sniffer: nil, vlcAvailable: true),
                                 library: nil, engines: PlaybackEngines(avPlayer: { av }, vlc: { vlc }))
        c.preferences = PlayerPreferences(kv: InMemoryKeyValueStore())
        // AVPlayer: applied in place, no reload; no subtitle delay.
        c.open(PlaybackRequest(item: .url("http://h.example.com/film.mp4", title: "F"), source: nil))
        for _ in 0..<200 where av.loads.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        av.emit(.playing)
        av.emit(.tracks(audio: [], subtitles: [MediaOption(id: 0, name: "Türkçe", languageCode: "tr")], selectedAudio: nil, selectedSubtitle: 0))
        XCTAssertFalse(c.supportsSubtitleDelay)
        let big = SubtitleStyle(size: .large)
        c.setSubtitleStyle(big)
        XCTAssertEqual(av.subtitleStyles.last, big)
        XCTAssertEqual(av.loads.count, 1)
        XCTAssertEqual(c.subtitleStyle, big, "stored")
        // VLCKit: the next load starts with the style; a change with a showing track reopens in place.
        c.open(PlaybackRequest(item: .url("http://h.example.com/film.mkv", title: "M"), source: nil))
        for _ in 0..<200 where vlc.loads.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(vlc.subtitleStyles.last, big, "applied before the load")
        vlc.emit(.playing)
        XCTAssertTrue(c.supportsSubtitleDelay)
        c.setSubtitleDelay(1_234)
        XCTAssertEqual(c.subtitleDelayMs, 1_200, "100 ms steps")
        XCTAssertEqual(vlc.subtitleDelays.last, 1_200)
        c.setSubtitleDelay(99_999)
        XCTAssertEqual(c.subtitleDelayMs, 10_000, "clamped")
        c.setSubtitleStyle(SubtitleStyle(color: .yellow))
        XCTAssertEqual(vlc.loads.count, 1, "no subtitle track showing: no reload")
        vlc.emit(.tracks(audio: [], subtitles: [MediaOption(id: 0, name: "Türkçe", languageCode: "tr")], selectedAudio: nil, selectedSubtitle: 0))
        c.setSubtitleStyle(SubtitleStyle(color: .yellow, background: .solid))
        XCTAssertEqual(vlc.loads.count, 2, "showing subtitles: reopened in place")
        XCTAssertEqual(vlc.subtitleDelays.last, 10_000, "delay kept for the reopened item")
    }
}
