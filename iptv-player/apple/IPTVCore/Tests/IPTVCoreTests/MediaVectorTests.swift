import Foundation
import XCTest
@testable import IPTVCore

/// CONTRACT §6 – `spec/test-vectors/media/expected.json` and `stream-samples.json`.
final class MediaVectorTests: XCTestCase {
    private func expected() throws -> [String: Any] { try Vectors.object("media/expected.json") }

    func testRealFilesAreSniffedFromFirst1024Bytes() throws {
        let files = try XCTUnwrap(expected().arr("files"))
        XCTAssertEqual(files.count, 9)
        for f in files {
            let name = try XCTUnwrap(f.str("file"))
            let bytes = try Vectors.data("media/\(name)").prefix(StreamFormatDetector.sniffLength)
            // Fake URL without a useful extension so that sniffing is exercised.
            let got = StreamFormatDetector.detect(url: "http://x.example.com/stream?id=1", contentType: nil, firstBytes: Data(bytes))
            XCTAssertEqual(got.rawValue, f.str("expected"), name)
        }
    }

    func testUrlsAndContentTypes() throws {
        let urls = try XCTUnwrap(expected().arr("urls"))
        XCTAssertEqual(urls.count, 13)
        for u in urls {
            let url = try XCTUnwrap(u.str("url"))
            let contentType = u.str("contentType")
            XCTAssertEqual(StreamFormatDetector.detect(url: url, contentType: contentType).rawValue, u.str("expected"),
                           "\(url) / \(contentType ?? "nil")")
        }
    }

    func testSupportMatrix() throws {
        let support = try XCTUnwrap(expected().obj("support"))
        for (name, engine) in [("media3", PlayerEngine.media3), ("avplayer", PlayerEngine.avPlayer), ("vlckit", PlayerEngine.vlcKit)] {
            let matrix = try XCTUnwrap(support.obj(name))
            XCTAssertEqual(Set(matrix.keys), Set(StreamContainer.allCases.map(\.rawValue)), "matrix covers all containers")
            for (wire, value) in matrix {
                let container = try XCTUnwrap(StreamContainer(rawValue: wire))
                let ok = try XCTUnwrap(value as? Bool)
                XCTAssertEqual(container.isSupported(by: engine), ok, "\(name)/\(wire)")
                XCTAssertEqual(container.playbackError(for: engine), ok ? nil : .unsupportedFormat(container: wire))
            }
        }
    }

    /// CONTRACT §6.1 – Apple engine choice (AVPlayer + VLCKit) and the AVPlayer → VLCKit fallback.
    func testAppleEngineSelection() throws {
        let apple = try XCTUnwrap(expected().obj("appleEngine"))
        for (key, vlc) in [("select", true), ("selectWithoutVlc", false)] {
            let table = try XCTUnwrap(apple.obj(key))
            XCTAssertEqual(Set(table.keys), Set(StreamContainer.allCases.map(\.rawValue)), key)
            for (wire, value) in table {
                let container = try XCTUnwrap(StreamContainer(rawValue: wire))
                let want = try XCTUnwrap(value as? String)
                let got = ApplePlayback.engine(for: container, vlcAvailable: vlc)
                if want == "error:UnsupportedFormat" {
                    XCTAssertNil(got, "\(key)/\(wire)")
                    XCTAssertEqual(ApplePlayback.playbackError(for: container, vlcAvailable: vlc), .unsupportedFormat(container: wire))
                } else {
                    XCTAssertEqual(got?.rawValue, want, "\(key)/\(wire)")
                    XCTAssertNil(ApplePlayback.playbackError(for: container, vlcAvailable: vlc))
                }
            }
        }
        // Audio delay ≠ 0 → VLCKit when available; 0 → the plain tables above.
        let delay = try XCTUnwrap(apple.obj("audioDelay"))
        let delayMs = try XCTUnwrap(delay["audioDelayMs"] as? Int)
        for (key, vlc) in [("select", true), ("selectWithoutVlc", false)] {
            let table = try XCTUnwrap(delay.obj(key))
            let plain = try XCTUnwrap(apple.obj(key))
            XCTAssertEqual(Set(table.keys), Set(StreamContainer.allCases.map(\.rawValue)), "audioDelay/\(key)")
            for (wire, value) in table {
                let container = try XCTUnwrap(StreamContainer(rawValue: wire))
                let want = try XCTUnwrap(value as? String)
                let got = ApplePlayback.engine(for: container, vlcAvailable: vlc, audioDelayMs: delayMs)
                XCTAssertEqual(got?.rawValue ?? "error:UnsupportedFormat", want, "audioDelay/\(key)/\(wire)")
                let gotZero = ApplePlayback.engine(for: container, vlcAvailable: vlc, audioDelayMs: 0)
                XCTAssertEqual(gotZero?.rawValue ?? "error:UnsupportedFormat", plain.str(wire), "delay 0/\(key)/\(wire)")
            }
        }
        let errors: [String: PlaybackError] = [
            "UnsupportedFormat": .unsupportedFormat(container: "mkv"), "UnsupportedCodec": .unsupportedCodec(codec: nil),
            "Network": .network(.timeout), "StreamOffline": .streamOffline(httpStatus: 404),
            "AccessDenied": .accessDenied(httpStatus: 403), "Drm": .drm, "Unknown": .unknown(message: "x"),
        ]
        let fallback = try XCTUnwrap(apple.arr("fallback"))
        XCTAssertFalse(fallback.isEmpty)
        for f in fallback {
            let engine = try XCTUnwrap(PlayerEngine(rawValue: try XCTUnwrap(f.str("engine"))))
            let error = try XCTUnwrap(errors[try XCTUnwrap(f.str("error"))])
            XCTAssertEqual(ApplePlayback.fallbackEngine(after: error, on: engine)?.rawValue, f.str("expected"), "\(f)")
            XCTAssertNil(ApplePlayback.fallbackEngine(after: error, on: engine, vlcAvailable: false))
        }
        // Rule −1: user override – same result with and without an audio delay; no fallback.
        let override = try XCTUnwrap(apple.obj("override"))
        let overrideDelay = try XCTUnwrap(override["audioDelayMs"] as? Int)
        for mode in [PlayerEngineOverride.avPlayer, .vlcKit] {
            let tables = try XCTUnwrap(override.obj(mode.rawValue), mode.rawValue)
            for (key, vlc) in [("select", true), ("selectWithoutVlc", false)] {
                let table = try XCTUnwrap(tables.obj(key))
                XCTAssertEqual(Set(table.keys), Set(StreamContainer.allCases.map(\.rawValue)), "override/\(mode)/\(key)")
                for (wire, value) in table {
                    let container = try XCTUnwrap(StreamContainer(rawValue: wire))
                    let want = try XCTUnwrap(value as? String)
                    for delay in [0, overrideDelay] {
                        let got = ApplePlayback.engine(for: container, vlcAvailable: vlc, audioDelayMs: delay, override: mode)
                        XCTAssertEqual(got?.rawValue ?? "error:UnsupportedFormat", want, "override/\(mode)/\(key)/\(wire)/\(delay)")
                    }
                    XCTAssertEqual(ApplePlayback.playbackError(for: container, vlcAvailable: vlc, override: mode) == nil,
                                   want != "error:UnsupportedFormat", "override/\(mode)/\(key)/\(wire)")
                }
            }
        }
        for (wire, value) in try XCTUnwrap(apple.obj("select")) {
            let container = try XCTUnwrap(StreamContainer(rawValue: wire))
            XCTAssertEqual(ApplePlayback.engine(for: container, override: .automatic)?.rawValue ?? "error:UnsupportedFormat",
                           value as? String, "override auto/\(wire)")
        }
        for f in try XCTUnwrap(override.arr("fallback")) {
            let mode = try XCTUnwrap(PlayerEngineOverride(rawValue: try XCTUnwrap(f.str("override"))))
            let engine = try XCTUnwrap(PlayerEngine(rawValue: try XCTUnwrap(f.str("engine"))))
            let error = try XCTUnwrap(errors[try XCTUnwrap(f.str("error"))])
            XCTAssertEqual(ApplePlayback.fallbackEngine(after: error, on: engine, override: mode)?.rawValue, f.str("expected"), "\(f)")
        }
    }

