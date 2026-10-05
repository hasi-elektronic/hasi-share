import Foundation

/// Stream container (CONTRACT §6).
public enum StreamContainer: String, Codable, Sendable, Hashable, CaseIterable {
    case hls, dash, mpegts, mp4, mkv, webm, flv, avi, rtmp, rtsp, udp, unknown

    /// Short human-readable name for error messages ("MPEG-TS", "MKV"…).
    public var displayName: String {
        switch self {
        case .hls: return "HLS"
        case .dash: return "DASH"
        case .mpegts: return "MPEG-TS"
        case .mp4: return "MP4"
        case .mkv: return "MKV"
        case .webm: return "WebM"
        case .flv: return "FLV"
        case .avi: return "AVI"
        case .rtmp: return "RTMP"
        case .rtsp: return "RTSP"
        case .udp: return "UDP/RTP"
        case .unknown: return "?"
        }
    }
}

/// Player engine of a platform (support matrix columns of CONTRACT §6).
public enum PlayerEngine: String, Sendable, Hashable, CaseIterable {
    /// AVPlayer (iOS, iPadOS, tvOS).
    case avPlayer = "avplayer"
    /// AndroidX Media3 / ExoPlayer.
    case media3
    /// VLCKit 3.x (libVLC) – second engine of the Apple apps (MobileVLCKit / TVVLCKit) for
    /// everything AVPlayer cannot open (CONTRACT §6.1).
    case vlcKit = "vlckit"
}

extension StreamContainer {
    /// Whether `engine` can play this container. `unknown` → true ("try and map the player
    /// error").
    public func isSupported(by engine: PlayerEngine) -> Bool {
        switch engine {
        case .avPlayer:
            switch self {
            case .hls, .mp4, .unknown: return true
            default: return false
            }
        case .media3:
            switch self {
            case .rtmp, .udp: return false
            default: return true
            }
        case .vlcKit:
            // UDP/RTP multicast needs the restricted multicast entitlement on iOS/tvOS.
            return self != .udp
        }
    }

    /// Pre-playback check: nil if playable, else the `PlaybackError` to show.
    public func playbackError(for engine: PlayerEngine) -> PlaybackError? {
        isSupported(by: engine) ? nil : .unsupportedFormat(container: rawValue)
    }
}

/// Engine choice of the Apple apps (CONTRACT §6.1): AVPlayer for what it plays natively
/// (HLS, MP4/MOV, unknown → try), VLCKit for everything else; one fallback AVPlayer → VLCKit
/// when AVPlayer reports a format/codec error.
public enum ApplePlayback {
    /// Engine for a detected container; nil = not playable on Apple (`UnsupportedFormat`).
    /// - Parameter vlcAvailable: false when the app is built without VLCKit (AVPlayer only).
    public static func engine(for container: StreamContainer, vlcAvailable: Bool = true) -> PlayerEngine? {
        if container.isSupported(by: .avPlayer) { return .avPlayer }
        if vlcAvailable, container.isSupported(by: .vlcKit) { return .vlcKit }
        return nil
    }

    /// Pre-playback check: nil if playable on Apple, else the error to show.
    public static func playbackError(for container: StreamContainer, vlcAvailable: Bool = true) -> PlaybackError? {
        engine(for: container, vlcAvailable: vlcAvailable) == nil ? .unsupportedFormat(container: container.rawValue) : nil
    }

    /// Engine to retry with after `error` on `engine` (at most once per opened stream): only
    /// AVPlayer → VLCKit, only for `UnsupportedFormat` / `UnsupportedCodec`.
    public static func fallbackEngine(after error: PlaybackError, on engine: PlayerEngine, vlcAvailable: Bool = true) -> PlayerEngine? {
        guard vlcAvailable, engine == .avPlayer else { return nil }
        switch error {
        case .unsupportedFormat, .unsupportedCodec: return .vlcKit
        default: return nil
        }
    }
}

/// Container detection (CONTRACT §6): scheme → byte sniffing → content type → extension.
public enum StreamFormatDetector {
    /// Number of leading bytes worth sniffing.
    public static let sniffLength = 1024

    /// Detects the container of a stream.
    /// - Parameters:
    ///   - url: stream URL (string, may be any scheme).
    ///   - contentType: `Content-Type` header (parameters and case ignored).
    ///   - firstBytes: first bytes of the body (≥ 4 bytes to be used; 1024 recommended).
    public static func detect(url: String, contentType: String? = nil, firstBytes: Data? = nil) -> StreamContainer {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        let scheme = trimmed.range(of: ":").map { trimmed[trimmed.startIndex..<$0.lowerBound].lowercased() } ?? ""
        // 1. Scheme.
        if scheme.hasPrefix("rtmp") { return .rtmp }
        if scheme == "rtsp" || scheme == "rtsps" { return .rtsp }
        if scheme == "udp" || scheme == "rtp" { return .udp }
        // 2. Bytes.
        if let firstBytes, firstBytes.count >= 4, let sniffed = sniff(firstBytes) { return sniffed }
        // 3. Content type.
        if let contentType, let byType = fromContentType(contentType) { return byType }
        // 4. Extension.
        if let byExtension = fromExtension(url: trimmed) { return byExtension }
        return .unknown
    }

