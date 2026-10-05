import AVFoundation
import Foundation
import IPTVCore
import Observation

/// One entry of `spec/test-vectors/stream-samples.json`.
public struct StreamSample: Decodable, Identifiable, Sendable, Hashable {
    public struct Expect: Decodable, Sendable, Hashable {
        /// AVPlayer alone (historical column).
        public var avplayer: String
        /// The Apple apps with both engines (AVPlayer + VLCKit, CONTRACT §6.1); falls back to `avplayer`.
        public var apple: String?
    }
    public var id: String
    public var name: String
    public var url: String
    public var container: String
    public var expect: Expect

    /// Expectation for the Apple apps: `apple` when VLCKit is available, else `avplayer`.
    public func expected(vlcAvailable: Bool) -> String {
        vlcAvailable ? (expect.apple ?? expect.avplayer) : expect.avplayer
    }
}

/// Settings → Diagnostics → Format test (docs/STREAM_COMPATIBILITY.md §3.2).
@MainActor
@Observable
public final class FormatTestViewModel {
    public enum Outcome: Equatable, Sendable {
        case pending
        case running
        case ok
        case expectedError(String)
        case unexpected(String)
    }

    public private(set) var samples: [StreamSample] = []
    public private(set) var results: [String: Outcome] = [:]
    /// Engine each sample was routed to (AVPlayer / VLCKit), filled while running.
    public private(set) var engines: [String: PlayerEngine] = [:]
    public private(set) var running = false
    @ObservationIgnored private let resolver: StreamResolver
    @ObservationIgnored private let playbackEngines: PlaybackEngines?

    /// - Parameter engines: the app's engines (probe through the real engine, VLCKit-aware);
    ///   `nil` → AVPlayer-only probe (unit tests on macOS).
    public init(samplesJSON: Data?, lanHost: String, engines: PlaybackEngines? = nil, resolver: StreamResolver? = nil) {
        self.playbackEngines = engines
        self.resolver = resolver ?? StreamResolver(secrets: { _ in nil }, vlcAvailable: engines?.vlcAvailable ?? false)
        struct File: Decodable { var samples: [StreamSample] }
        if let data = samplesJSON, let file = try? JSONDecoder().decode(File.self, from: data) {
            samples = file.samples.map { s in
                var s = s
                s.url = s.url.replacingOccurrences(of: "<LAN-IP>", with: lanHost)
                return s
            }
        }
    }

    /// Short error name as used in the samples file (`error:UnsupportedFormat`).
    public static func name(of error: PlaybackError) -> String {
        switch error {
        case .network: return "Network"
        case .accessDenied: return "AccessDenied"
        case .streamOffline: return "StreamOffline"
        case .serverError: return "ServerError"
        case .unsupportedFormat: return "UnsupportedFormat"
        case .unsupportedCodec: return "UnsupportedCodec"
        case .drm: return "Drm"
        case .unknown: return "Unknown"
        }
    }

    /// VLCKit engine available (decides the expectation column).
    public var vlcAvailable: Bool { playbackEngines?.vlcAvailable ?? false }

    /// Expectation shown / compared for a sample.
    public func expected(_ sample: StreamSample) -> String { sample.expected(vlcAvailable: vlcAvailable) }

    /// Compares an observed result ("play" or an error name) with the expectation.
    public static func evaluate(expected: String, observed: String) -> Outcome {
        if expected == "play" {
            return observed == "play" ? .ok : .unexpected(observed)
        }
        if expected == "play-or-codec-error" {
            if observed == "play" { return .ok }
            return observed == "UnsupportedCodec" ? .expectedError(observed) : .unexpected(observed)
        }
        let wanted = expected.replacingOccurrences(of: "error:", with: "")
        if observed == wanted { return .expectedError(wanted) }
        return .unexpected(observed)
    }

    public func runAll() async {
        running = true
        defer { running = false }
        for sample in samples { results[sample.id] = .pending }
        for sample in samples {
            results[sample.id] = .running
            let observed = await probe(sample)
            results[sample.id] = Self.evaluate(expected: expected(sample), observed: observed)
        }
    }

    private func probe(_ sample: StreamSample) async -> String {
        let request = PlaybackRequest(item: .url(sample.url, title: sample.name), source: nil)
        let stream: ResolvedStream
        do {
            stream = try await resolver.resolve(request)
        } catch let error as PlaybackError {
            return Self.name(of: error)
        } catch {
            return "Unknown"
        }
        engines[sample.id] = stream.engine
        if let playbackEngines {
            return await probe(stream, engine: stream.engine == .vlcKit ? (playbackEngines.vlc?() ?? playbackEngines.avPlayer()) : playbackEngines.avPlayer())
        }
        let item = AVPlayerItem(url: stream.url)
        let player = AVPlayer(playerItem: item)
        player.isMuted = true
        player.play()
        defer { player.pause(); player.replaceCurrentItem(with: nil) }
        for _ in 0..<60 {
            try? await Task.sleep(for: .milliseconds(250))
            switch item.status {
            case .readyToPlay: return "play"
            case .failed:
                return Self.name(of: item.error.map { PlaybackErrorMapper.map($0, container: stream.container) } ?? .unknown(message: ""))
            default: continue
            }
        }
        return "Network"
    }

    /// Probes through a real engine: first `.ready`/`.playing` → "play", `.failed` → error name, 15 s → "Network".
    private func probe(_ stream: ResolvedStream, engine: any PlaybackEngine) async -> String {
        var outcome: String?
        engine.onEvent = { event in
            guard outcome == nil else { return }
            switch event {
            case .ready, .playing: outcome = "play"
            case .failed(let error): outcome = Self.name(of: error)
            default: break
            }
        }
        engine.load(stream, isLive: false, startMs: nil, preferredAudioLanguage: nil, preferredSubtitleLanguage: nil)
        engine.play()
        defer { engine.onEvent = nil; engine.stop() }
        for _ in 0..<60 {
            if let outcome { return outcome }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return outcome ?? "Network"
    }
}