    /// The on-device format test list must agree with detection and the AVPlayer matrix.
    func testStreamSamplesAreConsistent() throws {
        let samples = try XCTUnwrap(Vectors.object("stream-samples.json").arr("samples"))
        XCTAssertFalse(samples.isEmpty)
        for s in samples {
            let id = try XCTUnwrap(s.str("id"))
            let url = try XCTUnwrap(s.str("url"))
            let container = try XCTUnwrap(StreamContainer(rawValue: try XCTUnwrap(s.str("container"))), id)
            XCTAssertEqual(StreamFormatDetector.detect(url: url), container, id)
            let avplayer = try XCTUnwrap(s.obj("expect")?.str("avplayer"), id)
            if avplayer == "error:UnsupportedFormat" {
                XCTAssertEqual(container.playbackError(for: .avPlayer), .unsupportedFormat(container: container.rawValue), id)
            } else {
                XCTAssertNil(container.playbackError(for: .avPlayer), id)
            }
            let apple = try XCTUnwrap(s.obj("expect")?.str("apple"), id)
            if apple == "error:UnsupportedFormat" {
                XCTAssertNotNil(ApplePlayback.playbackError(for: container), id)
            } else {
                XCTAssertNil(ApplePlayback.playbackError(for: container), id)
            }
        }
    }

    func testSniffEdgeCases() {
        XCTAssertNil(StreamFormatDetector.sniff(Data([0x47, 0, 0])))
        XCTAssertEqual(StreamFormatDetector.sniff(Data("\u{FEFF}  #EXTM3U\n#EXT-X-VERSION:3".utf8)), .hls)
        XCTAssertEqual(StreamFormatDetector.sniff(Data(#"<MPD xmlns="urn:mpeg:dash">"#.utf8)), .dash)
        XCTAssertEqual(StreamFormatDetector.sniff(Data(#"<?xml version="1.0"?><MPD>"#.utf8)), .dash)
        XCTAssertEqual(StreamFormatDetector.detect(url: "http://h/x", contentType: "text/html", firstBytes: Data("<html>".utf8)), .unknown)
        // Scheme wins over everything.
        XCTAssertEqual(StreamFormatDetector.detect(url: "rtmps://h/app", contentType: "video/mp4", firstBytes: Data("#EXTM3U".utf8)), .rtmp)
        // Bytes win over content type.
        XCTAssertEqual(StreamFormatDetector.detect(url: "http://h/a.mp4", contentType: "video/mp4", firstBytes: Data("#EXTM3U\n".utf8)), .hls)
    }
}