    /// Convenience overload for `URL`.
    public static func detect(url: URL, contentType: String? = nil, firstBytes: Data? = nil) -> StreamContainer {
        detect(url: url.absoluteString, contentType: contentType, firstBytes: firstBytes)
    }

    /// Byte sniffing; nil when inconclusive.
    public static func sniff(_ data: Data) -> StreamContainer? {
        let b = [UInt8](data.prefix(sniffLength))
        guard b.count >= 4 else { return nil }
        // Text formats may start with a BOM and/or whitespace.
        var t = 0
        if b.count >= 3, b[0] == 0xEF, b[1] == 0xBB, b[2] == 0xBF { t = 3 }
        while t < b.count, b[t] == 0x20 || b[t] == 0x09 || b[t] == 0x0A || b[t] == 0x0D { t += 1 }
        if starts(b, at: t, with: "#EXTM3U") { return .hls }
        if starts(b, at: t, with: "<MPD") { return .dash }
        if starts(b, at: t, with: "<?xml"), contains(b, "<MPD") { return .dash }
        if b[0] == 0x47, b.count > 188, b[188] == 0x47, b.count <= 376 || b[376] == 0x47 { return .mpegts }
        if b.count >= 8, starts(b, at: 4, with: "ftyp") { return .mp4 }
        if b[0] == 0x1A, b[1] == 0x45, b[2] == 0xDF, b[3] == 0xA3 { return isWebM(b) ? .webm : .mkv }
        if starts(b, at: 0, with: "FLV") { return .flv }
        if b.count >= 12, starts(b, at: 0, with: "RIFF"), starts(b, at: 8, with: "AVI ") { return .avi }
        return nil
    }

    /// Content-type mapping (case-insensitive, parameters ignored); nil when unknown.
    public static func fromContentType(_ contentType: String) -> StreamContainer? {
        let type = contentType.split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? ""
        switch type {
        case "application/vnd.apple.mpegurl", "application/x-mpegurl", "audio/mpegurl", "audio/x-mpegurl": return .hls
        case "application/dash+xml": return .dash
        case "video/mp2t": return .mpegts
        case "video/mp4": return .mp4
        case "video/x-matroska": return .mkv
        case "video/webm": return .webm
        case "video/x-flv": return .flv
        default: return nil
        }
    }

    /// URL path extension mapping; nil when unknown.
    public static func fromExtension(url: String) -> StreamContainer? {
        var path = url
        if let parts = URLParts.parse(url) { path = parts.path }
        guard let slash = path.lastIndex(of: "/") ?? path.indices.first else { return nil }
        let last = path[slash...]
        guard let dot = last.lastIndex(of: ".") else { return nil }
        switch last[last.index(after: dot)...].lowercased() {
        case "m3u8", "m3u": return .hls
        case "mpd": return .dash
        case "ts", "mts", "m2ts": return .mpegts
        case "mp4", "m4v", "mov": return .mp4
        case "mkv": return .mkv
        case "webm": return .webm
        case "flv": return .flv
        case "avi": return .avi
        default: return nil
        }
    }

    private static func starts(_ b: [UInt8], at offset: Int, with ascii: String) -> Bool {
        let pattern = Array(ascii.utf8)
        guard offset + pattern.count <= b.count else { return false }
        for (i, p) in pattern.enumerated() where b[offset + i] != p { return false }
        return true
    }

    private static func contains(_ b: [UInt8], _ ascii: String) -> Bool {
        let pattern = Array(ascii.utf8)
        guard b.count >= pattern.count else { return false }
        for i in 0...(b.count - pattern.count) where starts(b, at: i, with: ascii) { return true }
        return false
    }

    /// EBML DocType (element 0x4282) == "webm".
    private static func isWebM(_ b: [UInt8]) -> Bool {
        var i = 4
        while i + 2 < b.count {
            if b[i] == 0x42, b[i + 1] == 0x82 {
                let sizeByte = b[i + 2]
                // 1-byte VINT size (0x8X) is what muxers write for the DocType.
                if sizeByte & 0x80 != 0 {
                    let length = Int(sizeByte & 0x7F)
                    let start = i + 3
                    if start + length <= b.count {
                        return String(decoding: b[start..<(start + length)], as: UTF8.self) == "webm"
                    }
                }
                break
            }
            i += 1
        }
        return contains(Array(b.prefix(64)), "webm")
    }
}
