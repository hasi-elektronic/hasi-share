import XCTest
@testable import IPTVCore

/// M3U catch-up playback URLs (CONTRACT §3.9, audit C11): every `catchup` type + the template placeholders.
final class CatchupURLBuilderTests: XCTestCase {
    // 2026-10-09 18:30:00 UTC … 20:00:00 UTC (90 min), "now" = 21:00:00 UTC.
    let start = Date(timeIntervalSince1970: 1_791_570_600)
    var end: Date { start.addingTimeInterval(90 * 60) }
    var now: Date { start.addingTimeInterval(150 * 60) }

    private func build(_ url: String, _ type: CatchupType, source: String? = nil) -> String? {
        CatchupURLBuilder.url(channelURL: url, catchup: CatchupInfo(type: type, days: 3, source: source),
                              start: start, end: end, now: now)
    }

    func testFixtureTimesAreWhatTheTestsAssume() {
        XCTAssertEqual(CatchupURLBuilder.format("{Y}-{m}-{d} {H}:{M}:{S}", start: start, end: end, now: now), "2026-10-09 18:30:00")
    }

    func testDefaultWithTemplateReplacesEveryPlaceholder() {
        let url = build("http://p.tv/live/ch1.m3u8", .default,
                        source: "http://arch.tv/ch1/{utc}/{utcend}/{lutc}/{duration}/{duration:60}/{offset:60}/{Y}{m}{d}{H}{M}{S}.m3u8")
        XCTAssertEqual(url, "http://arch.tv/ch1/1791570600/1791576000/1791579600/5400/90/150/20261009183000.m3u8")
    }

    func testDollarPlaceholdersAndFormattedTimes() {
        let url = build("http://p.tv/ch1.ts", .default,
                        source: "http://arch.tv/ch1?s=${start}&e=${end}&n=${now}&t=${timestamp}&d=${duration}&o=${offset}&f=${start:Y-m-d:H-M}&g={utc:Y/m/d}&h={utcend:H-M}")
        XCTAssertEqual(url, "http://arch.tv/ch1?s=1791570600&e=1791576000&n=1791579600&t=1791579600&d=5400&o=9000&f=2026-10-09:18-30&g=2026/10/09&h=20-00")
    }

    func testAppendAddsTheFilledSourceToTheStreamURL() {
        XCTAssertEqual(build("http://p.tv/live/ch1.m3u8", .append, source: "?utc={utc}&lutc={lutc}"),
                       "http://p.tv/live/ch1.m3u8?utc=1791570600&lutc=1791579600")
        XCTAssertEqual(build("http://p.tv/live/ch1.m3u8?token=a", .append, source: "&utc={utc}"),
                       "http://p.tv/live/ch1.m3u8?token=a&utc=1791570600")
    }

    func testShiftAddsUtcAndLutcParameters() {
        XCTAssertEqual(build("http://p.tv/live/ch1.m3u8", .shift), "http://p.tv/live/ch1.m3u8?utc=1791570600&lutc=1791579600")
        XCTAssertEqual(build("http://p.tv/live/ch1.m3u8?token=a", .shift), "http://p.tv/live/ch1.m3u8?token=a&utc=1791570600&lutc=1791579600")
    }

    func testFlussonicHLSAndMpegts() {
        XCTAssertEqual(build("http://fs.tv:8080/ch1/index.m3u8?token=a", .flussonic), "http://fs.tv:8080/ch1/index-1791570600-5400.m3u8?token=a")
        XCTAssertEqual(build("http://fs.tv/ch1/video.m3u8", .flussonic), "http://fs.tv/ch1/video-1791570600-5400.m3u8")
        XCTAssertEqual(build("http://fs.tv/ch1/mono.m3u8", .flussonic), "http://fs.tv/ch1/mono-1791570600-5400.m3u8")
        XCTAssertEqual(build("http://fs.tv/ch1/mpegts?token=a", .flussonic), "http://fs.tv/ch1/archive-1791570600-5400.ts?token=a")
        XCTAssertEqual(build("http://fs.tv/ch1/mpegts", .flussonic), "http://fs.tv/ch1/archive-1791570600-5400.ts")
        XCTAssertNil(build("http://fs.tv/", .flussonic), "no stream name → no archive URL")
        XCTAssertEqual(build("http://fs.tv/ch1/index.m3u8", .flussonic, source: "http://fs.tv/ch1/timeshift_abs-{utc}.ts"),
                       "http://fs.tv/ch1/timeshift_abs-1791570600.ts", "an explicit catchup-source wins")
    }

    func testXtreamShapedStreamURL() {
        XCTAssertEqual(build("http://xc.tv:8080/live/user/pa%20ss/123.ts", .xtream),
                       "http://xc.tv:8080/timeshift/user/pa%20ss/90/2026-10-09:18-30/123.ts")
        XCTAssertEqual(build("http://xc.tv/user/pass/123.m3u8", .xtream), "http://xc.tv/timeshift/user/pass/90/2026-10-09:18-30/123.m3u8")
        XCTAssertNil(build("http://xc.tv/channel.m3u8", .xtream))
    }

    func testDefaultWithoutSourceDetectsTheServerKind() {
        // Placeholders in the stream URL itself.
        XCTAssertEqual(build("http://p.tv/ch1.m3u8?start={utc}&end={utcend}", .default), "http://p.tv/ch1.m3u8?start=1791570600&end=1791576000")
        // Xtream-shaped → timeshift; Flussonic-shaped → archive; anything else → utc/lutc parameters.
        XCTAssertEqual(build("http://xc.tv/live/u/p/7.ts", .default), "http://xc.tv/timeshift/u/p/90/2026-10-09:18-30/7.ts")
        XCTAssertEqual(build("http://fs.tv/ch1/index.m3u8", .default), "http://fs.tv/ch1/index-1791570600-5400.m3u8")
        XCTAssertEqual(build("https://cdn.tv/a/bipbop_variant.m3u8?ch=atlas", .default),
                       "https://cdn.tv/a/bipbop_variant.m3u8?ch=atlas&utc=1791570600&lutc=1791579600")
    }

    func testNoneAndNonHTTPGiveNil() {
        XCTAssertNil(build("http://p.tv/ch1.m3u8", .none))
        XCTAssertNil(build("udp://239.0.0.1:1234", .shift))
        XCTAssertNil(build("", .default, source: nil))
    }

    func testRunningProgrammeStartsFromItsBeginning() {
        // "Von Anfang an": the programme is still on air (end in the future) – duration stays the programme's.
        let onAirNow = start.addingTimeInterval(30 * 60)
        let url = CatchupURLBuilder.url(channelURL: "http://p.tv/ch.m3u8", catchup: CatchupInfo(type: .default, days: 1, source: "?s={utc}&d={duration}&o={offset}"),
                                        start: start, end: end, now: onAirNow)
        XCTAssertEqual(url, "http://p.tv/ch.m3u8?s=1791570600&d=5400&o=1800")
    }

    func testRelativeAppendSourceStaysRelativeToTheStream() {
        // `default` with a source that is not an absolute URL behaves like `append`.
        XCTAssertEqual(build("http://p.tv/ch.m3u8", .default, source: "?utc={utc}"), "http://p.tv/ch.m3u8?utc=1791570600")
    }
}
