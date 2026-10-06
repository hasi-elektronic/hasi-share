import Foundation
import IPTVCore
import XCTest
@testable import IPTVKit

/// VOD transport + resume (SCREENS §3.7): progress saving for both engines (also without a
/// reported duration), resume position, ≥ 95 % watched, seek clamping, hold-to-accelerate.
@MainActor
final class PlayerProgressTests: XCTestCase {
    private var av: FakeEngine!
    private var vlc: FakeEngine!
    private var library: LibraryRepository!
    private var clockMs: Int64 = 1_000_000

    private let movie = Movie(sourceId: "s1", id: "m7", name: "Film", url: "http://h.example.com/film.mp4")
    private let mkvMovie = Movie(sourceId: "s1", id: "m8", name: "Film MKV", url: "http://h.example.com/film.mkv")

    private func controller() throws -> PlayerController {
        let av = FakeEngine(kind: .avPlayer)
        let vlc = FakeEngine(kind: .vlcKit)
        self.av = av
        self.vlc = vlc
        library = LibraryRepository(database: try AppDatabase.inMemory())
        let engines = PlaybackEngines(avPlayer: { av }, vlc: { vlc })
        let c = PlayerController(resolver: StreamResolver(secrets: { _ in nil }, sniffer: nil, vlcAvailable: true),
                                 library: library, engines: engines)
        c.nowMs = { [unowned self] in self.clockMs }
        return c
    }

    private func request(_ movie: Movie, start: Int64? = nil) -> PlaybackRequest {
        var r = PlaybackRequest(item: .movie(movie), source: nil, startPositionMs: start)
        r.sourceFingerprint = "fp"
        return r
    }

    /// Opens and waits until the engine got the stream.
    private func open(_ c: PlayerController, _ movie: Movie, start: Int64? = nil) async throws -> FakeEngine {
        c.open(request(movie, start: start))
        for _ in 0..<200 where c.stream?.url.absoluteString != movie.url || (c.engine as? FakeEngine)?.loads.isEmpty != false {
            try await Task.sleep(for: .milliseconds(5))
        }
        let engine = try XCTUnwrap(c.engine as? FakeEngine)
        engine.isPlaying = true
        engine.emit(.playing)
        return engine
    }

    private func saved(_ movie: Movie) throws -> SyncItem? {
        try library.progress(contentKey: ContentKey.make(fingerprint: "fp", kind: .movie, itemId: movie.id))
    }

    // MARK: Saving

    func testPauseSavesProgressEvenWithoutDuration() async throws {
        let c = try controller()
        for (film, expected) in [(movie, PlayerEngine.avPlayer), (mkvMovie, .vlcKit)] {
            let engine = try await open(c, film)
            XCTAssertEqual(engine.kind, expected)
            engine.emit(.ready(duration: 0))     // engine could not tell the length
            clockMs += 1_000
            engine.emit(.time(42))
            c.togglePlayPause()
            XCTAssertFalse(engine.isPlaying)
            let item = try XCTUnwrap(try saved(film), "\(expected): saved on pause without duration")
            XCTAssertEqual(item.data.positionMs, 42_000)
            XCTAssertEqual(item.data.durationMs, 0)
        }
    }

    func testCloseAndReleaseSaveProgress() async throws {
        let c = try controller()
        var engine = try await open(c, movie)
        engine.emit(.ready(duration: 600))
        engine.emit(.time(120))
        clockMs += 2_000
        engine.emit(.time(121))   // < 10 s since the last save
        c.close()
        XCTAssertEqual(try saved(movie)?.data.positionMs, 121_000)
        XCTAssertEqual(try saved(movie)?.data.durationMs, 600_000)

        engine = try await open(c, mkvMovie)
        engine.emit(.ready(duration: 900))
        engine.emit(.time(300))
        engine.emit(.time(301.5))
        c.release()   // scene left .active
        XCTAssertEqual(try saved(mkvMovie)?.data.positionMs, 301_500)
    }

    func testSavesEveryTenSecondsWhilePlaying() async throws {
        let c = try controller()
        let engine = try await open(c, movie)
        engine.emit(.ready(duration: 600))
        engine.emit(.time(5))
        XCTAssertEqual(try saved(movie)?.data.positionMs, 5_000, "first tick saves")
        clockMs += 5_000
        engine.emit(.time(10))
        XCTAssertEqual(try saved(movie)?.data.positionMs, 5_000, "not again within 10 s")
        clockMs += 5_000
        engine.emit(.time(15))
        XCTAssertEqual(try saved(movie)?.data.positionMs, 15_000, "10 s later")
    }

    func testEnginePauseSavesProgress() async throws {
        let c = try controller()
        let engine = try await open(c, movie)
        engine.emit(.ready(duration: 600))
        engine.emit(.time(2))
        clockMs += 3_000
        engine.emit(.time(70))
        engine.emit(.paused)   // e.g. headphones unplugged
        XCTAssertEqual(try saved(movie)?.data.positionMs, 70_000)
    }

    func testNearEndIsWatched() async throws {
        let c = try controller()
        let engine = try await open(c, movie)
        engine.emit(.ready(duration: 1_000))
        engine.emit(.time(960))
        c.close()
        let item = try XCTUnwrap(try saved(movie))
        XCTAssertTrue(WatchHistory.isCompleted(positionMs: item.data.positionMs ?? 0, durationMs: item.data.durationMs ?? 0))
        XCTAssertNil(ResumePolicy.startPositionMs(positionMs: item.data.positionMs, durationMs: item.data.durationMs))

        // End of file: saved as fully watched even if the last time tick was earlier.
        let engine2 = try await open(c, mkvMovie)
        engine2.emit(.ready(duration: 1_000))
        engine2.emit(.time(900))
        engine2.emit(.ended)
        XCTAssertEqual(try saved(mkvMovie)?.data.positionMs, 1_000_000)
    }

