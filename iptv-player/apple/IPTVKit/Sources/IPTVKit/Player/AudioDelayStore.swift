import Foundation

/// User audio delay (docs/SCREENS.md §3.7, docs/ARCHITECTURE.md §3.2): one value per content
/// (channel / movie / episode content key) plus one device value (Settings → Playback, e.g. a
/// soundbar). Milliseconds, −2000…+2000 in 50 ms steps; positive = audio later. Device-local.
/// An effective delay ≠ 0 plays through VLCKit (CONTRACT §6.1) – AVPlayer cannot delay audio.
public struct AudioDelayStore: Sendable {
    private let kv: any KeyValueStore
    public static let range: ClosedRange<Int> = -2000...2000
    public static let step = 50

    public init(kv: any KeyValueStore) { self.kv = kv }

    /// Clamped to `range` and rounded to `step`.
    static func normalize(_ ms: Int) -> Int {
        let c = min(max(ms, range.lowerBound), range.upperBound)
        return Int((Double(c) / Double(step)).rounded()) * step
    }

    private func key(_ k: String) -> String { "audioDelay.\(k)" }

    /// Delay of one content (default 0).
    public func contentDelay(_ contentKey: String) -> Int { kv.value(Int.self, forKey: key(contentKey)) ?? 0 }

    /// Clamped + rounded to the step; 0 removes the key.
    public func setContentDelay(_ ms: Int, for contentKey: String) {
        let v = Self.normalize(ms)
        if v == 0 { kv.set(nil, forKey: key(contentKey)) } else { kv.setValue(v, forKey: key(contentKey)) }
    }

    /// Delay of this device's audio output (soundbar, TV), added to every content.
    public var deviceDelay: Int { kv.value(Int.self, forKey: "audioDelay.device") ?? 0 }

    public func setDeviceDelay(_ ms: Int) { kv.setValue(Self.normalize(ms), forKey: "audioDelay.device") }

    /// clamp(content + device).
    public func effectiveDelay(_ contentKey: String) -> Int { Self.normalize(contentDelay(contentKey) + deviceDelay) }
}

/// Automatic output-latency term of the VLCKit engine (docs/ARCHITECTURE.md §3.2).
///
/// libVLC 3's iOS/tvOS audio output (`modules/audio_output/audiounit_ios.m`) already reads
/// `AVAudioSession.outputLatency` when the output starts and on every route change and adds it to
/// the delay it reports for A/V sync (`coreaudio_common.c`, `ca_GetLatencyLocked`) – capped at 1 s
/// ("VLC can't handle this device latency"). Adding the full latency again would double it, so only
/// the part above the cap (AirPlay ≈ 2 s) is compensated here: that audio would be heard late, so
/// it is played earlier (negative delay; VLC sign: + = audio later, `currentAudioPlaybackDelay`).
public enum VLCLatencyCompensation {
    /// Device latency libVLC compensates itself (1 s cap in `ca_SetDeviceLatency` / `ca_Initialize`).
    public static let handledByLibVLCMs = 1000

    /// Extra delay in ms for the given `AVAudioSession.outputLatency` (seconds).
    public static func autoDelayMs(outputLatency: TimeInterval) -> Int {
        guard outputLatency.isFinite, outputLatency > 0 else { return 0 }
        let ms = Int((outputLatency * 1000).rounded())
        return -max(0, ms - handledByLibVLCMs)
    }

    /// User delay (content + device) + automatic term, in ms.
    public static func totalDelayMs(userMs: Int, outputLatency: TimeInterval) -> Int {
        userMs + autoDelayMs(outputLatency: outputLatency)
    }
}
