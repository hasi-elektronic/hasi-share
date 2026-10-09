import Foundation
import IPTVCore
import XCTest
@testable import IPTVKit
#if canImport(MediaPlayer)
import MediaPlayer
#endif

/// Build 17 (C5 / IOS-11): Now Playing mapping and remote-command routing.
@MainActor
final class NowPlayingTests: XCTestCase {
    private let channel = Channel(sourceId: "s", id: "c1", name: "Atlas News HD", logoUrl: "http://logo.example.com/a.png")
    private let channel2 = Channel(sourceId: "s", id: "c2", name: "Rhein 24")
    private let channel3 = Channel(sourceId: "s", id: "c3", name: "Kids Planet")

    // MARK: Mapping

    func testLiveShowsProgrammeOverChannel() throws {
        let request = PlaybackRequest(item: .channel(channel), source: nil)
        let meta = try XCTUnwrap(NowPlayingMapper.metadata(request: request, phase: .playing, currentTime: 42, duration: 0,
                                                           programmeTitle: "Tagesschau"))
        XCTAssertEqual(meta.title, "Tagesschau")
        XCTAssertEqual(meta.artist, "Atlas News HD")
        XCTAssertTrue(meta.isLive)
        XCTAssertNil(meta.duration)
        XCTAssertNil(meta.elapsed, "live: no position")
        XCTAssertEqual(meta.rate, 1)
        XCTAssertEqual(meta.artworkURL?.absoluteString, "http://logo.example.com/a.png")

        let noEpg = try XCTUnwrap(NowPlayingMapper.metadata(request: request, phase: .paused, currentTime: 0, duration: 0, programmeTitle: " "))
        XCTAssertEqual(noEpg.title, "Atlas News HD")
        XCTAssertNil(noEpg.artist)
        XCTAssertEqual(noEpg.rate, 0)
    }

    func testMovieAndEpisode() throws {
        let movie = Movie(sourceId: "s", id: "m1", name: "Red Horizon (2024) HD", posterUrl: "https://img.example.com/r.jpg")
        let m = try XCTUnwrap(NowPlayingMapper.metadata(request: PlaybackRequest(item: .movie(movie), source: nil), phase: .playing,
                                                        currentTime: 61.5, duration: 5400, movieTitle: { _ in "Red Horizon" }))
        XCTAssertEqual(m.title, "Red Horizon")
        XCTAssertFalse(m.isLive)
        XCTAssertEqual(m.duration, 5400)
        XCTAssertEqual(m.elapsed, 61.5)

        let episode = Episode(sourceId: "s", id: "e2", seriesId: "x", season: 1, number: 2, title: "Low Tide")
        let e = try XCTUnwrap(NowPlayingMapper.metadata(request: PlaybackRequest(item: .episode(episode, seriesTitle: "Harbor Lights"), source: nil),
                                                        phase: .ended, currentTime: 1200, duration: 1300))
        XCTAssertEqual(e.title, "Low Tide")
        XCTAssertEqual(e.artist, "Harbor Lights")
        XCTAssertEqual(e.albumTitle, "S1 E2")
        XCTAssertEqual(e.elapsed, 1300, "ended: at the end")
        XCTAssertEqual(e.rate, 0)
        XCTAssertNil(e.duration.flatMap { $0 > 0 ? nil : $0 })

        let unknownLength = try XCTUnwrap(NowPlayingMapper.metadata(request: PlaybackRequest(item: .movie(movie), source: nil),
                                                                    phase: .buffering, currentTime: 10, duration: 0))
        XCTAssertNil(unknownLength.duration)
        XCTAssertEqual(unknownLength.rate, 1, "buffering = the user's intent to play")
    }

    func testNothingWhenIdleOrLocked() {
        let request = PlaybackRequest(item: .channel(channel), source: nil)
        XCTAssertNil(NowPlayingMapper.metadata(request: nil, phase: .playing, currentTime: 0, duration: 0))
        XCTAssertNil(NowPlayingMapper.metadata(request: request, phase: .idle, currentTime: 0, duration: 0))
        XCTAssertNil(NowPlayingMapper.metadata(request: request, phase: .locked, currentTime: 0, duration: 0))
    }

