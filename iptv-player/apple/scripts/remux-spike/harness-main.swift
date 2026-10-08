import AVFoundation
import CNovaRemux
import Foundation

// Developer harness (macOS): remux server + segment dump + AVPlayer measurements.
// usage: harness <url> dump <dir> [--transcode]
//        harness <url> avplayer [--transcode]
//        harness <url> serve [--transcode]

setvbuf(stdout, nil, _IONBF, 0)
let args = CommandLine.arguments
let url = URL(string: args[1])!
let mode = args[2]
let transcode = args.contains("--transcode")

func now() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e6 }

@MainActor
final class Bench: NSObject {
    var player: AVPlayer!
    var output: AVPlayerItemVideoOutput!

    func run(master: URL, duration: Double) async {
        let t0 = now()
        let item = AVPlayerItem(url: master)
        output = AVPlayerItemVideoOutput(pixelBufferAttributes: nil)
        item.add(output)
        player = AVPlayer(playerItem: item)
        player.automaticallyWaitsToMinimizeStalling = true
        player.play()
        // first frame: a decoded pixel buffer is available and time advances
        while now() - t0 < 20000 {
            if item.status == .failed { print("FAILED \(String(describing: item.error))"); return }
            let t = player.currentTime()
            if output.hasNewPixelBuffer(forItemTime: t), player.timeControlStatus == .playing, t.seconds > 0 { break }
            try? await Task.sleep(for: .milliseconds(5))
        }
        print(String(format: "TTFF %.0f ms (status=%d tcs=%d t=%.3f)", now() - t0, item.status.rawValue,
                     player.timeControlStatus.rawValue, player.currentTime().seconds))
        try? await Task.sleep(for: .seconds(3))
        for fraction in [0.1, 0.5, 0.9] {
            let target = duration * fraction
            let s0 = now()
            var done = false
            player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .positiveInfinity,
                        toleranceAfter: .positiveInfinity) { _ in done = true }
            while !done { try? await Task.sleep(for: .milliseconds(2)) }
            let seekDone = now() - s0
            let base = player.currentTime().seconds
            while now() - s0 < 20000 {
                if player.timeControlStatus == .playing, player.currentTime().seconds > base + 0.05 { break }
                try? await Task.sleep(for: .milliseconds(5))
            }
            print(String(format: "SEEK %.0f%% → %.1f s: seek-complete %.0f ms, playing %.0f ms (t=%.2f)", fraction * 100, target,
                         seekDone, now() - s0, player.currentTime().seconds))
            try? await Task.sleep(for: .seconds(3))
        }
        if let log = item.accessLog() {
            for e in log.events {
                print(String(format: "ACCESS stalls=%d dropped=%d startup=%.3f indicated=%.0f observed=%.0f segs=%d",
                             e.numberOfStalls, e.numberOfDroppedVideoFrames, e.startupTime, e.indicatedBitrate, e.observedBitrate,
                             e.numberOfMediaRequests))
            }
        }
        if let log = item.errorLog() {
            for e in log.events { print("ERRORLOG \(e.errorStatusCode) \(e.errorDomain) \(e.errorComment ?? "")") }
        }
    }
}

Task {
    do {
        let port = try await RemuxHTTPServer.shared.start()
        let t0 = now()
        let session = try await RemuxSession.open(url: url, headers: ["User-Agent": "NovaPlayer-Harness"], audioLanguage: nil,
                                                  targetSegment: Double(ProcessInfo.processInfo.environment["SEG"] ?? "6") ?? 6,
                                                  forceAudioTranscode: transcode,
                                                  blockSize: (Int(ProcessInfo.processInfo.environment["BLOCK_KB"] ?? "512") ?? 512) * 1024,
                                                  maxInFlight: Int(ProcessInfo.processInfo.environment["INFLIGHT"] ?? "2") ?? 2)
        let info = session.info
        print(String(format: "OPEN %.0f ms, bytes=%lld, dur=%.2f, %dx%d %.3ffps codecs=%@ range=%@ audio %@→%@ ch=%d transcoded=%d segs=%d target=%.2f",
                     now() - t0, info.openBytes, info.duration, info.width, info.height, info.fps, info.codecs, info.videoRange,
                     info.audioIn, info.audioOut, info.audioChannels, info.audioTranscoded ? 1 : 0, info.segments.count, info.targetDuration))
        session.onSegment = { t in
            print(String(format: "SEG %d %@ %.1f ms enc %.1f ms %d B  v[%.4f..%.4f] a[%.4f..%.4f]", t.index, t.prefetch ? "pre" : "req",
                         t.ms, t.encodeMs, t.bytes, t.videoFirst, t.videoEnd, t.audioFirst, t.audioEnd))
        }
        RemuxHTTPServer.shared.register(session)
        let master = RemuxHTTPServer.shared.url(for: session, port: port)
        print("URL \(master)")
        switch mode {
        case "dump":
            let dir = URL(fileURLWithPath: args[3])
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let base = master.deletingLastPathComponent()
            var names = ["master.m3u8", "media.m3u8", "init.mp4"]
            var segNames = (0..<info.segments.count).map { "seg\($0).m4s" }
            if args.contains("--shuffle") { segNames.shuffle() }
            names += segNames
            let d0 = now()
            for name in names {
                let (data, response) = try await URLSession.shared.data(from: base.appendingPathComponent(name))
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { print("HTTP fail \(name)"); exit(1) }
                try data.write(to: dir.appendingPathComponent(name))
            }
            print(String(format: "DUMP %.0f ms total, source requests=%d bytes=%lld", now() - d0, session.byteStats.requests, session.byteStats.bytes))
            exit(0)
        case "avplayer":
            await Bench().run(master: master, duration: info.duration)
            print(String(format: "SOURCE requests=%d bytes=%lld wait=%.0f ms", session.byteStats.requests, session.byteStats.bytes,
                         session.byteStats.waitMs))
            exit(0)
        default:
            print("serving…")
        }
    } catch {
        print("ERROR \(error)")
        exit(1)
    }
}
RunLoop.main.run()
