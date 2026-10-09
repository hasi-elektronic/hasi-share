import Foundation
import XCTest
@testable import IPTVCore

/// CONTRACT §3.12: streaming parse of a 200 000-entry playlist, generated in memory chunk by
/// chunk (the whole file never exists as one buffer), in batches of ≤ 1000.
final class M3UPerformanceTests: XCTestCase {
    static let entryCount = 200_000

    /// Generates the playlist in ~64 KiB chunks.
    private func forEachChunk(_ body: (Data) throws -> Void) rethrows {
        var chunk = Data("#EXTM3U url-tvg=\"http://epg.example.com/guide.xml.gz\"\n".utf8)
        chunk.reserveCapacity(80 * 1024)
        for i in 0..<Self.entryCount {
            let line: String
            switch i % 10 {
            case 0:
                line = "#EXTINF:-1 tvg-id=\"ch\(i).tr\" tvg-name=\"Kanal \(i)\" tvg-logo=\"http://logo.example.com/\(i).png\" group-title=\"Grup \(i % 50)\" catchup=\"default\" catchup-days=\"3\",Kanal \(i) HD\nhttp://iptv.example.com:8080/live/user/pass/\(i).ts\n"
            case 1:
                line = "#EXTINF:7200 group-title=\"Filmler\",Film \(i) (2020)\nhttp://iptv.example.com:8080/movie/user/pass/\(i).mkv\n"
            case 2:
                line = "#EXTINF:-1 group-title=\"Diziler\",Dizi \(i % 300) S0\(i % 9 + 1)E\(i % 30 + 1)\nhttp://iptv.example.com:8080/series/user/pass/\(i).mp4\n"
            default:
                line = "#EXTINF:-1 tvg-id=\"c\(i)\" group-title='Ulusal, Eğlence',Çocuk Kanalı \(i)\n#EXTVLCOPT:http-user-agent=VLC/3.0\nhttp://cdn.example.com/hls/\(i)/index.m3u8\n"
            }
            chunk.append(contentsOf: line.utf8)
            if chunk.count >= 64 * 1024 {
                try body(chunk)
                chunk.removeAll(keepingCapacity: true)
            }
        }
        if !chunk.isEmpty { try body(chunk) }
    }

    func testParse200kEntriesStreaming() throws {
        let started = Date()
        var parser = M3UStreamParser()
        var builder = M3UCatalogBuilder(sourceId: "perf")
        var entries = 0, batches = 0, maxBatch = 0
        var channels = 0, movies = 0, episodes = 0, series = 0, categories = 0
        let onBatch: ([M3UEntry]) throws -> Void = { batch in
            entries += batch.count
            batches += 1
            maxBatch = max(maxBatch, batch.count)
            let mapped = builder.add(batch)
            channels += mapped.channels.count
            movies += mapped.movies.count
            episodes += mapped.episodes.count
            series += mapped.series.count
            categories += mapped.categories.count
        }
        try forEachChunk { try parser.consume($0, onBatch: onBatch) }
        let summary = try parser.finish(onBatch: onBatch)
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertEqual(entries, Self.entryCount)
        XCTAssertEqual(summary.entryCount, Self.entryCount)
        XCTAssertEqual(summary.skipped, 0)
        XCTAssertEqual(summary.epgUrls, ["http://epg.example.com/guide.xml.gz"])
        XCTAssertEqual(maxBatch, M3UPlaylist.defaultBatchSize)
        XCTAssertEqual(batches, Self.entryCount / M3UPlaylist.defaultBatchSize)
        XCTAssertEqual(channels, Self.entryCount / 10 * 8)
        XCTAssertEqual(movies, Self.entryCount / 10)
        XCTAssertEqual(episodes, Self.entryCount / 10)
        XCTAssertEqual(series, 30, "i ≡ 2 (mod 10) → 30 distinct values of i % 300")
        XCTAssertEqual(categories, 5 + 3, "5 live groups (i % 50 for i ≡ 0 mod 10) + Filmler, Diziler, Ulusal/Eğlence")
        // Generous bound: debug builds on CI are slow; release parses this in well under 2 s.
        XCTAssertLessThan(elapsed, 30, "200k entries took \(elapsed) s")
        print("M3U 200k streaming parse + mapping: \(String(format: "%.2f", elapsed)) s")
    }
}