    #if canImport(MediaPlayer)
    func testInfoDictionary() {
        let meta = NowPlayingMetadata(title: "Low Tide", artist: "Harbor Lights", albumTitle: "S1 E2", isLive: false, duration: 1300,
                                      elapsed: 20, rate: 1)
        let info = meta.nowPlayingInfo
        XCTAssertEqual(info[MPMediaItemPropertyTitle] as? String, "Low Tide")
        XCTAssertEqual(info[MPMediaItemPropertyArtist] as? String, "Harbor Lights")
        XCTAssertEqual(info[MPMediaItemPropertyAlbumTitle] as? String, "S1 E2")
        XCTAssertEqual(info[MPMediaItemPropertyPlaybackDuration] as? Double, 1300)
        XCTAssertEqual(info[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double, 20)
        XCTAssertEqual(info[MPNowPlayingInfoPropertyPlaybackRate] as? Double, 1)
        XCTAssertEqual(info[MPNowPlayingInfoPropertyIsLiveStream] as? Bool, false)
        let live = NowPlayingMetadata(title: "Atlas", isLive: true, rate: 0).nowPlayingInfo
        XCTAssertEqual(live[MPNowPlayingInfoPropertyIsLiveStream] as? Bool, true)
        XCTAssertNil(live[MPMediaItemPropertyPlaybackDuration])
        XCTAssertNil(live[MPNowPlayingInfoPropertyElapsedPlaybackTime])
    }
    #endif

    // MARK: Routing

    private var av: FakeEngine!

    private func controller() -> PlayerController {
        let av = FakeEngine(kind: .avPlayer)
        self.av = av
        let e = PlaybackEngines(avPlayer: { av }, vlc: nil)
        let c = PlayerController(resolver: StreamResolver(secrets: { _ in nil }, vlcAvailable: false), library: nil, engines: e)
        c.canPlay = { true }
        return c
    }

    private func play(_ c: PlayerController, _ request: PlaybackRequest) async throws {
        c.open(request)
        for _ in 0..<200 where av.loads.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        av.isPlaying = true
        av.emit(.playing)
        XCTAssertEqual(c.phase, .playing)
    }

    func testVODCommands() async throws {
        let c = controller()
        XCTAssertEqual(c.remoteCommandAvailability, .none)
        XCTAssertFalse(c.handleRemoteCommand(.play), "nothing to play")
        try await play(c, PlaybackRequest(item: .url("http://h.example.com/film.mp4", title: "Film"), source: nil))
        av.emit(.ready(duration: 600))
        XCTAssertEqual(c.remoteCommandAvailability, RemoteCommandAvailability(playPause: true, skip: true, changePosition: true, channelSwitch: false))
        av.emit(.time(100))
        XCTAssertTrue(c.handleRemoteCommand(.skipForward(seconds: 30)))
        XCTAssertEqual(av.seeks.last, 130)
        XCTAssertTrue(c.handleRemoteCommand(.skipBackward(seconds: 10)))
        XCTAssertEqual(av.seeks.last, 120)
        XCTAssertTrue(c.handleRemoteCommand(.changePosition(seconds: 300)))
        XCTAssertEqual(av.seeks.last, 300)
        XCTAssertFalse(c.handleRemoteCommand(.nextChannel), "no channel switch on VOD")

        XCTAssertTrue(c.handleRemoteCommand(.pause))
        XCTAssertEqual(c.phase, .paused)
        XCTAssertTrue(c.handleRemoteCommand(.pause), "already paused: no toggle back")
        XCTAssertEqual(c.phase, .paused)
        XCTAssertTrue(c.handleRemoteCommand(.play))
        XCTAssertTrue(av.isPlaying)
        av.emit(.playing)
        XCTAssertTrue(c.handleRemoteCommand(.play), "already playing: no toggle")
        XCTAssertEqual(c.phase, .playing)
        XCTAssertTrue(c.handleRemoteCommand(.togglePlayPause))
        XCTAssertEqual(c.phase, .paused)
    }

    func testLiveCommands() async throws {
        let c = controller()
        try await play(c, PlaybackRequest(item: .channel(Channel(sourceId: "s", id: "c1", name: "A", url: "http://h.example.com/a.m3u8")),
                                          source: nil, channels: [channel, channel2, channel3]))
        XCTAssertEqual(c.remoteCommandAvailability, RemoteCommandAvailability(playPause: true, skip: false, changePosition: false, channelSwitch: true))
        XCTAssertFalse(c.handleRemoteCommand(.skipForward(seconds: 10)))
        XCTAssertFalse(c.handleRemoteCommand(.changePosition(seconds: 10)))
        XCTAssertTrue(c.handleRemoteCommand(.nextChannel))
        XCTAssertEqual(c.zapTarget?.id, "c2")
        XCTAssertTrue(c.handleRemoteCommand(.previousChannel))
        XCTAssertTrue(c.handleRemoteCommand(.previousChannel))
        XCTAssertEqual(c.zapTarget?.id, "c3", "wraps around the zapping list")

        let single = controller()
        try await play(single, PlaybackRequest(item: .channel(Channel(sourceId: "s", id: "c1", name: "A", url: "http://h.example.com/a.m3u8")),
                                               source: nil, channels: [channel]))
        XCTAssertFalse(single.remoteCommandAvailability.channelSwitch, "one channel: nothing to switch to")
    }

    func testPlaybackChangesAreReported() async throws {
        let c = controller()
        var count = 0
        c.onPlaybackChange = { count += 1 }
        try await play(c, PlaybackRequest(item: .url("http://h.example.com/film.mp4", title: "Film"), source: nil))
        let afterOpen = count
        XCTAssertGreaterThanOrEqual(afterOpen, 2, "item + loading/playing")
        av.emit(.ready(duration: 600))
        XCTAssertEqual(count, afterOpen + 1, "duration known")
        av.emit(.time(5))
        XCTAssertEqual(count, afterOpen + 1, "plain ticks: the system extrapolates")
        c.seek(by: 10)
        XCTAssertEqual(count, afterOpen + 2, "seek")
        c.close()
        XCTAssertNil(c.request)
        XCTAssertGreaterThan(count, afterOpen + 2, "closed: Now Playing cleared")
    }
}
