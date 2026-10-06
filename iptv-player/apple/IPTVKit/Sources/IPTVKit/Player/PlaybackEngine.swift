import Foundation
import IPTVCore

/// What an engine reports to `PlayerController` (always on the main actor).
public enum EngineEvent: Equatable, Sendable {
    case playing
    case paused
    case buffering
    /// Item is ready; `duration` 0 = live/unknown.
    case ready(duration: Double)
    case time(Double)
    case tracks(audio: [MediaOption], subtitles: [MediaOption], selectedAudio: Int?, selectedSubtitle: Int?)
    case failed(PlaybackError)
    /// Playback stalled (the controller starts its 12 s stall timer).
    case stalled
    case ended
}

/// Live engine statistics for the performance overlay (Settings → Diagnostics). Any field may
/// be unknown (nil) – the overlay then shows "—".
public struct EngineDiagnostics: Sendable, Equatable {
    /// Indicated/demux bitrate in bits per second.
    public var bitrate: Double?
    public var droppedFrames: Int?
    /// "1920x1080" once known.
    public var resolution: String?

    public init(bitrate: Double? = nil, droppedFrames: Int? = nil, resolution: String? = nil) {
        self.bitrate = bitrate
        self.droppedFrames = droppedFrames
        self.resolution = resolution
    }
}

/// One playback engine behind `PlayerController` (docs/ARCHITECTURE.md §3.2): AVPlayer
/// (`AVPlayerEngine`, IPTVKit) or VLCKit (`VLCPlaybackEngine`, app target – the VLCKit
/// framework only exists for iOS/tvOS). The controller owns reconnect, zapping, progress and
/// the phase machine; engines only play one stream at a time and report `EngineEvent`s.
@MainActor
public protocol PlaybackEngine: AnyObject {
    var kind: PlayerEngine { get }
    var onEvent: (@MainActor (EngineEvent) -> Void)? { get set }
    /// Replaces the current item; `startMs` = resume position (VOD).
    func load(_ stream: ResolvedStream, isLive: Bool, startMs: Int64?, preferredAudioLanguage: String?, preferredSubtitleLanguage: String?)
    func play()
    func pause()
    var isPlaying: Bool { get }
    /// Current statistics (polled by the performance overlay only).
    var diagnostics: EngineDiagnostics { get }
    func seek(to seconds: Double)
    func selectAudio(_ id: Int)
    /// nil → subtitles off.
    func selectSubtitle(_ id: Int?)
    func setAspect(_ mode: AspectMode)
    /// Stops and frees the current item (the engine instance stays reusable).
    func stop()
}

/// Engine factories handed to `PlayerController`. `vlc` is nil for builds without VLCKit
/// (unit tests on macOS, or a hypothetical AVPlayer-only build) – then MKV/TS/… fail with
/// `UnsupportedFormat` exactly as before (CONTRACT §6.1 "selectWithoutVlc").
public struct PlaybackEngines {
    public var avPlayer: @MainActor () -> any PlaybackEngine
    public var vlc: (@MainActor () -> any PlaybackEngine)?

    public init(avPlayer: @escaping @MainActor () -> any PlaybackEngine, vlc: (@MainActor () -> any PlaybackEngine)?) {
        self.avPlayer = avPlayer
        self.vlc = vlc
    }

    public var vlcAvailable: Bool { vlc != nil }

    #if canImport(AVFoundation)
    /// AVPlayer only.
    @MainActor public static var avPlayerOnly: PlaybackEngines { PlaybackEngines(avPlayer: { AVPlayerEngine() }, vlc: nil) }
    #endif
}

/// Track names for the audio/subtitle menus (SCREENS §3.7): language name in the UI language
/// ("Türkçe", "English"), nil when unknown → the UI shows "Track n".
public enum TrackNaming {
    /// Language display name for an ISO 639-1/-2 code or BCP-47 tag ("tur", "en", "pt-BR").
    public static func displayName(forLanguage code: String?, locale: Locale = .current) -> String? {
        guard let raw = code?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        let lowered = raw.lowercased()
        // "und" (undetermined), "mis", "mul", "zxx" carry no language.
        if ["und", "mis", "mul", "zxx", "unknown"].contains(lowered) { return nil }
        if let name = locale.localizedString(forIdentifier: normalized(raw) ?? raw), name.lowercased() != lowered { return name }
        return nil
    }

    /// Two-letter language code (if known) for preference matching: "tur" → "tr", "en-US" → "en".
    public static func normalized(_ code: String?) -> String? {
        guard let code = code?.trimmingCharacters(in: .whitespacesAndNewlines), !code.isEmpty else { return nil }
        let base = code.split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init) ?? code
        let language = Locale.Language(identifier: base.lowercased())
        return language.languageCode?.identifier(.alpha2) ?? language.languageCode?.identifier ?? base.lowercased()
    }

    /// True when a track language matches a preferred language ("tr" vs "tur", "en" vs "en-GB").
    public static func matches(_ trackLanguage: String?, preferred: String?) -> Bool {
        guard let a = normalized(trackLanguage), let b = normalized(preferred) else { return false }
        return a == b
    }
}

/// Classifies a VLCKit failure (libVLC 3 reports only "error"/"ended", no reason) with an HTTP
/// probe of the stream URL, so the error card matches SCREENS §4 like on AVPlayer.
public enum VLCFailureClassifier {
    public struct Probe: Sendable, Equatable {
        public var httpStatus: Int?
        public var transportError: PlaybackError?
        public init(httpStatus: Int?, transportError: PlaybackError?) {
            self.httpStatus = httpStatus
            self.transportError = transportError
        }
    }

    /// - Parameters:
    ///   - probe: result of a 1 KiB range request to the stream (nil = not an HTTP URL).
    ///   - hadPlayed: the stream played before failing (→ connection loss, reconnect).
    ///   - ended: libVLC reported "ended" rather than "error".
    ///   - isLive: live streams never "end" – an end is a dropped connection.
    ///   - remainingSeconds: VOD time left when it ended (nil = unknown duration); an "end"
    ///     far from the real end is a dropped HTTP connection.
    /// - Returns: nil for a normal end of a VOD.
    public static func classify(probe: Probe?, hadPlayed: Bool, ended: Bool, isLive: Bool, remainingSeconds: Double? = nil) -> PlaybackError? {
        if ended, !isLive, hadPlayed, (remainingSeconds ?? 0) < 30 { return nil }
        if let status = probe?.httpStatus, let mapped = ErrorClassifier.playbackError(httpStatus: status) { return mapped }
        if let transport = probe?.transportError { return transport }
        if hadPlayed || ended { return .network(.other) }
        // Reachable and served, but libVLC could not open/decode it.
        return .unsupportedCodec(codec: nil)
    }

    /// 1 KiB range request (6 s budget) – status or transport error; nil for non-HTTP URLs.
    public static func probe(_ url: URL, headers: [String: String]) async -> Probe? {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return nil }
        var request = HTTPRequest(url: url, headers: headers.merging(["Range": "bytes=0-1023"]) { a, _ in a },
                                  timeouts: HTTPTimeouts(connect: 6, read: 6, total: 6))
        request.method = .get
        do {
            let response = try await URLSessionTransport.shared.stream(request)
            // Read ≤ 1 KiB and drop the stream (cancels the task – live TS ignores Range).
            _ = try? await response.collect(limit: 1024)
            return Probe(httpStatus: response.statusCode, transportError: nil)
        } catch {
            return Probe(httpStatus: nil, transportError: ErrorClassifier.playbackError(from: error) ?? .network(.other))
        }
    }
}