    func testLateDurationIsUsed() async throws {
        let c = try controller()
        let engine = try await open(c, mkvMovie)
        engine.emit(.ready(duration: 0))
        engine.emit(.time(30))
        engine.emit(.ready(duration: 1_200))   // VLC: media.length known later
        XCTAssertEqual(c.duration, 1_200)
        c.close()
        XCTAssertEqual(try saved(mkvMovie)?.data.durationMs, 1_200_000)
    }

    // MARK: Resume

    func testResumePolicy() {
        XCTAssertEqual(ResumePolicy.startPositionMs(positionMs: 120_000, durationMs: 600_000), 120_000)
        XCTAssertEqual(ResumePolicy.startPositionMs(positionMs: 120_000, durationMs: 0), 120_000, "unknown duration still resumes")
        XCTAssertEqual(ResumePolicy.startPositionMs(positionMs: 120_000, durationMs: nil), 120_000)
        XCTAssertEqual(ResumePolicy.startPositionMs(positionMs: 10_000, durationMs: 600_000), 10_000)
        XCTAssertNil(ResumePolicy.startPositionMs(positionMs: 9_999, durationMs: 600_000), "< 10 s starts from the beginning")
        XCTAssertNil(ResumePolicy.startPositionMs(positionMs: 570_000, durationMs: 600_000), "≥ 95 % = watched")
        XCTAssertNil(ResumePolicy.startPositionMs(positionMs: nil, durationMs: 600_000))
    }

    func testResumeRequestStartsEngineAtSavedPosition() async throws {
        let c = try controller()
        let engine = try await open(c, movie, start: 120_000)
        XCTAssertEqual(engine.loads.last?.startMs, 120_000)
        XCTAssertEqual(c.resumedFromMs, 120_000)
        XCTAssertEqual(c.currentTime, 120, "time label starts at the resume point")
        engine.emit(.time(0.5))   // tick before the engine reached the start position
        XCTAssertEqual(c.currentTime, 120)
        c.close()
        XCTAssertEqual(try saved(movie)?.data.positionMs, 120_000, "a stale tick does not overwrite the resume position")
        _ = try await open(c, movie, start: 120_000)
        // "Play from start" drops the chip and seeks to 0.
        c.restartFromBeginning()
        XCTAssertNil(c.resumedFromMs)
        XCTAssertEqual(engine.seeks.last, 0)
    }

    // MARK: Seeking

    func testSeekByClampsToDuration() async throws {
        let c = try controller()
        let engine = try await open(c, movie)
        engine.emit(.ready(duration: 100))
        engine.emit(.time(95))
        c.seek(by: 10)
        XCTAssertLessThanOrEqual(c.currentTime, 100)
        XCTAssertGreaterThanOrEqual(c.currentTime, 98)
        clockMs += 4_000   // seek settled
        engine.emit(.time(3))
        c.seek(by: -10)
        XCTAssertEqual(c.currentTime, 0)
        XCTAssertEqual(engine.seeks.last, 0)
        // Unknown duration: forward seeks are not capped.
        engine.emit(.ready(duration: 0))
        clockMs += 4_000
        engine.emit(.time(5))
        c.seek(by: 10)
        XCTAssertEqual(c.currentTime, 15)
    }

    func testStaleTimeTicksAfterSeekDoNotJumpBack() async throws {
        let c = try controller()
        let engine = try await open(c, movie)
        engine.emit(.ready(duration: 600))
        engine.emit(.time(20))
        c.seek(by: 10)
        c.seek(by: 10)   // presses accumulate
        XCTAssertEqual(c.currentTime, 40)
        engine.emit(.time(21))   // tick from before the seek finished
        XCTAssertEqual(c.currentTime, 40)
        engine.emit(.time(40.5))
        XCTAssertEqual(c.currentTime, 40.5)
        engine.emit(.time(41.5))
        XCTAssertEqual(c.currentTime, 41.5)
    }

    func testSeekToFraction() async throws {
        let c = try controller()
        let engine = try await open(c, movie)
        engine.emit(.ready(duration: 600))
        c.seek(toFraction: 0.5)
        XCTAssertEqual(engine.seeks.last, 300)
        XCTAssertEqual(c.currentTime, 300)
    }

    // MARK: tvOS hold-to-accelerate

    func testSeekAcceleratorStepsUpAfterOneSecondHeld() {
        XCTAssertEqual(SeekAccelerator.step(direction: 1, heldMs: 0), 10, "click")
        XCTAssertEqual(SeekAccelerator.step(direction: 1, heldMs: 400), 10)
        XCTAssertEqual(SeekAccelerator.step(direction: 1, heldMs: 999), 10)
        XCTAssertEqual(SeekAccelerator.step(direction: 1, heldMs: 1_000), 30, "held ≥ 1 s")
        XCTAssertEqual(SeekAccelerator.step(direction: 1, heldMs: 5_000), 30)
        XCTAssertEqual(SeekAccelerator.step(direction: -1, heldMs: 0), -10)
        XCTAssertEqual(SeekAccelerator.step(direction: -1, heldMs: 1_300), -30)
    }
}
