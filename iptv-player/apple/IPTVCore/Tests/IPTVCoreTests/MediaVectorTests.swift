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
        for (name, engine) in [("media3", PlayerEngine.media3), ("avplayer", PlayerEngine.avPlayer)] {
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
